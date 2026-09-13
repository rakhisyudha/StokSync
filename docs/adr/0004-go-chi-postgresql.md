# ADR 0004: Build the server with Go, Chi, and PostgreSQL

## Status

Accepted

## Context

The backend must offer a small HTTPS API for authentication, snapshot bootstrap, health checks, and reliable push/pull synchronization. It must process each submitted operation independently and transactionally, enforce relational constraints, retain idempotency outcomes, and expose a durable ordered change feed.

The server needs explicit control of transactions and concurrency-critical SQL without requiring a large framework abstraction.

## Decision

Use Go for the API, Chi for HTTP routing and middleware, and PostgreSQL as the canonical server database.

- Compose the API with Go's standard `net/http` conventions and Chi routing/middleware.
- Use PostgreSQL transactions for domain writes, idempotency results, balance projection updates, and change-log records.
- Use explicit SQL through `pgx` and preferably `sqlc` for synchronization and domain transactions; do not hide concurrency-sensitive behavior behind a general ORM.
- Manage server schema evolution with versioned migrations.
- Enforce server-side foreign keys, non-zero movement deltas, allowed movement kinds, active-barcode uniqueness, product versions, and `(device_id, op_id)` idempotency uniqueness.

## Consequences

- The deployment is a focused Go API plus PostgreSQL, with conventional HTTP middleware and a small framework surface.
- PostgreSQL provides the transactional guarantees, constraints, JSON payload storage, and concurrency behavior required for canonical synchronization.
- Database access code must explicitly define transaction boundaries and concurrency handling, especially for idempotency and change-log cursor allocation.
- The team must maintain Go tooling and PostgreSQL migrations alongside the Flutter client.
