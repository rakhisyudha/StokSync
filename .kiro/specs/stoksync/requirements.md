# StokSync — Requirements

## 1. Purpose and scope

StokSync is an offline-first Android/iOS inventory application for one account operating across multiple devices. A user can scan product barcodes or QR codes, maintain a product catalog, record stock changes with notes, and continue working without network access. Each device stores a complete local replica of the account's catalog and stock ledger, then converges with the backend when connectivity is available.

### In scope for v1

- One account owner using two or more devices.
- One organization/inventory deployment; no tenant boundaries or shared-team collaboration.
- Full data replication to every authenticated device for catalogs of hundreds to low thousands of products.
- Product catalog management, barcode/QR scanning, immutable stock movements, current balances, and low-stock visibility.
- Account authentication, device registration, offline operation, reliable queued synchronization, conflict recording/resolution, and a visible sync status.
- A Go API using Chi, PostgreSQL, and a Flutter client using Riverpod, Drift/SQLite, and `mobile_scanner`.

### Explicitly out of scope for v1

- Multi-user collaboration, roles, permissions, multi-tenancy, and row-level security.
- Partial replication / user-selectable sync subsets.
- Real-time sockets, push-notification-driven sync, and guaranteed operating-system background sync.
- Redis, Asynq, and separate background workers.
- Barcode label printing, media uploads, accounting integrations, and hard deletes.

## 2. Product principles

1. **Local-first UI:** Screens read from the local SQLite database only. Network availability must not be required to browse or mutate locally replicated inventory data.
2. **Ledger as truth:** Stock quantity is derived from immutable signed stock movements, never overwritten as a mutable product quantity.
3. **Reliable convergence:** Retrying a sync request after a timeout or lost response must never duplicate a stock movement or product mutation.
4. **Auditable behavior:** Corrections are new, linked movements rather than edits to historical movements. Deletions are tombstones.
5. **Honest sync state:** The app must expose pending work, retrying/blocked state, and conflicts instead of silently discarding data.

## 3. Functional requirements

### 3.1 Authentication and devices

**FR-1 — Sign in**

- The system shall let a user sign in with email and password when online.
- The backend shall issue a short-lived access token and a rotating, long-lived refresh token bound to a registered device.
- The mobile client shall store tokens only in secure device storage.

**FR-2 — Offline access**

- After a successful sign-in and initial synchronization, the app shall allow the user to access locally replicated data and create local changes while offline.
- An expired access or refresh token shall block synchronization only; it shall not erase local data or force a local logout.
- If a user tries to log out with queued operations, the app shall require explicit confirmation and explain that unsynchronized changes will remain local until the account is reauthenticated.

**FR-3 — Device identity**

- The client shall create and persist one UUIDv7 device identifier per installation.
- Every synchronization request and locally originated change shall identify its originating device.
- The backend shall track device registration and last-seen time for the authenticated account.

### 3.2 Product catalog

**FR-4 — Product lifecycle**

- The user shall be able to create, view, edit, search, and soft-delete products while online or offline.
- A product shall contain a client-generated UUIDv7 id, optional barcode, optional SKU, required name, optional description/category, unit, optional minimum-stock threshold, version, timestamps, and deletion state.
- A product barcode shall be unique among non-deleted products on both client and server.
- Deleting a product shall hide it from active catalog results but preserve it and its historical stock movements for auditability and synchronization.

**FR-5 — Barcode and QR workflow**

- The user shall be able to scan supported barcode and QR formats using the device camera.
- Repeated detections of the same code shall be debounced.
- A recognized code shall open the matching active product.
- An unrecognized code shall offer a local product-creation flow prefilled with the scanned value.

### 3.3 Stock ledger and balances

**FR-6 — Stock movements**

- The user shall be able to record a stock movement for an active product while online or offline.
- Each movement shall be immutable and contain a client-generated UUIDv7 id, product id, non-zero signed quantity delta, type, optional note, corrected occurrence time, originating device id, and server receipt time once synchronized.
- v1 movement types shall include `receive`, `issue`, `adjust`, and `stocktake`.
- Corrections shall be represented by a new reversing movement linked to the original movement, never by updating or deleting the original.

**FR-7 — Derived current balance**

- The current product quantity shall equal the sum of all retained stock movement deltas for that product.
- The client and server may maintain rebuildable balance projections for query speed, but the ledger shall remain the source of truth.
- A low-stock view shall identify active products whose current balance is at or below their configured minimum threshold.

**FR-8 — Stocktake semantics**

- A stocktake shall capture the counted absolute quantity as well as its resulting movement delta.
- The server shall recompute a stocktake's delta against the canonical ledger when it applies the stocktake.
- Conflicting stocktakes from multiple devices shall be resolved deterministically according to the design's documented server policy and be visible to the user when attention is required.

### 3.4 Offline queue and synchronization

**FR-9 — Atomic local mutation and queueing**

- Every user mutation shall update the local domain tables and insert one pending sync operation in the same SQLite transaction.
- No UI code path shall directly mutate remote domain state.
- Each pending operation shall have a stable client-generated operation id, FIFO sequence, payload, retry metadata, and status.

**FR-10 — Bootstrap and incremental replication**

