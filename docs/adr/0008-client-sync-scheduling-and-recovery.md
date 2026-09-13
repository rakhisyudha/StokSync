# ADR 0008: Serialized client sync scheduling and recoverable queue states

## Status

Accepted

## Context

The client queue is durable, but a process can stop after an operation is
selected and before its server response or local consequence is persisted. A
second foreground trigger can also arrive while a sync exchange is already in
progress. Retrying only by inspecting in-memory state would either run
concurrent exchanges or strand a pending operation permanently.

## Decision

- Guard each sync cycle with one async mutex. A cycle claims one bounded batch,
  sends it, and hands the response to the later reconciliation seam before the
  next cycle can begin.
- Select only `queued` and `retrying` rows whose `next_attempt_at` is due,
  ordering by durable `local_seq`. Claiming and changing those rows to
  `inflight` happen in one SQLite transaction.
- Treat `inflight` as recoverable, not complete. The startup/cycle recovery
  pass changes abandoned inflight rows back to `queued` without deleting or
  changing their attempt metadata. A response that was committed remotely but
  not locally applied is therefore safe to resend through server idempotency.
- Retry socket/network failures, timeouts, rate limits, server errors, and
  local clock-offset persistence failures using one-based capped exponential
  backoff with bounded jitter. The default range starts at one second and caps
  at five minutes.
- Leave authentication and schema blockers queued for an outer auth/update
  flow. Park malformed requests and non-retryable client/protocol failures in
  the durable `blocked` state with a safe error summary; payloads remain
  available for inspection and later resolution.

## Consequences

- Concurrent foreground, connectivity, and manual triggers cannot overlap a
  push cycle in one process.
- A crash can cause a duplicate delivery, but cannot silently lose a claimed
  operation; the server's `(device_id, op_id)` idempotency record makes the
  duplicate logically safe.
- Retry timing is durable across restart because attempt count, deadline, last
  error, and state are stored in `pending_ops`.
- Removing successfully reconciled rows and recording canonical conflicts stay
  in the response-reconciliation layer rather than in the scheduler.
