# StokSync — Design

## 1. Decision summary

| Concern | Decision | Rationale |
|---|---|---|
| Mobile framework | Flutter | One codebase for Android and iOS with camera and local-database support. |
| State management | Riverpod | Fits reactive database streams with less UI state-machine ceremony than Bloc. |
| Local persistence | Drift on SQLite | The domain is relational (products, ledger entries, balances, queue, conflicts), needs transactional writes and schema migrations, and may later integrate with a SQLite sync product. |
| Scanning | `mobile_scanner` | Camera barcode/QR support suitable for the product lookup workflow. |
| API language | Go | Small, explicit deployment and strong concurrency/database tooling. |
| HTTP router | Chi | Standard `net/http`-compatible routing and middleware, minimal framework coupling. |
| Server database | PostgreSQL | Durable transactions, constraints, JSONB payloads, migrations, and correct concurrency semantics. |
| Database access | `pgx` and `sqlc` (preferred) | Explicit SQL for sync transactions and compile-time query mapping; avoid ORM abstraction over concurrency-critical SQL. |
| Server migrations | `goose` or `golang-migrate` | Versioned, repeatable schema evolution. |
| Sync transport | REST JSON over HTTPS | Debuggable and sufficient for v1; a single sync exchange combines push and pull. |
| Queue/workers | Deferred | v1 sync runs synchronously inside the API. Add Postgres-backed worker jobs before Redis/Asynq when a real asynchronous job exists. |
| Theming | Material 3 `ColorScheme.fromSeed`, light and dark, `ThemeMode.system` | A generated, contrast-checked palette without hand-rolled colors; dark mode is nearly free once the seed scheme is used correctly. |
| Typography | `google_fonts` (Inter) merged into the Material 3 `TextTheme` | A distinct, legible look with minimal implementation effort over the Material 3 default type scale. |
| Navigation | Material 3 `NavigationBar` with Products / Movements / Sync / Conflicts destinations | The app-bar-only structure does not scale past one screen; a bottom nav matches familiar inventory/POS app patterns. |

## 2. Scope boundaries

v1 has a single account owner, one inventory deployment, and multiple devices. All authenticated devices replicate the full account dataset. There are no tenant ids, roles, shared users, partial-sync filters, WebSockets, push notifications, or guaranteed background execution. App foregrounding, user actions, and connectivity events initiate sync; operating-system scheduling remains opportunistic and non-essential.

## 3. Repository layout

```text
StokSync/
├── app/                              # Flutter application
│   ├── lib/
│   │   ├── app/                      # bootstrap, routing, theming
│   │   ├── core/                     # configuration, errors, logging
│   │   ├── data/
│   │   │   ├── local/                # Drift database, DAOs, migrations
│   │   │   └── remote/               # HTTP client, auth and DTOs
│   │   ├── domain/                   # entities and repository contracts
│   │   └── features/                 # auth, products, scan, movements, sync, conflicts
│   └── packages/
│       └── sync_engine/              # Pure Dart: no Flutter imports
├── server/
│   ├── cmd/api/                      # composition root
│   ├── internal/
│   │   ├── auth/ db/ changelog/ sync/
│   │   ├── products/ movements/ httpx/
│   │   └── platform/                 # configuration, logging, time/uuid abstractions
│   └── migrations/
├── docs/
│   ├── adr/
│   ├── sync-protocol.md
│   └── conflict-matrix.md
├── docker-compose.yml
└── .kiro/specs/stoksync/
```

The `sync_engine` package accepts narrow interfaces for the local store, transport, clock, connectivity hint, and operation identifiers. Flutter code owns platform lifecycle and UI; server-specific HTTP DTOs remain outside the engine.

## 4. Architecture

```text
Flutter UI
  Riverpod providers ─────► Drift watch() queries
                                   │
                                SQLite
                   domain + queue + cursor + conflicts
                                   │
                            SyncEngine (pure Dart)
                                   │ HTTPS
                         Go API (net/http + Chi)
           auth │ snapshot │ sync │ health middleware + handlers
                                   │
                              PostgreSQL
      domain ledger + projections + change log + idempotency records
```