- A newly authenticated device shall receive a consistent full snapshot of all in-scope products, retained movements, tombstones, and a synchronization cursor.
- After bootstrap, a device shall synchronize incremental changes using a durable cursor rather than replacing its entire local database.
- The client shall apply remote changes and advance its persisted cursor in one SQLite transaction.

**FR-11 — Push/pull sync**

- The client shall push a bounded FIFO batch of due pending operations and pull remote changes in the same `POST /v1/sync` exchange.
- The backend shall process valid operations independently so one rejected operation does not invalidate other operations in the batch.
- The client shall continue pagination while the server reports more changes.
- The sync engine shall serialize sync cycles with one mutex and shall support triggers from app foreground, connectivity changes, debounced local writes, manual refresh, and a foreground timer.

**FR-12 — Idempotency and retries**

- The backend shall guarantee at-most-once logical application of an operation by unique `(device_id, op_id)` idempotency records.
- If an already processed operation is received again, the backend shall return the original recorded outcome without reapplying it.
- The client shall classify network failures, timeouts, rate limits, and server errors as retryable and use capped exponential backoff with jitter.
- Validation failures and semantic conflicts shall stop automatic retry for that operation and enter an inspectable conflict/error state.

**FR-13 — Connectivity**

- The client shall treat OS connectivity notifications as a trigger only, not proof that the backend is reachable.
- The client shall use a lightweight authenticated reachability check or an attempted sync to determine whether it can synchronize.

### 3.5 Conflict behavior

**FR-14 — Concurrent movement merge**

- Independently created stock movements from different devices shall both be retained and included in balances when they reference valid products.
- Concurrent movement creation shall not produce a manual conflict solely because the devices were offline.

**FR-15 — Versioned product edits**

- Product edits shall carry the version on which they were based.
- The backend shall reject an update whose base version no longer matches the canonical product version.
- The client shall automatically merge disjoint field edits when sufficient base/local/server data is available; overlapping field edits shall be recorded for user resolution.

**FR-16 — Deletion and barcode conflicts**

- A remote tombstone shall win over a concurrent product edit; the rejected local edit shall remain visible in the conflict history.
- The backend shall reject an active barcode collision and include enough canonical product information for the user to understand the collision.

**FR-17 — Conflict visibility**

- The app shall show the number of unresolved conflicts.
- The user shall be able to inspect local intent, canonical server state, and the reason for each conflict.
- Resolving a conflict shall create an explicit new local operation; it shall not silently mutate prior history.

### 3.6 Sync status and observability

**FR-18 — Sync status UX**

- The app shall expose `idle`, `syncing`, `backing_off`, and `blocked` synchronization states, pending-operation count, conflict count, last successful sync time, and latest error summary.
- The user shall be able to manually request a sync.

**FR-19 — Auditability**

- The backend shall retain immutable stock movement history, synchronization operation outcomes, and deletion tombstones according to the deployment retention policy.
- Logs and errors shall avoid recording raw passwords, bearer tokens, refresh tokens, or full sensitive request payloads.

## 4. Non-functional requirements

**NFR-1 — Correctness:** Retried operations, duplicate delivery, a client crash during change application, and concurrent device writes shall not silently lose or duplicate logical domain changes.

**NFR-2 — Data integrity:** The server shall enforce product barcode uniqueness, foreign-key integrity, non-zero deltas, valid movement types, and idempotency uniqueness.

**NFR-3 — Performance:** For a few hundred to low thousands of products, primary catalog and product-detail views shall render from local SQLite without waiting on network I/O. Sync responses shall be paginated and bounded.

**NFR-4 — Security:** API access shall require authenticated requests except login/refresh/health as designed. Passwords shall be hashed with an adaptive password hash. Tokens shall be rotated/revocable and never logged.

**NFR-5 — Testability:** Sync orchestration shall live in a pure Dart package with transport and storage abstractions so deterministic unit tests can model drops, duplicates, partial batches, and retry behavior.

**NFR-6 — Maintainability:** The project shall document key decisions, the sync protocol, and the conflict policy. Client and server schema changes shall be versioned with migrations.

## 5. Acceptance scenarios

1. **Offline ledger convergence:** Device A records `issue -3` and device B records `issue -2` for the same product while both are offline. After each device synchronizes, both show both movements and the same balance reduced by five.
2. **Lost sync response:** A server applies a movement but the client loses the response. The client retries the identical operation. The server retains exactly one movement and reports the cached original result.
3. **Crash-safe pull:** The client crashes while applying pulled changes. On restart it replays safely or resumes without a cursor that skips unapplied changes.
4. **Product edit conflict:** Device A and B edit the same product name offline from the same base version. The first sync succeeds; the other is rejected and shown as a conflict with both values.
5. **Disjoint product edits:** Device A changes a product name while B changes only its minimum-stock threshold from the same base version. The client can create a merged follow-up operation without user intervention.
6. **Barcode collision:** Separate offline product creations use the same barcode. One succeeds; the other operation becomes a visible barcode conflict, not a duplicate active barcode.
7. **Token expiry offline:** The user can continue viewing and recording locally while authentication refresh is unavailable. Synchronization becomes blocked and pending operations remain intact until reauthentication.
8. **Stocktake:** Two devices submit stocktakes for the same product from stale balances. The server recomputes canonical deltas and applies the documented deterministic policy without corrupting the ledger.
