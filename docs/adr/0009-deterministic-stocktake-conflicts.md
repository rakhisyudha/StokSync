# ADR 0009: Deterministic concurrent stocktake policy

- Status: Accepted
- Date: 2026-09-13

## Context

Offline devices can submit stocktakes based on the same stale balance. Applying
an absolute count with an arrival-order delta would make the final quantity
depend on network delivery order. The stock ledger is append-only, so a policy
must not revise or remove an earlier movement.

## Decision

For one product, the canonical stocktake ordering key is
`(occurred_at, movement_id)` in ascending order, with the greatest key treated
as the current canonical observation. `occurred_at` is the server-normalized
(corrected) occurrence time and `movement_id` is the UUIDv7 client identifier
tie-breaker. The product row lock serializes each decision.

A stocktake whose key is greater than the current canonical stocktake is
accepted and its delta is recomputed as `counted_qty - current ledger balance`.
The previous canonical intent remains immutable and is reported as displaced.
A stocktake whose key is not greater is rejected with reason
`stocktake_displaced`; the response contains the canonical winner, current
canonical balance, and the incoming stale intent. The rejected intent is not
silently discarded: the client stores it in conflict history and may mark it
reviewed. Accepted transitions include the displaced intent in both the
operation result and movement change payload so every replica can preserve the
same audit record.

This policy means two stale stocktakes converge to the same final quantity
regardless of arrival order. If the lower key arrives first, the higher key's
recomputed delta moves the ledger to the higher count. If the higher key arrives
first, the lower key is rejected. Existing ledger rows are never updated or
deleted, and materialized balances remain transactionally maintained from the
appended deltas.

## Consequences

- Sync operation results and movement change payloads have optional structured
  `stocktake_outcome` metadata.
- Flutter stores displaced intents as `stocktake_displaced` conflict history,
  including local intent and canonical outcome. A generic review action is
  sufficient; replaying the stale count is not automatic.
- The canonical balance remains the sum of retained immutable movement deltas.
- A client must understand the new optional metadata, while older v1 clients
  that reject unknown fields require the normal schema/version rollout path.
