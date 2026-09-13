# PostgreSQL migrations

These versioned SQL files are applied by the pinned `migrate/migrate:v4.17.1`
container configured in the repository root `docker-compose.yml`. The initial
migration creates the canonical authentication, device, catalog, ledger,
balance-projection, change-feed, idempotency, and sync-cursor tables. Domain
checks, foreign keys, and secondary indexes are intentionally reserved for the
follow-up schema migration in task 2.2.

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
