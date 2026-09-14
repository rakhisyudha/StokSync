[CmdletBinding()]
param(
    [string]$DatabaseName
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$createdDatabases = [System.Collections.Generic.List[string]]::new()

function Invoke-ComposeSql {
    param(
        [Parameter(Mandatory)] [string]$Database,
        [Parameter(Mandatory)] [string]$Sql
    )

    $Sql | docker compose exec -T postgres sh -c "psql -v ON_ERROR_STOP=1 -U `"$script:postgresUser`" -d `"$Database`""
    if ($LASTEXITCODE -ne 0) {
        throw "PostgreSQL command failed for database '$Database'."
    }
}

function Invoke-ComposeSqlFile {
    param(
        [Parameter(Mandatory)] [string]$Database,
        [Parameter(Mandatory)] [string]$Path
    )

    Invoke-ComposeSql -Database $Database -Sql (Get-Content -Raw -LiteralPath $Path)
}

function New-TestDatabase {
    param([Parameter(Mandatory)] [string]$Name)

    Invoke-ComposeSql -Database $script:postgresDatabase -Sql "DROP DATABASE IF EXISTS `"$Name`";"
    Invoke-ComposeSql -Database $script:postgresDatabase -Sql "CREATE DATABASE `"$Name`";"
    $script:createdDatabases.Add($Name)
}

function Invoke-Migrations {
    param(
        [Parameter(Mandatory)] [string]$Database,
        [int]$Count = 0
    )

    $databaseUrl = "postgres://$([Uri]::EscapeDataString($script:postgresUser)):$([Uri]::EscapeDataString($script:postgresPassword))@postgres:5432/${Database}?sslmode=disable"
    $arguments = @(
        'compose', '--profile', 'tools', 'run', '--rm', 'migrate',
        '-path=/migrations', "-database=$databaseUrl", 'up'
    )
    if ($Count -gt 0) {
        $arguments += $Count.ToString()
    }

    & docker @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Migration runner failed for database '$Database'."
    }
}

function Invoke-UpgradeScenario {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int]$InitialMigration,
        [Parameter(Mandatory)] [string]$Fixture
    )

    New-TestDatabase -Name $Name
    Invoke-Migrations -Database $Name -Count $InitialMigration
    Invoke-ComposeSqlFile -Database $Name -Path $Fixture
    Invoke-Migrations -Database $Name
    Invoke-ComposeSqlFile -Database $Name -Path (Join-Path $PSScriptRoot 'testdata/upgrade_assertions.sql')
    Write-Host "Migration upgrade scenario passed: $Name"
}

Push-Location $repositoryRoot
try {
    $composeJson = (& docker compose config --format json) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the resolved Docker Compose configuration.'
    }
    $composeConfig = $composeJson | ConvertFrom-Json
    $postgresEnvironment = $composeConfig.services.postgres.environment
    $script:postgresUser = [string]$postgresEnvironment.POSTGRES_USER
    $script:postgresPassword = [string]$postgresEnvironment.POSTGRES_PASSWORD
    $script:postgresDatabase = [string]$postgresEnvironment.POSTGRES_DB

    if ([string]::IsNullOrWhiteSpace($script:postgresUser) -or
        [string]::IsNullOrWhiteSpace($script:postgresPassword) -or
        [string]::IsNullOrWhiteSpace($script:postgresDatabase)) {
        throw 'POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB must be set in the Compose environment.'
    }
    if ($script:postgresUser -notmatch '^[A-Za-z0-9_]+$' -or
        $script:postgresDatabase -notmatch '^[A-Za-z0-9_]+$') {
        throw 'The migration test requires alphanumeric or underscore PostgreSQL user/database names.'
    }

    & docker compose up -d postgres
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to start PostgreSQL for migration tests.'
    }
    & docker compose exec -T postgres pg_isready -U $script:postgresUser -d $script:postgresDatabase
    if ($LASTEXITCODE -ne 0) {
        throw 'PostgreSQL is not ready for migration tests.'
    }

    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
        $DatabaseName = "stoksync_migration_upgrade_$suffix"
    }
    if ($DatabaseName -notmatch '^[A-Za-z0-9_]+$') {
        throw 'DatabaseName must contain only alphanumeric characters or underscores.'
    }

    Invoke-UpgradeScenario `
        -Name $DatabaseName `
        -InitialMigration 1 `
        -Fixture (Join-Path $PSScriptRoot 'testdata/000001_upgrade_fixture.sql')
    Invoke-UpgradeScenario `
        -Name "${DatabaseName}_v2" `
        -InitialMigration 2 `
        -Fixture (Join-Path $PSScriptRoot 'testdata/000002_upgrade_fixture.sql')

    Write-Host 'PostgreSQL migration upgrade tests passed.'
}
finally {
    foreach ($database in $createdDatabases) {
        try {
            Invoke-ComposeSql -Database $script:postgresDatabase -Sql "DROP DATABASE IF EXISTS `"$database`";"
        }
        catch {
            Write-Warning "Unable to clean up temporary database '$database': $_"
        }
    }
    Pop-Location
}
