# StokSync — Implementation Tasks

## Execution rules

- Implement tasks in order unless a task explicitly identifies safe parallel work.
- Do not proceed past a milestone until its listed validation passes.
- Keep application UI local-first: domain features must write through repositories to Drift and never wait on an API response.
- Keep `sync_engine` free of Flutter imports and provide tests for each reliability invariant before integrating the UI trigger.
- Record material architecture changes as ADRs under `docs/adr/` and update `docs/sync-protocol.md` or `docs/conflict-matrix.md` when behavior changes.
- Stop after completing the last task of a milestone. Do not start any task from the next milestone in the same run, even if time/context remains.
- After stopping, write a summary of every file created or modified and every notable decision made since the previous milestone checkpoint. Then tell the user the milestone is ready to commit/push and wait for explicit go-ahead before continuing to the next milestone's tasks.

## Milestone 0 — Foundation

- [x] 0.1 Create the repository layout: `app/`, `server/`, `docs/adr/`, and local-development configuration. Keep the existing `.kiro/specs/stoksync/` files as the authoritative plan.
- [x] 0.2 Initialize the Flutter application and a separate pure-Dart `sync_engine` package. Add Riverpod, Drift/SQLite, secure storage, connectivity handling, and `mobile_scanner` using pinned compatible versions.
- [x] 0.3 Initialize the Go module, Chi router, configuration loading, structured logging, health/readiness endpoints, and graceful shutdown using `net/http` conventions.
- [x] 0.4 Add Docker Compose for a local PostgreSQL instance, environment templates without secrets, and a migration runner (`goose` or `golang-migrate`).
- [x] 0.5 Add client and server formatting, static analysis, test commands, and CI. Do not add Redis, Asynq, workers, WebSockets, or multi-tenancy.
- [x] 0.6 Add initial ADRs for: local-first architecture, Drift over Hive/Isar, immutable stock ledger, Go/Chi/PostgreSQL, and no Redis/Asynq in v1.

**Milestone validation:** From a clean clone, documented commands start Postgres, apply migrations, run Flutter analysis/tests, and run Go tests. The API health endpoint responds successfully.

## Milestone 1 — Local-only Flutter inventory app

- [x] 1.1 Define Drift tables and migrations for products, stock movements, materialized balances, pending operations, sync state, and conflicts.
- [x] 1.2 Implement local UUIDv7 generation and durable device identity.
- [x] 1.3 Implement repositories that atomically write domain changes, local balance projections, and pending operations in one SQLite transaction.
- [x] 1.4 Implement a rebuildable local balance projection from the ledger and test it against incremental updates.
- [x] 1.5 Build Riverpod providers over Drift `watch()` queries for active products, product details, movement history, low-stock products, and sync summary.
- [x] 1.6 Build product browse/search/detail/create/edit/soft-delete flows backed only by local data.
- [x] 1.7 Integrate `mobile_scanner`: permissions, allowed formats, duplicate-read debounce, matching-product navigation, and unknown-barcode product creation.
- [x] 1.8 Build receive, issue, adjustment, reversal, and stocktake entry flows with notes and validation.
- [x] 1.9 Add a local sync-status shell showing queued count, conflicts count, and last known status, even before remote sync exists.

**Milestone validation:** In airplane mode, create products, scan or manually enter a barcode, record movements, force-close/relaunch, and verify all data remains. Rebuild balances and prove they equal the sum of each product ledger. Low-stock queries update reactively.

## Milestone 2 — Go/Chi server and canonical data model

- [x] 2.1 Create PostgreSQL migrations for users, devices, refresh tokens, products, stock movements, product balances, `change_log`, `sync_ops`, and `sync_seq_counter`.
- [x] 2.2 Add database constraints and indexes: non-zero deltas, allowed movement kinds, foreign keys, active-barcode partial uniqueness, product version, and `(device_id, op_id)` idempotency primary key.
- [x] 2.3 Implement `pgx` connection pooling and `sqlc` queries (or explicitly documented equivalent) for domain and synchronization transactions.
- [x] 2.4 Implement password hashing, login, device registration, access-token issuance, refresh-token rotation/revocation, and Chi authentication middleware.
- [x] 2.5 Implement canonical product and immutable movement transaction services. Maintain server `product_balances` transactionally and provide a projection rebuild verification command/test.
- [x] 2.6 Implement transaction-scoped change-log sequence allocation through `sync_seq_counter`; never rely on `BIGSERIAL` as the sync cursor.
- [x] 2.7 Implement `GET /v1/snapshot` using a consistent snapshot and return products, movements, tombstones, and cursor.
- [x] 2.8 Write API protocol documentation and a reproducible HTTP test collection/script covering login, refresh, snapshot, and health.

**Milestone validation:** A clean local database can login/register a device, create canonical domain data through the service layer, and return a consistent snapshot. A concurrent Postgres integration test demonstrates that committed change-log cursors are ordered and no committed entries are skipped.

## Milestone 3 — Reliable push synchronization

