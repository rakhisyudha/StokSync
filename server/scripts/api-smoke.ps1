[CmdletBinding()]
param(
    [string]$BaseUrl = "",
    [string]$Email = "",
    [string]$Password = "",
    [string]$DeviceName = "api-smoke",
    [string]$Platform = "script",
    [switch]$SkipRegister
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = $env:STOKSYNC_API_BASE_URL
}
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = "http://127.0.0.1:8080"
}
$BaseUrl = $BaseUrl.TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($Email)) {
    $Email = $env:STOKSYNC_SMOKE_EMAIL
}
if ([string]::IsNullOrWhiteSpace($Password)) {
    $Password = $env:STOKSYNC_SMOKE_PASSWORD
}

$generatedEmail = $false
if ([string]::IsNullOrWhiteSpace($Email)) {
    $Email = "stoksync-smoke-$([guid]::NewGuid().ToString('N'))@example.test"
    $generatedEmail = $true
}
if ([string]::IsNullOrWhiteSpace($Password)) {
    $Password = "local-api-smoke-password"
}
if ($SkipRegister -and $generatedEmail) {
    throw "-SkipRegister requires -Email (or STOKSYNC_SMOKE_EMAIL) for an existing account."
}

function Invoke-ApiJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object]$Body = $null,
        [string]$AccessToken = $null,
        [int]$ExpectedStatus = 200
    )

    $headers = @{ Accept = "application/json" }
    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
        $headers["Authorization"] = "Bearer $AccessToken"
    }

    $request = @{
        Method          = $Method
        Uri             = "$BaseUrl$Path"
        Headers         = $headers
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $request.ContentType = "application/json"
        $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }

    try {
        $response = Invoke-WebRequest @request
    }
    catch {
        $status = $null
        if ($null -ne $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($null -ne $status) {
            throw "HTTP $Method $Path failed with status $($status): $($_.Exception.Message)"
        }
        throw "HTTP $Method $Path failed: $($_.Exception.Message)"
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -ne $ExpectedStatus) {
        throw "HTTP $Method $Path returned $statusCode; expected $ExpectedStatus. Body: $($response.Content)"
    }

    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        try {
            $json = $response.Content | ConvertFrom-Json
        }
        catch {
            throw "HTTP $Method $Path returned invalid JSON: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        StatusCode = $statusCode
        Body       = $response.Content
        Json       = $json
    }
}

function Get-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,
        [Parameter(Mandatory = $true)]
        [string]$Property
    )

    if ($null -eq $Response.Json) {
        throw "Response did not contain JSON property '$Property'."
    }
    $jsonProperty = $Response.Json.PSObject.Properties[$Property]
    if ($null -eq $jsonProperty -or $null -eq $jsonProperty.Value -or [string]::IsNullOrWhiteSpace([string]$jsonProperty.Value)) {
        throw "Response JSON property '$Property' was empty or missing."
    }
    return $jsonProperty.Value
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Actual,
        [Parameter(Mandatory = $true)]
        [object]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "$Label was '$Actual'; expected '$Expected'."
    }
}

$health = Invoke-ApiJson -Method GET -Path "/v1/health"
Assert-Equal -Actual $health.Json.status -Expected "ok" -Label "GET /v1/health status"
Write-Host "PASS GET /v1/health"

$deviceId = [guid]::NewGuid().ToString()
$credentials = [ordered]@{
    email       = $Email
    password    = $Password
    device_id   = $deviceId
    device_name = $DeviceName
    platform    = $Platform
}

if (-not $SkipRegister) {
    $registration = Invoke-ApiJson -Method POST -Path "/v1/auth/register" -Body $credentials -ExpectedStatus 201
    Assert-Equal -Actual (Get-RequiredValue -Response $registration -Property "device_id") -Expected $deviceId -Label "POST /v1/auth/register device_id"
    Write-Host "PASS POST /v1/auth/register (disposable smoke-test account)"
}

$login = Invoke-ApiJson -Method POST -Path "/v1/auth/login" -Body $credentials
Assert-Equal -Actual (Get-RequiredValue -Response $login -Property "token_type") -Expected "Bearer" -Label "POST /v1/auth/login token_type"
$accessToken = [string](Get-RequiredValue -Response $login -Property "access_token")
$refreshToken = [string](Get-RequiredValue -Response $login -Property "refresh_token")
Assert-Equal -Actual (Get-RequiredValue -Response $login -Property "device_id") -Expected $deviceId -Label "POST /v1/auth/login device_id"
[void](Get-RequiredValue -Response $login -Property "user_id")
Write-Host "PASS POST /v1/auth/login"

$refresh = Invoke-ApiJson -Method POST -Path "/v1/auth/refresh" -Body @{ refresh_token = $refreshToken }
$newAccessToken = [string](Get-RequiredValue -Response $refresh -Property "access_token")
$newRefreshToken = [string](Get-RequiredValue -Response $refresh -Property "refresh_token")
Assert-Equal -Actual (Get-RequiredValue -Response $refresh -Property "token_type") -Expected "Bearer" -Label "POST /v1/auth/refresh token_type"
if ($newRefreshToken -eq $refreshToken) {
    throw "POST /v1/auth/refresh did not rotate the refresh token."
}
$accessToken = $newAccessToken
$refreshToken = $newRefreshToken
Write-Host "PASS POST /v1/auth/refresh (refresh token rotated)"

$snapshot = Invoke-ApiJson -Method GET -Path "/v1/snapshot" -AccessToken $accessToken
Assert-Equal -Actual $snapshot.Json.schema_version -Expected 1 -Label "GET /v1/snapshot schema_version"
[void](Get-RequiredValue -Response $snapshot -Property "server_time")
if ($null -eq $snapshot.Json.cursor -or $snapshot.Json.cursor -lt 0) {
    throw "GET /v1/snapshot returned an invalid cursor."
}
$productCount = @($snapshot.Json.products).Count
$movementCount = @($snapshot.Json.movements).Count
Write-Host "PASS GET /v1/snapshot (schema_version=1, cursor=$($snapshot.Json.cursor), products=$productCount, movements=$movementCount)"

Write-Host "API smoke test passed."
