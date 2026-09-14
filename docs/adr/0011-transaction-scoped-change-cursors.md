# ADR 0011: Allocate commit-ordered change cursors in the transaction

- Status: Accepted
- Date: 2026-09-13

## Context

Clients advance a durable cursor through the server change feed. A cursor
allocation that is visible before its transaction commits can create a gap
when the transaction rolls back. Independent sequence allocation can also
make a later-committing transaction receive a lower cursor than a transaction
that commits first. Either behavior can cause a consumer to skip a committed
change if it treats the cursor as progress through an ordered feed.

The v1 API has enough write volume to serialize allocation on one PostgreSQL
row. Correctness is more important than avoiding this small critical section.

## Decision

Allocate `change_log.seq` from the singleton `sync_seq_counter` row inside the
same PostgreSQL transaction as the canonical mutation and change-log insert.

- Increment the counter with `UPDATE sync_seq_counter SET last_seq = last_seq +
  1 WHERE id = 1 RETURNING last_seq`; the row lock serializes concurrent
  allocators.
- Insert the returned sequence into `change_log` before the enclosing
  transaction commits. The domain mutation, rebuildable balance projection,
  idempotency outcome, counter update, and change-log row therefore share one
  commit boundary.
- Never use `BIGSERIAL`/`nextval()` as the client-visible cursor source and do
  not allow callers to supply a cursor to the low-level change-log insert.
- A rollback restores the counter and removes the uncommitted event. A
  committed event has a sequence ordered by the serialized transaction
  allocation, with no rollback-created gaps in the global committed stream.
- Rejected operations that do not change canonical state do not allocate a
  change-log sequence.
- Change-feed reads select `seq > cursor`, order ascending, and use the last
  returned sequence as `next_cursor`. A client account may see numeric gaps
  because the feed is account-scoped and hides other users' changes; those gaps
  are not missing changes and cursors are opaque high-water marks.
- Snapshot bootstrap reads replicated rows and the high-water counter in one
  repeatable-read view so the initial cursor describes the same committed data.

The allocator's serialization cost is accepted for v1. Concurrent transaction
behavior is covered by the PostgreSQL integration checks described in the
repository documentation.

## Consequences

- A client cursor cannot advance past an uncommitted or rolled-back change.
- Every committed change is reachable by a consumer that continues with
  `seq > cursor`, including after retries or process interruption.
- Writers contend briefly on the allocator row, which is an intentional v1
  trade-off. A future scale change would require a new decision and preserved
  cursor semantics.
- Feed consumers must not assume per-account sequence contiguity or derive
  counts from cursor differences.

## Related decisions and documentation

- [ADR 0004: Go, Chi, and PostgreSQL](0004-go-chi-postgresql.md)
- [ADR 0010: Replay durable synchronization operation outcomes](0010-sync-operation-idempotency.md)
- [Synchronization protocol (cursor and pagination)](../sync-protocol.md)
- [Design: Change feed and cursor correctness](../../.kiro/specs/stoksync/design.md#6-change-feed-and-cursor-correctness)
- [Database transaction recipe](../../server/internal/db/README.md#transaction-recipe)
- [Cursor allocator migration](../../server/migrations/000001_initial_schema.up.sql)