- [x] 3.1 Define versioned JSON DTOs for sync requests, operations, operation results, change entries, and responses. Enforce request limits and schema-version handling.
- [x] 3.2 Implement `POST /v1/sync` in Chi with authenticated user/device validation and per-operation transactions.
- [x] 3.3 Implement `add_movement`, `upsert_product`, and `delete_product` operations on the server. Persist an idempotency outcome and its response atomically with each operation.
- [x] 3.4 On duplicate `(device_id, op_id)`, return the originally stored operation response exactly and do not reapply domain logic.
- [x] 3.5 Implement the pure Dart transport interface, HTTP implementation, operation serialization, response decoding, and server-time clock-offset persistence.
- [x] 3.6 Implement a sync mutex, due FIFO operation selection, retry classification, exponential backoff with jitter, and interruption-safe pending-operation states.
- [x] 3.7 Reconcile successful and rejected push results into Drift; remove applied queue items only in a transaction that persists their canonical consequence. Store terminal errors/conflicts.
- [x] 3.8 Add unit/integration tests for duplicate delivery, lost response, partial-batch success, server error retries, and retry persistence across restart.

**Milestone validation:** Intentionally lose a response after the server commits a movement. Retrying the same operation one or many times leaves exactly one canonical movement and returns the original outcome. A malformed operation cannot prevent valid operations in the same batch from completing.

## Milestone 4 — Pull, bootstrap, and two-device convergence

- [x] 4.1 Implement server change-feed reads ordered by `seq > cursor`, bounded by `max_changes`, returning `next_cursor` and `has_more`.
- [x] 4.2 Implement snapshot bootstrap on the client: write all snapshot data, balances/projections, and initial cursor in one SQLite transaction.
- [x] 4.3 Implement idempotent remote upsert/tombstone application for products and movements.
- [x] 4.4 Advance the local cursor only in the same SQLite transaction as the complete applied change page.
- [x] 4.5 Complete the push-then-pull loop with pagination until `has_more` is false.
- [x] 4.6 Connect sync triggers to application foreground, debounced local writes, manual refresh, foreground interval, and connectivity hints. Confirm reachability through health/sync rather than interface state alone.
- [ ] 4.7 Implement access-token refresh-once behavior and blocked-sync state without wiping local data.
- [ ] 4.8 Build a deterministic two-device integration harness using independent local stores and a real Postgres database.

**Milestone validation:** Two clients for one account create a product and independent movements while offline, then synchronize in either order. Each client and the server converge to the same products, ledger, tombstones, and balances. Killing a client during change application cannot permanently skip a remote change.

## Milestone 5 — Conflicts and resolution UX

- [ ] 5.1 Add canonical product version checks using `base_version` and return structured version-conflict responses with current server state.
- [ ] 5.2 Implement a three-way field merge for disjoint product edits, producing an explicit merged follow-up operation using the current server version.
- [ ] 5.3 Implement and test duplicate barcode conflict handling based on the active-barcode unique index.
- [ ] 5.4 Implement and test delete-wins behavior for edit-versus-tombstone races.
- [ ] 5.5 Implement stocktake processing that stores `counted_qty` and recomputes its delta against the canonical ledger in the server transaction.
- [ ] 5.6 Document and implement deterministic treatment of concurrent stocktakes, including an informational or resolvable record for stale/displaced intent.
- [ ] 5.7 Build the Flutter conflict list/detail/resolution flows showing reason, base/local/server payloads, and the explicit follow-up action.
- [ ] 5.8 Implement the sync-status chip and detail screen showing state, pending count, conflicts, last successful sync, and error summary.
- [ ] 5.9 Add automated scenarios for every row in the documented conflict matrix.

**Milestone validation:** Reproduce all acceptance scenarios in `requirements.md`, including overlapping/disjoint product edits, barcode collision, tombstone race, concurrent stocktakes, and offline expired-token behavior. No rejected intent is silently discarded.

## Milestone 6 — Quality, demo readiness, and documentation

- [ ] 6.1 Add Drift migration tests and server migration-upgrade tests from representative previous schemas.
- [ ] 6.2 Expand the convergence harness with dropped requests/responses, duplicates, reordering, timeouts, retries, and random operation sequences; assert eventual convergence and ledger-derived balances.
- [ ] 6.3 Add client/server structured logging and safe diagnostics, excluding credentials and tokens.
- [ ] 6.4 Complete README documentation: local setup, architecture diagram, data model, protocol overview, test commands, known v1 limits, and two-device demonstration steps.
- [ ] 6.5 Record ADRs for idempotency, cursor allocation, conflict behavior, stocktake policy, and foreground-first sync constraints.
- [ ] 6.6 Manually validate the demo on two physical phones or emulators: scan, offline operations, restart persistence, convergence, and conflict resolution.

**Milestone validation:** A reviewer can clone the repository, run the documented environment, use two clients offline/online, observe status/conflicts, and run automated convergence tests without author assistance.

## Deferred v2 backlog

- [ ] V2.1 Introduce multi-tenant ownership (`tenant_id`), tenant-scoped unique indexes, authorization, and PostgreSQL row-level security.
- [ ] V2.2 Add shared organizations, roles, invitations, and multi-user audit attribution.
- [ ] V2.3 Add a Postgres-backed worker queue for genuine asynchronous jobs using transactionally enqueued jobs and `FOR UPDATE SKIP LOCKED`.
- [ ] V2.4 Evaluate Redis and Asynq only after a demonstrated need for distributed rate limiting, caching, delayed jobs, or higher worker throughput.
- [ ] V2.5 Add FCM/APNs data-message nudges and opportunistic mobile background sync; retain foreground sync as the correctness baseline.
- [ ] V2.6 Add partial replication/sync rules only when catalog size or privacy requirements demand it.
