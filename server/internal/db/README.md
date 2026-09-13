# PostgreSQL data access

The server uses `github.com/jackc/pgx/v5/pgxpool` at the pinned version in
`server/go.mod`. `db.Open` parses the database URL, applies the configured pool
bounds/lifetimes, and returns a pool that must be closed by the process
composition root. Pool creation is lazy; `Pool.Ping` is wired to `/v1/ready`,
so liveness can remain available while PostgreSQL is temporarily unavailable.

## Typed query approach

The repository does not currently run the `sqlc` generator. `internal/db`
therefore uses an explicitly documented sqlc-equivalent implementation:

- SQL statements are static package constants in `queries.go` and all values
  are passed as positional parameters.
- `Queries` exposes typed parameter and result structs for products, immutable
  stock movements, product-balance projections, change-log events, and sync
  idempotency outcomes.
- `DBTX` is the narrow common interface implemented by `*pgxpool.Pool` and
  `pgx.Tx`; this keeps read queries pool-bound and lets mutation queries bind to
  a transaction in tests and services.
- Scan functions convert pgx nullable types into Go pointers and copy JSON
  response/payload bytes before returning them.
- Ownership predicates are included in the SQL, in addition to the migration
  foreign keys. Movement insertion only selects an active product owned by the
  authenticated account; product reads/edits, balances, change-log events,
  and sync-operation idempotency are user-scoped.

This keeps the SQL reviewable and parameterized without adding a codegen step
that is not yet part of the repository toolchain. If sqlc is introduced later,
its generated `DBTX`/`Queries` API can replace the hand-written mappings while
preserving the service-facing parameter and result contracts.

## Transaction recipe

Use `Pool.WithTx` for any operation that changes canonical state:

```go
err := pool.WithTx(ctx, func(q *db.Queries) error {
    movement, err := q.InsertStockMovement(ctx, movementParams)
    if err != nil {
        return err
    }
    if _, err := q.IncrementProductBalance(ctx, balanceParams); err != nil {
        return err
    }
    seq, err := q.AllocateChangeSequence(ctx)
    if err != nil {
        return err
    }
    _, err = q.InsertChangeLog(ctx, changeLogParams(seq, movement))
    return err
})
```

`WithTx` commits only after the callback returns nil and rolls back callback or
commit failures. `sync_seq_counter` allocation and the corresponding
`change_log` insert are intentionally exposed as separate calls so a later
sync service can keep them in the same transaction as its domain mutation.
`TryInsertSyncOperation` uses `ON CONFLICT (device_id, op_id) DO NOTHING`;
`inserted == false` means the caller must read the stored outcome and must not
reapply domain logic.

## Integration test

Unit tests use the `DBTX` and `TxBeginner` interfaces. The PostgreSQL test is
opt-in and expects migrations 000001 and 000002 to have been applied:

```powershell
$env:STOKSYNC_TEST_DATABASE_URL = "postgres://stoksync:password@127.0.0.1:5432/stoksync?sslmode=disable"
go test ./internal/db -run TestPostgresPersistenceIntegration -count=1
```

Without that environment variable the integration test is skipped; normal
`go test ./...` remains fully offline.
