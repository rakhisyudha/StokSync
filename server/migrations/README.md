# PostgreSQL migrations

These versioned SQL files are applied by the pinned `migrate/migrate:v4.17.1`
container configured in the repository root `docker-compose.yml`. Migration
`000001` creates the canonical authentication, device, catalog, ledger,
balance-projection, change-feed, idempotency, and sync-cursor tables. Migration
`000002` adds ownership-aware foreign keys, domain checks, active-barcode
uniqueness, the composite idempotency primary key, and indexes for the
server/synchronization access paths. Migration `000003` adds case-insensitive
account-email uniqueness, non-empty credential/digest checks, and unique
refresh-token digests required for safe rotation.

## Reproducible local smoke check

After copying the root `.env.example` to `.env`, start PostgreSQL and apply the
migrations:

```powershell
docker compose up -d postgres
docker compose --profile tools run --rm migrate
```

The following command verifies that all task 2.1 tables exist and that the
transaction-scoped cursor allocator has its required seed row:

```powershell
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema = ''public'' AND table_name IN (''users'', ''devices'', ''refresh_tokens'', ''products'', ''stock_movements'', ''product_balances'', ''change_log'', ''sync_ops'', ''sync_seq_counter''); SELECT id, last_seq FROM sync_seq_counter;"'
```

The expected output is a table count of `9`, followed by `1|0`. The migration
runner records the applied version in `schema_migrations`; rerunning the `up`
command is safe because the runner tracks applied versions.

Authentication-specific constraints can be checked with:

```powershell
Get-Content server/migrations/validate_auth.sql |
  docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

A successful run prints `000003 authentication validation passed` and leaves
the database unchanged.

## Constraint validation

`validate_constraints.sql` inserts valid fixture rows, checks non-zero deltas,
allowed movement kinds, product versions, ownership-aware foreign keys, active
barcode behavior, and composite idempotency semantics, then rolls everything
back. Run it after applying the migrations:

```powershell
Get-Content server/migrations/validate_constraints.sql |
  docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

A successful run prints `000002 constraint validation passed` and leaves the
database unchanged.

## Migration upgrade tests

`test-upgrades.ps1` creates disposable PostgreSQL databases, applies the
pinned `golang-migrate` runner only through migration 000001 or 000002, loads a
representative previous-schema fixture, upgrades to the latest migration, and
runs assertions over preserved catalog, tombstone, stocktake, balance,
change-log, refresh-token, and rejected-sync-operation data. It also probes the
constraints and indexes introduced by the remaining migrations. The temporary
databases are dropped in a `finally` block and the existing development
PostgreSQL service is left running.

Run it from the repository root after Docker Compose has loaded the local
`.env` values (the script starts PostgreSQL if needed):

```powershell
.\server\migrations\test-upgrades.ps1
```

The two scenarios cover v1 -> latest (including 000002 and 000003) and v2 ->
latest (the 000003 upgrade path). Ordinary `go test ./...` remains offline;
this opt-in test uses the same pinned migration container as the documented
local migration command.
