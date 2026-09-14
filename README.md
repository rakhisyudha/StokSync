# StokSync

StokSync is an offline-first inventory application for one account working across multiple Android/iOS devices. The Flutter client keeps a local SQLite replica of the catalog and stock ledger, while a Go/Chi API and PostgreSQL provide authentication, canonical constraints, durable synchronization, and conflict outcomes.

The v1 client reads and writes local data first. Network access is needed for sign-in, bootstrap, and synchronization, but not for browsing replicated inventory or recording local changes after a device has been authenticated and bootstrapped.

## Repository layout

```text
StokSync/
├── app/                         # Flutter application and Drift/SQLite client
│   ├── lib/                     # app, data, domain, and feature code
│   ├── packages/sync_engine/    # framework-independent Dart sync orchestration
│   └── test/                    # Flutter unit, widget, and integration tests
├── server/                      # Go API and PostgreSQL access/migrations
│   ├── cmd/api/                 # API process entry point
│   ├── internal/                # auth, database, snapshot, sync, and HTTP code
│   ├── migrations/              # versioned PostgreSQL migrations and checks
│   └── scripts/                 # reproducible API smoke checks
├── docs/                        # local setup, protocol, conflict policy, and ADRs
├── docker-compose.yml           # local PostgreSQL and migration runner
├── Makefile                     # client/server format, analysis, and test targets
└── .kiro/specs/stoksync/       # requirements, design, and implementation plan
```

## Prerequisites

