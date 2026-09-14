\set ON_ERROR_STOP on

-- Representative rows written after 000002, before 000003 adds the
-- case-insensitive email and refresh-token digest invariants.
BEGIN;

INSERT INTO users (id, email, password_hash, created_at, updated_at)
VALUES (
    '00000000-0000-4000-8000-000000000001',
    'migration-upgrade@example.test',
    'legacy-password-hash',
    TIMESTAMPTZ '2026-01-01 00:00:00+00',
    TIMESTAMPTZ '2026-01-01 00:00:00+00'
);

INSERT INTO devices (id, user_id, name, platform, last_ack_seq, created_at)
VALUES (
    '00000000-0000-4000-8000-000000000011',
    '00000000-0000-4000-8000-000000000001',
    'legacy-device',
    'test',
    0,
    TIMESTAMPTZ '2026-01-01 00:00:00+00'
);

INSERT INTO refresh_tokens (
    id, user_id, device_id, token_hash, expires_at, created_at
)
VALUES (
    '00000000-0000-4000-8000-000000000012',
    '00000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000011',
    'legacy-refresh-token-digest',
    TIMESTAMPTZ '2027-01-01 00:00:00+00',
    TIMESTAMPTZ '2026-01-01 00:00:00+00'
);

INSERT INTO products (
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, created_at, deleted_at
)
VALUES (
    '00000000-0000-4000-8000-000000000021',
    '00000000-0000-4000-8000-000000000001',
    'legacy-barcode',
    'LEGACY-001',
    'Legacy stock item',
    'Written before the authentication index upgrade',
    'pcs',
    'food',
    3,
    4,
    TIMESTAMPTZ '2026-01-01 00:00:00+00',
    '00000000-0000-4000-8000-000000000011',
    TIMESTAMPTZ '2026-01-01 00:00:00+00',
    NULL
), (
    '00000000-0000-4000-8000-000000000022',
    '00000000-0000-4000-8000-000000000001',
    'legacy-barcode',
    'LEGACY-DELETED',
    'Deleted legacy item',
    NULL,
    'pcs',
    NULL,
    NULL,
    2,
    TIMESTAMPTZ '2026-01-01 00:00:00+00',
    '00000000-0000-4000-8000-000000000011',
    TIMESTAMPTZ '2026-01-01 00:00:00+00',
    TIMESTAMPTZ '2026-01-02 00:00:00+00'
);

INSERT INTO stock_movements (
    id, user_id, product_id, delta, kind, note, occurred_at,
    raw_occurred_at, clock_offset_ms, counted_qty, device_id,
    server_created_at
)
VALUES (
    '00000000-0000-4000-8000-000000000031',
    '00000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000021',
    7,
    'stocktake',
    'Legacy counted quantity',
    TIMESTAMPTZ '2026-01-01 00:01:00+00',
    TIMESTAMPTZ '2026-01-01 00:01:00+00',
    -125,
    7,
    '00000000-0000-4000-8000-000000000011',
    TIMESTAMPTZ '2026-01-01 00:02:00+00'
);

INSERT INTO product_balances (
    product_id, qty, last_movement_at, updated_at
)
VALUES (
    '00000000-0000-4000-8000-000000000021',
    7,
    TIMESTAMPTZ '2026-01-01 00:01:00+00',
    TIMESTAMPTZ '2026-01-01 00:02:00+00'
);

UPDATE sync_seq_counter SET last_seq = 1 WHERE id = 1;

INSERT INTO change_log (
    seq, user_id, entity, entity_id, op, payload, origin_device_id,
    created_at
)
VALUES (
    1,
    '00000000-0000-4000-8000-000000000001',
    'stock_movement',
    '00000000-0000-4000-8000-000000000031',
    'upsert',
    '{"id":"00000000-0000-4000-8000-000000000031","kind":"stocktake","counted_qty":7}'::JSONB,
    '00000000-0000-4000-8000-000000000011',
    TIMESTAMPTZ '2026-01-01 00:02:00+00'
);

INSERT INTO sync_ops (
    device_id, op_id, user_id, status, reason, response, received_at,
    completed_at
)
VALUES (
    '00000000-0000-4000-8000-000000000011',
    '00000000-0000-4000-8000-000000000041',
    '00000000-0000-4000-8000-000000000001',
    'rejected',
    'stocktake_conflict',
    '{"status":"rejected","reason":"stocktake_conflict"}'::JSONB,
    TIMESTAMPTZ '2026-01-01 00:03:00+00',
    TIMESTAMPTZ '2026-01-01 00:03:00+00'
);

COMMIT;