### 4.1 Local-first write path

1. A feature invokes a domain repository, not the API client.
2. One SQLite transaction writes the product/movement/tombstone state, updates a local balance projection if needed, and enqueues an immutable pending operation.
3. Drift streams notify Riverpod; the UI updates immediately.
4. A debounced trigger asks the serialized sync engine to run.
5. The engine persists all remote outcomes before changing its state, so app termination is safe.

### 4.2 Server write path

1. Chi authentication middleware authenticates the access token and binds user/device context.
2. The sync handler processes each received operation in an independent Postgres transaction.
3. That transaction records idempotency outcome, performs the domain write, updates projections, allocates and inserts a change-log record, and commits atomically.
4. The handler reads a bounded range of changes after the request's input cursor and returns results plus changes.

No route should update a product or stock movement outside the same domain transaction used by sync; direct CRUD routes are intentionally omitted from v1 except authentication, bootstrap, health, and sync.

## 5. Domain model

### 5.1 Product

```text
Product
  id: UUIDv7 (client-generated)
  barcode?: string
  sku?: string
  name: string
  description?: string
  unit: string = pcs
  category?: string
  minStock?: integer
  version: int64
  updatedAt: server timestamp
  updatedBy: device UUID
  deletedAt?: server timestamp
  createdAt: timestamp
```

Active barcode uniqueness is enforced by a partial PostgreSQL unique index (`barcode WHERE deleted_at IS NULL`) and mirrored with a local validation/unique constraint where practical. The server remains canonical.

### 5.2 Stock movement ledger

```text
StockMovement
  id: UUIDv7 (client-generated)
  productId: UUIDv7
  delta: non-zero integer
  kind: receive | issue | adjust | stocktake
  note?: string
  occurredAt: corrected device timestamp
  rawOccurredAt: original device timestamp
  clockOffsetMs: integer
  countedQty?: integer                # stocktake only
  reversesId?: UUIDv7
  deviceId: UUIDv7
  serverCreatedAt?: timestamp
```

Stock movement rows are never updated or removed. The balance is `SUM(delta)` for each product. Both databases can materialize `product_balances` for list performance; each projection must be rebuildable solely from the ledger.

A correction creates a new `adjust` movement with the opposite delta and a `reverses_id`, retaining audit history.

### 5.3 Synchronization tables

**PostgreSQL**

```text
users(id, email, password_hash, created_at, updated_at)
devices(id, user_id, name, platform, last_seen_at, last_ack_seq, created_at)
refresh_tokens(id, user_id, device_id, token_hash, expires_at, revoked_at)
products(...)
stock_movements(...)
product_balances(product_id, qty, last_movement_at, updated_at)
change_log(seq, entity, entity_id, op, payload, origin_device, created_at)
sync_ops(device_id, op_id, status, reason, response, received_at)
sync_seq_counter(id=1, last_seq)
```

`sync_ops` has `PRIMARY KEY (device_id, op_id)`. The stored `response` is the exact operation result to replay when delivery is duplicated.

**Drift/SQLite**

```text
products(..., sync_status)
stock_movements(..., sync_status)
product_balances(...)
pending_ops(op_id, local_seq, entity, entity_id, op, payload,
            base_version, attempts, next_attempt_at, last_error, status)
sync_state(id=1, cursor, bootstrapped, last_sync_at, last_error,
           server_clock_offset_ms)
conflicts(op_id, entity, entity_id, local_payload, base_payload,
          server_payload, reason, created_at, resolution_status)
```

`pending_ops.local_seq` defines FIFO order. All queue inserts are committed with their local domain mutation. A status such as `inflight` is only an implementation aid: a restart returns recoverable in-flight operations to `queued` unless the persisted server result has already been applied.

## 6. Change feed and cursor correctness

