# Local development database

Docker Compose provides PostgreSQL for local development only; it does not run the API or any background workers.

## Setup

1. Copy the templates:

   ```powershell
   Copy-Item .env.example .env
   Copy-Item server/.env.example server/.env
   ```

2. Replace `replace-with-a-local-dev-password` in both files with the same unique, URL-safe local password. In `server/.env`, also replace the authentication secret placeholder with a random value of at least 32 bytes. The templates contain placeholders only and must not receive production credentials.
3. Start PostgreSQL and wait for its health check:

   ```powershell
   docker compose up -d postgres
   docker compose ps
   ```

4. Apply the SQL migrations with the pinned `golang-migrate` container:

   ```powershell
   docker compose --profile tools run --rm migrate
   ```

   The runner reads the versioned SQL files in `server/migrations` and records applied versions in PostgreSQL. After applying them, use the smoke check in [`server/migrations/README.md`](../server/migrations/README.md) to verify the expected tables and seeded synchronization cursor.

## Useful commands

```powershell
# Follow PostgreSQL logs.
docker compose logs -f postgres

# Stop the local services while preserving database data.
docker compose down

# Remove local services and the development database volume.
docker compose down -v
```

`docker compose down -v` permanently deletes the local PostgreSQL data volume.

## Two-device convergence harness

Task 4.9 includes an opt-in Flutter integration test that uses two independent
in-memory Drift replicas, the real authenticated `AuthenticatedSyncRuntime`
composition root, HTTP sockets, and the PostgreSQL-backed API. It creates an
account, performs deterministic offline product and movement work, synchronizes
in both device orders, injects a transaction interruption during remote-page
application, and verifies both replicas plus the server snapshot converge.

Start PostgreSQL and apply migrations as above, then start the API with
`server/.env` configured for that database. In a second PowerShell terminal,
set the API URL and the same migrated database URL used by the API, for example:

```powershell
$env:STOKSYNC_TEST_API_BASE_URI = "http://127.0.0.1:8080"
$env:STOKSYNC_TEST_DATABASE_URL = "postgres://stoksync:local-password@127.0.0.1:5432/stoksync?sslmode=disable"
Push-Location app
try { flutter test test/integration/two_device_convergence_test.dart } finally { Pop-Location }
```

The test is skipped when either variable is absent, so ordinary Flutter test
runs do not require Docker. The database URL is an explicit prerequisite and
serves as a guard against accidentally treating a fake transport or an
unmigrated database as the live integration environment. The test creates a
unique disposable account; it does not delete or reset shared database data.

## Product balance projection check

The server keeps `product_balances` as a rebuildable read projection; the
immutable `stock_movements` ledger remains canonical. After setting
`STOKSYNC_DATABASE_URL` (or loading `server/.env` in the shell), verify one
account with:

```powershell
go run ./cmd/verify-projections -user-id <account-uuid>
```

The command exits non-zero and lists mismatches when a projection row is
missing or differs from the ledger-derived quantity/latest movement time. To
repair the projection and verify the repaired result, run:

```powershell
go run ./cmd/verify-projections -user-id <account-uuid> -rebuild
```

Both commands must be run from `server/`. They require migrations 000001
through 000003 and a reachable PostgreSQL database; they do not expose an HTTP
endpoint or change stock movement history.

## API smoke test

After PostgreSQL is healthy and the migrations are applied, start the API from
`server/` with the variables in `server/.env` loaded into the current shell.
The API process reads environment variables; it does not load `.env` files
itself. For PowerShell, from the repository root:

```powershell
Get-Content server/.env |
  Where-Object { $_ -and $_ -notmatch '^\s*#' } |
  ForEach-Object {
    $name, $value = $_ -split '=', 2
    Set-Item -Path "Env:$($name.Trim())" -Value $value.Trim()
  }
Push-Location server
try { go run ./cmd/api } finally { Pop-Location }
```

In a second terminal, run the reproducible login/refresh/snapshot/health
check. It creates a disposable account by default, so no credentials need to
be committed:

```powershell
.\server\scripts\api-smoke.ps1
```

To exercise an existing account instead, provide its credentials and skip the
fixture registration:

```powershell
.\server\scripts\api-smoke.ps1 `
  -SkipRegister `
  -Email "owner@example.test" `
  -Password "your-local-password"
```

The complete route contract and response/error shapes are in
[`sync-protocol.md`](sync-protocol.md).
