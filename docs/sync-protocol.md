# StokSync synchronization protocol

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