`change_log.seq` must be monotonic, commit-ordered, and gap-free for a single consumer cursor. Do **not** use `BIGSERIAL` / `nextval()` as the only cursor source: sequence allocation can produce gaps on rollback and becomes visible independently of transaction commit order.

Within the operation transaction, allocate the sequence under a row lock:

```sql
UPDATE sync_seq_counter
SET last_seq = last_seq + 1
WHERE id = 1
RETURNING last_seq;
```

Insert that result into `change_log` before commit. At v1's write volume, serializing change-log allocation is acceptable and ensures that a client cursor never skips a committed change. This choice must be captured as an ADR and integration-tested with concurrent transactions.

### Bootstrap

`GET /v1/snapshot` returns all replicated canonical rows and the high-water cursor from a consistent database view. The client writes the snapshot and `sync_state.cursor` in one SQLite transaction, then marks `bootstrapped = true`. The endpoint lets the server prune old `change_log` entries later without preventing a new installation from starting.

### Incremental application

The sync response returns only entries where `seq > request.cursor`, ordered ascending, bounded by `max_changes`. The client handles inserts/upserts/tombstones idempotently and advances its cursor to `next_cursor` in the same local transaction. If the app crashes, it repeats safely rather than skipping a change.

## 7. API contract

All routes are versioned under `/v1`. JSON uses RFC 3339 UTC timestamps and UUID strings. The server rejects unknown protocol versions with a response containing `min_supported_version`.

| Route | Auth | Responsibility |
|---|---|---|
| `POST /v1/auth/login` | No | Validate credentials, register/select device, return tokens. |
| `POST /v1/auth/refresh` | Refresh token | Rotate token pair for its device. |
| `GET /v1/snapshot` | Access token | Return full replica and consistent cursor. |
| `POST /v1/sync` | Access token | Apply a batch idempotently, then return change-feed page. |
| `GET /v1/health` | No or lightweight auth | Reachability/operational check only; not a source of data truth. |

### `POST /v1/sync`

Request:

```json
{
  "schema_version": 1,
  "device_id": "0192f200-0000-7000-8000-000000000001",
  "cursor": 1482,
  "max_changes": 500,
  "client_time": "2026-09-13T10:02:14Z",
  "ops": [
    {
      "op_id": "0192f3a1-0000-7000-8000-000000000001",
      "op": "add_movement",
      "payload": {
        "id": "0192f3a0-0000-7000-8000-000000000001",
        "product_id": "0192e1aa-0000-7000-8000-000000000001",
        "delta": -3,
        "kind": "issue",
        "note": "sold",
        "occurred_at": "2026-09-13T09:41:02Z"
      }
    },
    {
      "op_id": "0192f3a2-0000-7000-8000-000000000001",
      "op": "upsert_product",
      "base_version": 7,
      "payload": {
        "id": "0192e1aa-0000-7000-8000-000000000001",
        "name": "Indomie Goreng",
        "barcode": "089686010947",
        "unit": "pcs",
        "min_stock": 24
      }
    }
  ]
}
```

Response:

```json
{
  "results": [
    { "op_id": "0192f3a1-0000-7000-8000-000000000001", "status": "applied", "seq": 1483 },
    {
      "op_id": "0192f3a2-0000-7000-8000-000000000001",
      "status": "rejected",
      "reason": "version_conflict",
      "server_state": { "id": "...", "version": 9 }
    }
  ],
  "changes": [
    { "seq": 1483, "entity": "stock_movement", "op": "upsert", "data": {} }
  ],
  "next_cursor": 1483,
  "has_more": false,
  "server_time": "2026-09-13T10:02:15Z"
}
```

### Error classification

| Condition | Client behavior |
|---|---|
| `401` | Refresh exactly once, retry once; then enter `blocked` and retain all local work. |
| Unsupported schema | Enter `blocked`; require app update; retain local work. |
| Timeout, socket error, `429`, `5xx` | Keep queue item eligible; retry with exponential backoff and jitter. |
| Validation failure (`400`) | Mark operation terminal and create a conflict/error item. |
| Version, barcode, deletion, stocktake conflict | Mark operation terminal and create a conflict item with canonical state. |

