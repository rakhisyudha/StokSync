# PostgreSQL migrations

These versioned SQL files are applied by the pinned `migrate/migrate:v4.17.1`
container configured in the repository root `docker-compose.yml`. Migration
`000001` creates the canonical authentication, device, catalog, ledger,
balance-projection, change-feed, idempotency, and sync-cursor tables. Migration
`000002` adds ownership-aware foreign keys, domain checks, active-barcode
uniqueness, the composite idempotency primary key, and indexes for the
server/synchronization access paths.

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
