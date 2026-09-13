# StokSync synchronization protocol

## API conventions and current routes

The API is currently served under `/v1` by the Go/Chi server. Examples in this
document use `http://127.0.0.1:8080` as `BASE_URL`; deployed clients must use
HTTPS. JSON request bodies require `Content-Type: application/json`, and JSON
responses use `Content-Type: application/json; charset=utf-8`. UUIDs are sent as
strings and timestamps are RFC 3339 UTC values.

The routes currently implemented are:

| Method and path | Authentication | Purpose |
|---|---|---|
| `GET /v1/health` | None | Liveness response. Returns `{"status":"ok"}` without checking PostgreSQL. |
| `GET /v1/ready` | None | Dependency readiness. Returns `{"status":"ready"}` when PostgreSQL responds to `Ping`, otherwise `503 {"status":"not_ready"}`. |
| `POST /v1/auth/register` | None | Creates an account, registers its first device, and returns a session. The smoke script uses this only to create a disposable local fixture. |
| `POST /v1/auth/login` | None | Validates credentials, registers or refreshes the supplied device, and returns a session. |
| `POST /v1/auth/refresh` | None; opaque refresh token in the body | Rotates a refresh token and returns a replacement access/refresh-token pair. |
| `POST /v1/auth/logout` | `Authorization: Bearer <access-token>` | Revokes active refresh sessions for the authenticated device. It returns `204` with no body. |
| `GET /v1/snapshot` | `Authorization: Bearer <access-token>` | Returns the complete account-scoped bootstrap replica and a consistent cursor. |
| `POST /v1/sync` | `Authorization: Bearer <access-token>` | Validates the request/device boundary and processes each received operation in an independent transaction. Task 3.2 currently returns explicit rejected results for unimplemented domain operations and an empty change page. |

### Sync DTO contract (Milestone 3.1)

The sync DTOs use `schema_version: 1` and reject every other version. A request
contains the authenticated device identifier, a non-negative cursor, a bounded
`max_changes` page size, an RFC 3339 `client_time`, and an `ops` array (use an
empty array when there is no push work):

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
        "occurred_at": "2026-09-13T09:41:02Z"
      }
    }
  ]
}
```

The supported operation envelopes are `add_movement`, `upsert_product`, and
`delete_product`. Each requires a UUID `op_id` and a JSON-object payload;
`base_version` is optional for versioned product mutations. Payload fields are
strictly decoded. Movement payloads require `id`, `product_id`, non-zero
`delta`, a supported `kind`, and `occurred_at`; product upserts require `id`
and `name`; deletes require `id`. Optional movement audit fields include
`raw_occurred_at`, `clock_offset_ms`, `counted_qty`, `reverses_id`, and
`device_id`.

A successful response includes `schema_version`, independent per-operation
`results`, an ordered `changes` page, `next_cursor`, `has_more`, and UTC
`server_time`:

```json
{
  "schema_version": 1,
  "results": [
    { "op_id": "0192f3a1-0000-7000-8000-000000000001", "status": "applied", "seq": 1483 },
    { "op_id": "0192f3a2-0000-7000-8000-000000000001", "status": "rejected", "reason": "version_conflict", "server_state": { "id": "...", "version": 9 } }
  ],
  "changes": [
    { "seq": 1483, "entity": "stock_movement", "op": "upsert", "data": {} }
  ],
  "next_cursor": 1483,
  "has_more": false,
  "server_time": "2026-09-13T10:02:15Z"
}
```

The strict decoder rejects unknown fields, missing required fields, malformed
UUIDs/timestamps, trailing JSON values, and non-object operation payloads. The
default bounds are a 1 MiB request body, 100 operations, 500 requested or
returned changes, and a 256 KiB individual operation payload. Deployments may
lower these limits. Unsupported schema errors use
`{"schema_version":1,"error":"unsupported_schema_version","min_supported_version":1}`.

The sync handler requires a valid access token, requires the request `device_id`
to equal the device identity in that token, and verifies that the device is
registered to the authenticated account. Malformed, oversized, and unsupported
schema requests are rejected before service work. Each received operation is
sent through its own transaction boundary; a transaction failure becomes an
isolated rejected result so later operations can still be handled. Until Task
3.3 supplies domain services, valid operation envelopes return
`status: "rejected"` with `reason: "operation_not_implemented"`; no product,
movement, idempotency, or change-log rows are written by this boundary.

The current response still has the complete push/pull shape (`results`,
`changes`, `next_cursor`, `has_more`, and `server_time`). Task 3.2 returns an
empty `changes` page and preserves the request cursor.

### Authentication requests and sessions

`register` and `login` accept the same JSON shape:

```json
{
  "email": "owner@example.test",
  "password": "correct horse battery staple",
  "device_id": "0192f200-0000-7000-8000-000000000001",
  "device_name": "Warehouse phone",
  "platform": "android"
}
```

The client generates and persists `device_id` for an installation. The server
normalizes the email to lowercase, requires a non-empty device name/platform,
and applies the registration password length and bcrypt input limits. A
successful registration returns `201`; a successful login returns `200`.
Both return the following session shape (with `expires_in` in seconds):

```json
{
  "access_token": "<short-lived bearer token>",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "<opaque one-time token>",
  "user_id": "0192f1a0-0000-7000-8000-000000000001",
  "device_id": "0192f200-0000-7000-8000-000000000001"
}
```

Send the access token only in the `Authorization` header:

```http
Authorization: Bearer <access_token>
```

Refresh requests put the opaque token in JSON and do not use the access-token
header:

```http
POST /v1/auth/refresh
Content-Type: application/json