## 8. Synchronization engine

```text
Idle -- trigger --> Preflight --> PushAndPull --> Apply --> Idle
                        |              |            |
                        +--------------+------------+--> Backoff --> Idle
                                                        |
                                                        +--> Blocked
```

- A single async mutex guards the entire cycle.
- Triggers: successful bootstrap/login, app foreground, debounced local write (~2 seconds), manual refresh, connectivity hint, and periodic foreground timer (~60 seconds).
- Connectivity signals are a wakeup hint only. A health request or sync attempt establishes reachability.
- Operations are selected in `local_seq` FIFO order, subject to `next_attempt_at`.
- Retry delay uses exponential backoff with jitter (for example: 1, 2, 4, 8, 30, 120, up to 300 seconds).
- The engine persists a rolling server clock offset from `server_time`. New movement occurrence times use corrected time while retaining raw device time and offset for auditing.
- Push happens before pull. Results are reconciled before/with the returned change page so the local representation converges on canonical data.

## 9. Conflict model

| Domain case | Canonical policy | Client action |
|---|---|---|
| Independent movement creation | Append/union both entries | No conflict UI. |
| Same product, disjoint field edits | Version mismatch then field-level three-way merge | Queue an explicit merged update. |
| Same product, same field edits | First accepted update wins canonical version | Create a conflict card with base/local/server values. |
| Duplicate active barcode | Unique index rejects second writer | Show owning canonical product information. |
| Edit vs tombstone | Tombstone wins | Preserve rejected intent in conflict history. |
| Correction | Append reversal, never mutate history | Show linked audit entries. |
| Concurrent stocktakes | Server orders canonical processing; recomputes delta from current ledger; later accepted stocktake establishes current count | Return canonical result and create informational/attention record for displaced stale intent if needed. |

A three-way merge compares `base → local` changed fields with `base → server` changed fields. It auto-merges only when the changed field sets do not overlap. It creates a new operation at the then-current server version, preserving the rejected operation as history.

## 10. Security and operations

- Use TLS in all deployed environments.
- Hash passwords with Argon2id or bcrypt using current secure parameters.
- Access tokens are short-lived (approximately 15 minutes); refresh tokens are device-bound, hashed at rest, rotated, revocable, and long-lived (approximately 90 days).
- Store mobile tokens with `flutter_secure_storage`, not Drift or shared preferences.
- Apply request-size limits, JSON validation, token-aware rate limits when needed, structured logs, request IDs, and health/readiness endpoints.
- Docker Compose is for local Postgres development. Redis/Asynq do not enter the initial composition.

## 11. Test strategy

| Layer | Focus |
|---|---|
| Flutter/domain tests | Ledger balance calculation, local transaction invariant, barcode validation, migrations. |
| Pure Dart sync-engine tests | Duplicate responses, dropped responses, partial results, backoff, mutex serialization, cursor application, blocked auth. |
| Go unit tests | Validation, token lifecycle, conflict classification, response mapping. |
| Go/Postgres integration tests | Idempotency under concurrency, transaction rollback behavior, commit-ordered change cursor, snapshot consistency, stocktake recomputation. |
| Two-device convergence harness | Two local replicas against real Postgres with injected request loss, duplicate delivery, reordering, failures, and eventual queue drain. Assert both replicas and server converge and balances equal ledger sums. |
| Manual device checks | Camera permission, repeated-code debounce, offline session, app restart persistence, two-phone conflict UX. |

## 12. Key risks and mitigations

| Risk | Mitigation |
|---|---|
| Silent inventory loss from mutable balance writes | Use immutable signed ledger and rebuildable projections. |
| Duplicate movement after lost response | Persist idempotency record and original result atomically with domain write. |
| Cursor skips committed change | Allocate change sequence in the same transaction using locked counter row. |
| Data loss from client crash during pull | Apply changes and advance local cursor in the same SQLite transaction. |
| Offline auth destroys local work | Treat expired credentials as sync-blocked, never as permission to wipe local state. |
| Clock differences affect stocktake order | Persist/refresh server clock offset; make server canonically recompute stocktake deltas. |
| Background execution differs by OS | Make foreground sync correct; treat background sync as optional v2 enhancement. |

