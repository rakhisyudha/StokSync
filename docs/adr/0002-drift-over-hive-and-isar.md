# ADR 0002: Use Drift on SQLite instead of Hive or Isar

## Status

Accepted

## Context

The mobile client persists related products, immutable stock movements, balance projections, pending synchronization operations, cursor state, and conflict records. A single user action must atomically update domain data and its queued synchronization operation. The application also needs relational queries, reactive reads, referential integrity where practical, and versioned migrations.

Hive and Isar are viable local stores, but their object/document-oriented models would require more custom coordination for the relational ledger, transactional queue invariants, SQL-style reporting, and future interoperability with SQLite-oriented synchronization tooling.

## Decision

Use Drift as the Flutter persistence layer over SQLite.

- Define the local domain, projection, queue, cursor, and conflict tables in Drift.
- Use SQLite transactions to atomically persist local domain mutations with pending synchronization operations and to atomically apply remote changes with cursor advancement.
- Use Drift `watch()` queries as the reactive data source for Riverpod-backed UI state.
- Version local schema changes with Drift migrations.

## Consequences

- The client gains relational modeling, query expressiveness, durable transactions, migration support, and reactive streams from one local database.
- Drift table definitions, generated code, and migration tests become part of the mobile build and maintenance workflow.
- SQLite is the persisted client data format; new storage features must preserve the local-first transactional invariants.
- Hive and Isar are not included in the v1 application, avoiding duplicate persistence models and migration paths.
