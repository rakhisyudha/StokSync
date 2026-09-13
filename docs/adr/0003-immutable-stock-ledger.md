# ADR 0003: Use an immutable signed stock ledger as inventory truth

## Status

Accepted

## Context

Stock changes can originate on multiple devices while offline, be retried after a lost response, and later require correction. A mutable quantity field alone cannot preserve the source of a balance, reliably merge independently created movements, or provide an audit trail for corrections.

The system must retain inventory history, avoid duplicate logical application of retried operations, and calculate balances consistently across client and server replicas.

## Decision

Model inventory as an append-only ledger of signed stock movements.

- Every movement has a client-generated identifier, product identifier, non-zero signed delta, movement kind, occurrence time, originating device, and optional note.
- Current quantity is derived as the sum of retained movement deltas for a product.
- `product_balances` may be materialized for read performance, but it is a rebuildable projection and never the source of truth.
- Stock movement rows are never edited or deleted. A correction appends a linked reversing `adjust` movement with the opposite delta.
- Stocktakes retain both the counted quantity and their resulting delta; the server recomputes that delta against the canonical ledger when applying the stocktake.

## Consequences

- Independent offline movements converge by unioning ledger entries and are naturally auditable.
- Corrections preserve historical intent instead of rewriting inventory history.
- Both local and server projections require transactional maintenance and periodic rebuild verification.
- Storage grows with movement history, so retention, indexing, and query design must support historical data.
- APIs and UI flows must create new movements for adjustments and reversals rather than exposing mutation or deletion of prior entries.
