# ADR 0001: Adopt a local-first architecture

## Status

Accepted

## Context

StokSync must remain useful when a device has no network connection. Users need to browse their replicated catalog and record inventory changes without waiting for an API response. Synchronization must also tolerate app termination, dropped responses, duplicate delivery, and concurrent use on multiple devices.

A network-first application would make normal inventory work depend on reachability and would leave local changes vulnerable to loss or ambiguous remote outcomes.

## Decision

The Flutter application is local-first:

- Screens read inventory state exclusively from the local SQLite database through Drift queries.
- Domain repositories apply every user mutation locally and enqueue one immutable synchronization operation in the same SQLite transaction.
- Riverpod reacts to local database streams so the UI updates immediately after the local commit.
- A serialized sync engine exchanges queued operations and remote changes with the API asynchronously; connectivity events are wake-up hints rather than proof that the server is reachable.
- The client applies remote changes and advances its durable synchronization cursor in one SQLite transaction.

The server is canonical for cross-device convergence, constraints, and conflict outcomes, but it is not on the interactive read/write path for an individual local action.

## Consequences

- The app remains operational offline after authentication and bootstrap, with pending work preserved until synchronization succeeds.
- Local schema migrations, transaction boundaries, queue durability, and crash-safe cursor application are correctness-critical.
- UI features must use repositories and local data rather than mutate remote state directly.
- Sync state, pending operations, and conflicts must be visible to users because eventual synchronization can be delayed or blocked.
- Full account replication is acceptable in v1 for catalogs ranging from hundreds to low thousands of products; partial replication is deferred.
