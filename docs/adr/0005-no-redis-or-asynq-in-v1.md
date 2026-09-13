# ADR 0005: Exclude Redis and Asynq from v1

## Status

Accepted

## Context

v1 needs reliable request-time synchronization, not an independently scaled background job system. The sync endpoint can process bounded operation batches synchronously inside PostgreSQL transactions. Introducing Redis and Asynq now would add an operational datastore, worker lifecycle, failure modes, and distributed delivery semantics before there is a concrete asynchronous workload.

The v1 scope also excludes real-time sockets, push-notification-driven synchronization, guaranteed operating-system background sync, and separate background workers.

## Decision

Do not include Redis, Asynq, or separate background worker processes in v1.

- Execute v1 synchronization work synchronously in the Go API request path.
- Keep durable data and synchronization correctness within PostgreSQL transactions.
- Trigger mobile synchronization from foreground lifecycle events, local writes, manual refresh, and connectivity hints; background execution remains opportunistic rather than a correctness requirement.
- If a genuine asynchronous workload emerges, first evaluate a PostgreSQL-backed job queue that transactionally enqueues work and uses `FOR UPDATE SKIP LOCKED` for workers.
- Re-evaluate Redis and Asynq only when requirements demonstrate a need for capabilities such as distributed rate limiting, caching, delayed jobs, or substantially higher worker throughput.

## Consequences

- v1 has fewer services to deploy, secure, monitor, back up, and recover.
- Request handlers must keep synchronization batches bounded and efficient because they run synchronously.
- Features that require asynchronous processing must either remain out of scope or justify a deliberate architecture change.
- A future worker system must preserve transactional handoff and idempotency guarantees instead of relying on best-effort delivery.