## 13. Visual system and navigation (Milestone 7)

v1's functional screens were built with default Material widgets and no shared visual system. Milestone 7 refines presentation without changing any domain, sync, or conflict behavior decided in sections 1-12.

### 13.1 Theming

- The app defines exactly one seed color and generates both light and dark `ColorScheme`s from it with `ColorScheme.fromSeed(seedColor: ..., brightness: Brightness.light/dark)`. No individual color is hand-picked outside the seed; Material 3 computes primary/secondary/tertiary/error roles and their contrast pairs.
- `MaterialApp.themeMode` is `ThemeMode.system`. The app follows the device's light/dark setting; there is no in-app override in v1.
- Both `ThemeData` instances use `useMaterial3: true` (the current Flutter default) and set `colorScheme`, leaving component-level styling to Material 3 defaults unless a specific screen requires a documented exception.

### 13.2 Typography

- The app applies the `google_fonts` package's `Inter` font family to the Material 3 `TextTheme` (e.g., `GoogleFonts.interTextTheme(Theme.of(context).textTheme)` composed into each `ThemeData`), rather than overriding individual text styles per screen.
- Existing `textTheme.headlineSmall` / `titleMedium` / `bodyMedium` usages across screens are preserved; only the font family and the theme's derived weights change.

### 13.3 Navigation structure

- A `NavigationBar` (Material 3 bottom navigation) replaces the current single-page-plus-app-bar structure as the authenticated app's root shell. Destinations, in this order: **Products**, **Movements**, **Sync**, **Conflicts**.
- **Products** hosts today's `ProductBrowsePage` (browse/search/create/edit/soft-delete) and the barcode scanner entry point.
- **Movements** is a new cross-product movement history view (list of recent movements across all products, newest first), separate from the existing per-product movement history on the product detail page. It reuses the existing `LocalInventoryQueries` pattern with a new unfiltered movement stream rather than changing ledger semantics.
- **Sync** hosts the existing sync-status detail screen (state, pending count, conflicts, last successful sync, error summary, manual sync action) as a full destination instead of only a toolbar chip.
- **Conflicts** hosts the existing conflict list/detail flow as a full destination instead of an app-bar icon button.
- The product detail, product edit, movement entry, movement reversal, barcode scanner, and conflict detail screens remain pushed routes reached from their respective tab, not new bottom-nav destinations themselves.
- Auth (sign-in) remains the pre-authentication gate shown before the navigation shell, unchanged in structure; only its visual styling is in scope for Milestone 7.

### 13.4 Conflict payload presentation

- The conflict detail screen's base/local/server payload sections stop rendering raw pretty-printed JSON. Each section instead renders a structured label/value list built from the same decoded JSON object already available to the widget (`conflict.basePayload` / `localPayload` / `serverPayload`), mapping known product/movement fields (for example `name`, `barcode`, `sku`, `unit`, `min_stock`, `version`, `delta`, `counted_qty`) to human-readable labels.
- A field present in one payload but absent or differing in another remains visible in its own section; the presentation change does not alter which data is shown, only how it is formatted. No field is summarized away or hidden.
- Fields not in the known label map (forward-compatible/unexpected fields) still render using their raw JSON key as a fallback label, so the view degrades gracefully rather than silently dropping data.

### 13.5 Verification

- Milestone 7 is verified visually on a running Android emulator (the developer's Pixel 8a emulator target) rather than solely through widget tests, because the goal is a perceivable layout/theme/navigation change. Widget tests continue to assert structure (destinations present, keys present, label content) but do not substitute for an on-emulator visual check.
- Each task under Milestone 7 is expected to produce an immediately visible, incremental change on the running emulator (hot reload/restart) before moving to the next task, per the task list in `tasks.md`.
