# ADR 0006: Typed pgx data access without a generator

- Status: Accepted
- Date: 2026-09-13

## Context

StokSync's synchronization transactions need explicit PostgreSQL statements,
ownership predicates, transaction boundaries, and exact idempotency/change-log
semantics. The repository does not yet have a sqlc installation or generation
command, so adding generated files without a reproducible toolchain would make
schema changes difficult to review and reproduce.

## Decision

Use the pinned `github.com/jackc/pgx/v5` module and its `pgxpool` package. Keep
static, parameterized SQL and typed result/parameter structs in
`server/internal/db`. The `DBTX` interface is the common executor for a pool or
transaction, while `WithTx` and `WithTxResult` own begin/commit/rollback
behavior.

The data-access layer includes user-scoped product queries, active-product
immutable movement insertion, projection increment/upsert, change-log sequence
allocation and reads, and composite `(device_id, op_id)` sync-operation
idempotency insertion/lookup. The SQL repeats ownership conditions where a
service needs a user boundary, while migrations remain responsible for
relational integrity and uniqueness.

If sqlc is introduced later, generated queries may replace the hand-written
mappings provided the service-facing contracts and transaction invariants are
retained.

## Consequences

- SQL and ownership behavior are reviewable in source control now, with no
  generator dependency or generated-code drift.
- Interface-backed tests can verify transaction rollback/commit behavior and
  representative mappings without PostgreSQL.
- PostgreSQL integration coverage remains opt-in and validates the actual
  migration schema and transaction behavior.
- Query code must be maintained when migrations change; a future sqlc adoption
  should add a pinned generation command before replacing this layer.
