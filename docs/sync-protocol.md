# StokSync synchronization protocol

## API conventions and current routes

The API is currently served under `/v1` by the Go/Chi server. Examples in this
document use `http://127.0.0.1:8080` as `BASE_URL`; deployed clients must use
HTTPS. JSON request bodies require `Content-Type: application/json`, and JSON
responses use `Content-Type: application/json; charset=utf-8`. UUIDs are sent as
strings and timestamps are RFC 3339 UTC values.

The routes implemented at the end of Milestone 2 are:

| Method and path | Authentication | Purpose |
|---|---|---|
| `GET /v1/health` | None | Liveness response. Returns `{"status":"ok"}` without checking PostgreSQL. |
| `GET /v1/ready` | None | Dependency readiness. Returns `{"status":"ready"}` when PostgreSQL responds to `Ping`, otherwise `503 {"status":"not_ready"}`. |
| `POST /v1/auth/register` | None | Creates an account, registers its first device, and returns a session. The smoke script uses this only to create a disposable local fixture. |
| `POST /v1/auth/login` | None | Validates credentials, registers or refreshes the supplied device, and returns a session. |
| `POST /v1/auth/refresh` | None; opaque refresh token in the body | Rotates a refresh token and returns a replacement access/refresh-token pair. |
| `POST /v1/auth/logout` | `Authorization: Bearer <access-token>` | Revokes active refresh sessions for the authenticated device. It returns `204` with no body. |
| `GET /v1/snapshot` | `Authorization: Bearer <access-token>` | Returns the complete account-scoped bootstrap replica and a consistent cursor. |

`POST /v1/sync` is not implemented yet. It is intentionally not included in
the HTTP smoke test; its versioned DTO and push/pull behavior belong to
Milestone 3.

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

Incremental push/pull exchange behavior is intentionally documented in a later milestone; this bootstrap contract does not define `POST /v1/sync`.

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
