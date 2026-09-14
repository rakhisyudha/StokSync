# ADR 0012: Preserve conflict intent and resolve it explicitly

- Status: Accepted
- Date: 2026-09-13

## Context

Offline devices can edit the same product, claim the same barcode, race a
product tombstone, or submit operations based on stale state. Treating every
rejection as a retry or silently replacing local data would lose user intent
and make convergence depend on arrival order. Independent ledger movements
have different semantics from versioned product fields and must not be forced
through a generic conflict dialog.

The server is canonical for ownership, versions, uniqueness, tombstones, and
stocktake outcomes. The client must retain enough base, local, and server data
to explain a rejected operation and must make any user-selected resolution a
new local operation.

## Decision

Use domain-specific deterministic policies and durable local conflict history.

- Independently created valid stock movements are both retained and included
  in the ledger balance; being created offline is not itself a conflict.
- Product edits use optimistic versions. The first accepted edit establishes
  the canonical version. A stale edit is compared field-by-field using
  `base -> local` and `base -> server`: only disjoint changes are auto-merged,
  and the client queues an explicit merged follow-up at the current server
  version. Overlapping changes remain unresolved even when the values happen
  to be equal.
- The active-barcode unique index rejects a duplicate and returns the canonical
  owning product. The contender's local payload remains available; removing or
  changing the barcode is an explicit follow-up choice.
- A product tombstone wins against an edit in either arrival order. A rejected
  edit remains blocked with its local/base/server history, and the client
  applies the canonical tombstone without creating a resurrection operation.
  The user may mark the conflict reviewed.
- Corrections append a linked reversing movement; they never edit or delete
  prior ledger rows.
- Concurrent stocktakes follow [ADR 0009](0009-deterministic-stocktake-conflicts.md):
  the server orders the corrected occurrence time and UUIDv7 movement id,
  recomputes accepted deltas from the locked canonical ledger, and records
  displaced intent rather than rewriting history.

For every terminal rejection, the client keeps the pending operation blocked
and records a conflict row containing the local payload, optional base
snapshot, canonical server state or structured outcome, reason, and resolution
status. The conflict list exposes unresolved records. When a resolution changes
domain intent, it is performed locally in one SQLite transaction that updates
the optimistic row, queues a new UUIDv7 operation with a new FIFO sequence, and
marks the original conflict resolved; the original operation and conflict
history are not deleted or rewritten. An acknowledgement-only action, such as
reviewing a delete-wins conflict, marks the retained conflict resolved without
queueing a resurrection operation. Stocktake displacement is retained as
`stocktake_displaced` history and is not automatically replayed.

An automatic disjoint merge is the narrow exception to interactive resolution:
it still preserves the rejected source operation and conflict record, marks
that record `auto_merged`, and creates a durable follow-up operation with its
own base snapshot so a later conflict can be classified again.

## Consequences

- Conflict outcomes are deterministic and explainable across devices, while
  valid independent movements continue to converge without unnecessary UI.
- Local work is never discarded merely because credentials, reachability, or a
  canonical version is unavailable.
- Resolution code remains local-first and uses the normal FIFO queue and
  idempotency semantics; it does not write remote state directly.
- Conflict UI and storage are part of the correctness boundary, not just
  presentation. Schema/protocol changes must preserve the reason and canonical
  state needed for inspection.
- Adding a new domain conflict policy requires updating the source-of-truth
  matrix and an ADR or an amendment to this decision.

## Related decisions and documentation

- [ADR 0003: Immutable signed stock ledger](0003-immutable-stock-ledger.md)
- [ADR 0008: Serialized client sync scheduling and recoverable queue states](0008-client-sync-scheduling-and-recovery.md)
- [ADR 0009: Deterministic concurrent stocktake policy](0009-deterministic-stocktake-conflicts.md)
- [Conflict matrix](../conflict-matrix.md)
- [Synchronization protocol](../sync-protocol.md)
- [Requirements FR-14–FR-17](../../.kiro/specs/stoksync/requirements.md#35-conflict-behavior)
- [Local conflict resolution repository](../../app/lib/data/local/conflict_resolution_repository.dart)