- Docker Desktop with Docker Compose v2.
- Flutter stable with Dart SDK `>=3.9.0` for `app/` and `app/packages/sync_engine/`.
- Go 1.21 or newer for the API and Go tests.
- PowerShell 5.1+ for the repository's `.ps1` smoke and migration-upgrade scripts. The commands below use PowerShell syntax because the repository is developed and validated on Windows.
- `make` is optional. The Makefile is convenient in CI, Git Bash, WSL, or another shell that supports its `find`, `grep`, and `awk` commands; equivalent direct commands are listed in [Testing and validation](#testing-and-validation).
- Android Studio/Xcode and a configured emulator or physical device are additionally required for a mobile demo.

## Local setup

### 1. Create local configuration

Copy the checked-in templates. The resulting `.env` files are ignored by Git.

```powershell
Copy-Item .env.example .env
Copy-Item server/.env.example server/.env
```

In the two local files, replace only the placeholders:

- Use the same unique URL-safe local PostgreSQL password in the root `.env` and `server/.env`.
- Set `STOKSYNC_AUTH_ACCESS_TOKEN_SECRET` in `server/.env` to a random local secret of at least 32 bytes.
- Do not copy production credentials into these files or commit either local `.env` file. The templates contain placeholders only; this README intentionally does not reproduce local secret values.

The API reads environment variables, not `.env` files directly. The PowerShell loader in the next step imports `server/.env` into the current process before starting the API.

### 2. Start PostgreSQL and apply migrations

Run these commands from the repository root:

```powershell
docker compose up -d postgres
docker compose ps
docker compose --profile tools run --rm migrate
```

The `postgres` service is the only long-running service in Compose. The `migrate` service is a one-shot, pinned `golang-migrate` container that applies `server/migrations`.

For migration table/seed checks, constraint checks, and upgrade tests, see [`server/migrations/README.md`](server/migrations/README.md). To stop PostgreSQL while preserving the local volume:

```powershell
docker compose down
```

`docker compose down -v` also deletes the local PostgreSQL volume and all local database data.

### 3. Start the API

In a new PowerShell terminal, import the server template and start the API:

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

The default listener is `:8080`, and the default local database URL in the template targets the PostgreSQL container through `127.0.0.1:5432`. In another terminal, check liveness and database readiness:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/v1/health
Invoke-RestMethod http://127.0.0.1:8080/v1/ready
```

Expected responses are `status: ok` for health and `status: ready` when PostgreSQL is reachable. The API does not run inside Docker Compose.

The API smoke script creates a disposable account by default and checks health, registration, login, refresh-token rotation, and authenticated snapshot bootstrap. It does not print token values:

```powershell
.\server\scripts\api-smoke.ps1
```

For the full environment and HTTP route details, see [`docs/local-development.md`](docs/local-development.md) and [`docs/sync-protocol.md`](docs/sync-protocol.md).

### 4. Run the Flutter client

Resolve dependencies and start the app from `app/`:

```powershell
Push-Location app
try {
  flutter pub get
  flutter run --dart-define=STOKSYNC_API_BASE_URL=http://127.0.0.1:8080
} finally {
  Pop-Location
}
```

`STOKSYNC_API_BASE_URL` is optional for a desktop or iOS simulator because the client defaults to `http://127.0.0.1:8080`. Use the host appropriate to the target:

- Android emulator: `http://10.0.2.2:8080`.
- iOS simulator or a desktop target: `http://127.0.0.1:8080`.
- Physical phone: `http://<computer-lan-ip>:8080`; allow the API port through the local firewall and keep the phone and computer on the same network.

The app currently exposes an online sign-in form rather than account registration. Create a local account with `api-smoke.ps1` (using explicit local `-Email` and `-Password` values if the app must log into it), then sign in from the app. After bootstrap, catalog and stock changes are stored in local Drift/SQLite first.

## Architecture

```text
                 local-first reads and writes
┌─────────────────────────────────────────────────────────────┐
│ Flutter UI                                                   │
│ Riverpod providers ── watch() ──► Drift / SQLite replica     │
│        │                                                    │
│        └─ repositories: domain mutation + pending op        │
│           in one SQLite transaction                          │
└──────────────────────────────┬──────────────────────────────┘
                               │ queued operations / cursor
                         pure Dart SyncEngine
                    mutex, retry, push-then-pull
                               │ HTTPS JSON
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ Go API (net/http + Chi)                                     │
│ auth · snapshot · sync · health/readiness                    │
│ per-operation PostgreSQL transactions                        │
└──────────────────────────────┬──────────────────────────────┘
                               │ pgx / explicit SQL
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ PostgreSQL canonical store                                  │
│ products · immutable movements · projections · change log   │
│ idempotency outcomes · devices · refresh sessions           │
└─────────────────────────────────────────────────────────────┘
```

The UI never performs a remote domain write directly. A local mutation updates its domain row, any rebuildable balance projection, and one durable pending operation atomically. The sync engine serializes a cycle, pushes a bounded FIFO batch, reconciles results, pulls ordered changes, and advances the local cursor in the same SQLite transaction as the complete change page. Connectivity notifications are wake-up hints; a health check or sync attempt establishes reachability.

The server is canonical for cross-device constraints, version conflicts, tombstones, and stocktake outcomes. PostgreSQL transactions commit domain data, projections, change-log entries, and the `(device_id, op_id)` idempotency outcome together. v1 has no Redis, Asynq, separate worker process, WebSocket, or push-notification dependency.

Architecture decisions are recorded in [`docs/adr/`](docs/adr/), including [local-first behavior](docs/adr/0001-local-first-architecture.md), [Drift/SQLite](docs/adr/0002-drift-over-hive-and-isar.md), the [immutable ledger](docs/adr/0003-immutable-stock-ledger.md), and [Go/Chi/PostgreSQL](docs/adr/0004-go-chi-postgresql.md).

## Data model overview

### Client replica

The Drift database contains:

- **Products:** client-generated UUIDv7 identity, optional barcode/SKU/description/category, required name and unit, optional minimum-stock threshold, version/timestamps, and deletion state. Soft-deleted rows remain for history and synchronization but disappear from active catalog queries.
- **Stock movements:** append-only rows with product id, non-zero signed `delta`, `receive`/`issue`/`adjust`/`stocktake` kind, note, corrected and raw occurrence times, clock offset, originating device, optional counted quantity, and optional `reverses_id`. Historical rows are never edited or deleted.
- **Product balances:** rebuildable local read projections. A current quantity is the sum of retained movement deltas; the projection is not inventory truth.
- **Pending operations:** stable operation id, FIFO `local_seq`, entity/op/payload, base version and base snapshot where needed, retry metadata, and queue status. Every user mutation enqueues exactly one operation in the same local transaction.
- **Sync state:** bootstrap flag, durable change cursor, last successful sync/error, server-clock offset, and sync status.
- **Conflicts:** local intent, base payload, canonical server payload, reason, and resolution status. Resolving a conflict creates a new explicit local operation.

### Canonical server store

PostgreSQL stores users, device registrations, hashed/rotated refresh sessions, products, immutable stock movements, rebuildable `product_balances`, account-scoped `change_log` rows, `(device_id, op_id)` `sync_ops` outcomes, and the transaction-scoped `sync_seq_counter`. Active barcode uniqueness, ownership, movement-kind/non-zero-delta checks, foreign keys, product version checks, and idempotency uniqueness are enforced by the database and service layer.

A correction is a new reversing `adjust` movement linked to the original. A stocktake keeps the absolute `counted_qty`; the server recomputes its delta against the canonical ledger while holding the product row lock. Concurrent stocktakes are ordered by `(occurred_at, movement_id)`, and displaced intent remains visible instead of rewriting immutable history.

## Protocol overview

All routes are under `/v1` and use JSON, UUID strings, and RFC 3339 UTC timestamps. The implemented public routes are:

| Route | Purpose |
|---|---|
| `GET /v1/health` | Liveness only; does not query PostgreSQL. |
| `GET /v1/ready` | PostgreSQL-backed readiness check. |
| `POST /v1/auth/register` | Local/test account creation and first-device registration. |
| `POST /v1/auth/login` | Credential validation, device registration/refresh, and token issuance. |
| `POST /v1/auth/refresh` | One-time refresh-token rotation. |
| `POST /v1/auth/logout` | Revokes active refresh sessions for the authenticated device. |
| `GET /v1/snapshot` | Consistent full replica bootstrap with products, movements, balances, tombstones, and cursor. |
| `POST /v1/sync` | Per-operation push followed by a bounded account-scoped change-feed page. |

A sync request contains `schema_version`, authenticated `device_id`, non-negative `cursor`, bounded `max_changes`, `client_time`, and an `ops` array. v1 operation envelopes are `add_movement`, `upsert_product`, and `delete_product`. The response contains independent operation results, ordered `changes`, `next_cursor`, `has_more`, and `server_time`.

The client sends due operations in FIFO order before pulling changes. Each valid operation is processed independently, so one rejected operation does not invalidate unrelated operations in the same batch. A retry with the same `(device_id, op_id)` returns the stored original result and does not duplicate a movement or product mutation. Change-log allocation is transaction-scoped; the client applies a complete page and advances its cursor atomically. More pages are requested until `has_more` is false.

Network failures, timeouts, HTTP 429, and HTTP 5xx responses remain retryable with capped exponential backoff and jitter. Validation failures, unsupported schema versions, version conflicts, barcode conflicts, deletion conflicts, and displaced stocktakes are retained as blocked/conflict state. A `401` triggers one refresh attempt; if authentication remains unavailable, synchronization is blocked while local products, movements, pending operations, and conflicts remain intact.

The complete request/response shapes, bounds, authentication rules, pagination behavior, and conflict semantics are in [`docs/sync-protocol.md`](docs/sync-protocol.md). The conflict source of truth is [`docs/conflict-matrix.md`](docs/conflict-matrix.md).

## Testing and validation

### Standard offline checks

The normal test and quality commands do not require Docker or PostgreSQL. From the repository root, the Makefile provides:

```powershell
make help
make client-deps
make format-check
make analyze
make test
make verify
```

`make verify` runs dependency resolution, Dart and Go formatting checks, Flutter/Dart analysis, and client/server tests. Individual direct commands, useful when `make` is unavailable, are:

```powershell
# Flutter app
Push-Location app
try {
  flutter pub get
  dart format --output=none --set-exit-if-changed lib test
  flutter analyze --fatal-infos
  flutter test
} finally {
  Pop-Location
}

# Pure-Dart sync engine
Push-Location app/packages/sync_engine
try {
  dart pub get
  dart format --output=none --set-exit-if-changed lib test
  dart analyze --fatal-infos
  dart test
} finally {
  Pop-Location
}

# Go API
Push-Location server
try {
  $goFiles = (Get-ChildItem -Recurse -Filter *.go -File).FullName
  if ($goFiles) { gofmt -l $goFiles }
  go vet ./...
  go test ./...
} finally {
  Pop-Location
}
```

The Flutter integration test `app/test/integration/deterministic_convergence_harness_test.dart` is included in the ordinary `flutter test` run and uses deterministic in-memory replicas and fault injection; it does not require a server. The live tests below are separate environment-gated checks.

### Environment-gated PostgreSQL checks

The Go PostgreSQL integration tests skip when `STOKSYNC_TEST_DATABASE_URL` is absent. After starting PostgreSQL and applying migrations, run them from `server/` with a local URL assembled from your ignored `.env` values:

```powershell
$env:STOKSYNC_TEST_DATABASE_URL = "postgres://<local-user>:<local-password>@127.0.0.1:5432/<local-db>?sslmode=disable"
Push-Location server
try { go test ./... -count=1 } finally { Pop-Location }
```

This exercises real PostgreSQL persistence, authentication, canonical movement/product transactions, snapshot consistency, change-log cursor allocation, idempotency, and conflict cases. Without the variable, the same command remains an offline test run and reports those integration cases as skipped.

Migration upgrade tests are also opt-in and use temporary databases that are cleaned up by the script:

```powershell
.\server\migrations\test-upgrades.ps1
```

Run this after the root `.env` is configured and the Compose PostgreSQL service is available. Migration smoke and constraint checks are documented in [`server/migrations/README.md`](server/migrations/README.md).

### Live authenticated two-replica test

`app/test/integration/two_device_convergence_test.dart` is skipped unless both variables below are set. It uses two independent in-memory Drift replicas, the real authenticated runtime, HTTP sockets, and the migrated PostgreSQL-backed API. It verifies product pull, offline independent movements, both push orders, cursor-application rollback/recovery, tombstone propagation, ledger-derived balances, and agreement with the server snapshot.

With PostgreSQL migrated and the API running:

```powershell
$env:STOKSYNC_TEST_API_BASE_URI = "http://127.0.0.1:8080"
$env:STOKSYNC_TEST_DATABASE_URL = "postgres://<local-user>:<local-password>@127.0.0.1:5432/<local-db>?sslmode=disable"
Push-Location app
try { flutter test test/integration/two_device_convergence_test.dart } finally { Pop-Location }
```

The test creates a unique disposable account and does not reset or delete shared database data. This is the environment-gated end-to-end check; a normal `flutter test` run should not be used as evidence that the live API path was exercised.

## Reproducible two-device demonstration

This walkthrough demonstrates the user-visible local-first flow on two emulators or physical phones. It requires a running migrated API and a local account. It does not require production services.

1. **Prepare the API.** Complete [Local setup](#local-setup), start PostgreSQL, apply migrations, load `server/.env`, and start `go run ./cmd/api`.
2. **Create a known disposable demo account.** Choose local-only values and pass them to the smoke script; do not use a production account or commit them:

   ```powershell
   $demoEmail = "two-device-owner@example.test"
   $demoPassword = "choose-a-local-demo-password"
   .\server\scripts\api-smoke.ps1 -Email $demoEmail -Password $demoPassword
   ```

   If that email already exists, omit registration on later smoke checks with `-SkipRegister -Email $demoEmail -Password $demoPassword`. The app's login screen uses the same account.
3. **Launch both clients.** Run one client per emulator/phone with the API address reachable from that target. For example, Android emulators use `10.0.2.2`; two physical phones use the computer's LAN IP:

   ```powershell
   # Run this in one terminal per device, changing -d and the URL as needed.
   Push-Location app
   try {
     flutter run -d <device-a> --dart-define=STOKSYNC_API_BASE_URL=http://10.0.2.2:8080
   } finally {
     Pop-Location
   }
   ```

   Each installation has its own durable device identifier. Sign in to the same demo account on both clients and allow the initial sync to complete. Open the **Sync status** card/chip and confirm the local status reaches **Last synced** or **Idle** with no queued operations.
4. **Create and replicate a product.** On device A choose **Add product**, enter a name (and optionally barcode/minimum stock), and save. Use **Sync now** or foreground the app until the operation is applied. On device B refresh/foreground and open the product. This establishes the shared product while both clients are online.
5. **Work offline on both devices.** Enable airplane mode (or otherwise make the API unreachable) on both clients. Open the shared product on device A and choose **Issue**, enter quantity `3`, and save. On device B choose **Issue**, enter quantity `2`, and save. Both screens should update immediately from local SQLite; the sync status should show queued local work rather than losing it.
6. **Reconnect and converge.** Restore network access. Foreground each app or open **Sync status** and choose **Sync now**. Wait for both queued counts to reach zero and for each product detail page to show the same movement history and balance. The two issue movements are both retained, so the combined balance change is `-5`.
7. **Optional conflict demonstration.** While both devices have the same product version, take both offline and edit the same product field to different values. Reconnect and sync device A first, then device B. The first canonical edit wins; device B retains a blocked operation and an unresolved conflict. Open **Conflicts** to inspect the base/local/server values, then use the explicit resolution action. A conflict resolution creates a follow-up operation; it does not rewrite prior history.
8. **Verify persistence.** Force-close and relaunch one client while offline. Its local catalog, movements, queued work, and visible sync status remain available. Reconnect and sync again to confirm the queued operation is eventually reconciled.

For an automated version of the two-replica scenario, use the [live authenticated test](#live-authenticated-two-replica-test). For injected drops, duplicates, reordering, timeouts, and seeded random sequences without PostgreSQL, run `app/test/integration/deterministic_convergence_harness_test.dart`.

## Known v1 limits

- One account owner and full account replication to authenticated devices; no multi-user collaboration, roles, permissions, tenant boundaries, or partial replication.
- Sign-in and initial synchronization require a reachable API. Once local data is bootstrapped, expired credentials block synchronization rather than erasing local data; queued work remains until reauthentication.
- Synchronization is foreground-first. App foreground, local writes, manual refresh, a foreground timer, and connectivity hints trigger sync; guaranteed OS background execution, push-driven sync, WebSockets, and real-time updates are out of scope.
- The API processes bounded sync batches synchronously. Redis, Asynq, and separate background workers are intentionally not part of v1.
- Product deletion is a tombstone, not a hard delete. Stock movements are immutable; corrections append linked reversing movements.
- Barcode/QR scanning, catalog, ledger, conflict, and sync-status flows are implemented, but mobile camera permissions and physical-device networking still require device-specific setup.
- Barcode label printing, media uploads, accounting integrations, and other external inventory integrations are not included.
- Local PostgreSQL, API secrets, and demo credentials in this README are for development only. Deployments must provide TLS, managed secrets, operational retention, and production database controls separately.

## Further documentation

- [Local development and opt-in integration checks](docs/local-development.md)
- [Synchronization protocol](docs/sync-protocol.md)
- [Conflict matrix](docs/conflict-matrix.md)
- [PostgreSQL migrations](server/migrations/README.md)
- [Database access and transaction recipe](server/internal/db/README.md)
- [Architecture decision records](docs/adr/)
- [Requirements](.kiro/specs/stoksync/requirements.md) and [design](.kiro/specs/stoksync/design.md)