{"refresh_token":"<refresh_token>"}
```

Refresh tokens are one-time use. After a successful refresh, the submitted
token is invalid and the response contains a new token pair. A reused,
expired, malformed, or unknown token returns `401 {"error":"invalid_refresh_token"}`.
Logout revokes the device's active refresh sessions; the stateless access token
can remain valid until its short expiry because access-token middleware does
not consult the refresh-token table.

Authentication and snapshot errors use stable, non-sensitive JSON error codes:

| Status | Error code(s) | Meaning |
|---|---|---|
| `400` | `invalid_request` | Malformed JSON, unknown fields, missing/invalid request values, or a snapshot query/body that is not allowed. |
| `401` | `unauthorized` | Missing or invalid bearer token. |
| `401` | `invalid_credentials` | Login credentials are not valid. |
| `401` | `invalid_refresh_token` | Refresh token is missing, expired, revoked, reused, or unknown. |
| `409` | `email_taken`, `device_conflict` | Registration/account or device ownership conflict. |
| `413` | `snapshot_too_large` | The complete snapshot exceeds configured row or encoded-response bounds; no partial snapshot is returned. |
| `500` | `internal_error` | An unexpected server/database failure; implementation details are not returned. |

The server does not log passwords, bearer tokens, refresh tokens, or full
sensitive request payloads.

## Bootstrap snapshot (`GET /v1/snapshot`)

An authenticated device bootstraps its complete local replica with `GET /v1/snapshot`. The access token supplies the account identity; the request has no body or query parameters. Missing, malformed, or invalid bearer credentials are rejected without exposing account data.

The server executes the read in one PostgreSQL `REPEATABLE READ, READ ONLY` transaction. Products, retained immutable movements, ledger-derived balances, and the cursor high-water mark therefore describe one committed database view. Every SQL read is constrained by the authenticated account id. The cursor is read from the transaction-scoped `sync_seq_counter`, not from a PostgreSQL sequence.

The response is versioned and uses UUID strings and RFC 3339 UTC timestamps:

```json
{
  "schema_version": 1,
  "products": [
    {
      "id": "0192e1aa-0000-7000-8000-000000000001",
      "barcode": "089686010947",
      "sku": null,
      "name": "Indomie Goreng",
      "description": null,
      "unit": "pcs",
      "category": "food",
      "min_stock": 24,
      "version": 1,
      "updated_at": "2026-09-13T10:00:00Z",
      "updated_by_device_id": "0192f200-0000-7000-8000-000000000001",
      "deleted_at": null,
      "created_at": "2026-09-13T10:00:00Z"
    }
  ],
  "movements": [],
  "balances": [],
  "tombstones": [],
  "cursor": 1482,
  "server_time": "2026-09-13T10:02:15Z"
}
```

`products` contains active rows and retained deleted rows. Deleted rows also appear in `tombstones` as a compact deletion index so a client can apply the deletion explicitly while retaining the full historical product row. `balances` are derived from the immutable movement ledger rather than trusted as the source of truth from `product_balances`; the projection remains a server-side query optimization.

The endpoint bounds database row reads and encoded response size. The default bounds are 10,000 products, 100,000 movements, and 32 MiB; an account exceeding a bound receives `413 snapshot_too_large` rather than a partial response. A request body or query string receives `400 invalid_request`. These limits are intended for v1 catalogs of hundreds to low thousands of products and can be configured at construction time.

The sync response boundary is now implemented with the behavior described above.
Incremental change-feed reads, canonical operation application, and idempotency
persistence remain subsequent tasks; this endpoint intentionally does not claim
those operations were applied.

## Reproducible HTTP smoke test

[`server/scripts/api-smoke.ps1`](../server/scripts/api-smoke.ps1) is a
PowerShell 5.1+ HTTP smoke script with no third-party client dependencies. It
checks `GET /v1/health`, creates a disposable account through
`POST /v1/auth/register` by default, then asserts successful
`POST /v1/auth/login`, one-time `POST /v1/auth/refresh` rotation, and
authenticated `GET /v1/snapshot` metadata. It does not print access or
refresh-token values.

Run it only after PostgreSQL has been migrated and the API is listening:

```powershell
.\server\scripts\api-smoke.ps1
```

The default base URL is `http://127.0.0.1:8080`; override it with
`-BaseUrl` or `STOKSYNC_API_BASE_URL`. To test an existing account without
creating a fixture, pass `-SkipRegister -Email <email> -Password <password>`.
The complete environment and API startup sequence is documented in
[`local-development.md`](local-development.md).
