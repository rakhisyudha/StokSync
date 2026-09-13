-- StokSync canonical PostgreSQL schema, version 1.
--
-- This migration establishes durable table shape and the columns required by
-- the authentication, catalog, ledger, and synchronization services. Domain
-- checks, relationship constraints, secondary indexes, and the composite
-- idempotency key are added by the next migration (task 2.2).

CREATE TABLE users (
    id UUID NOT NULL,
    email TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);

CREATE TABLE devices (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    last_seen_at TIMESTAMPTZ,
    last_ack_seq BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);

CREATE TABLE refresh_tokens (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    token_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    rotated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);

CREATE TABLE products (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    barcode TEXT,
    sku TEXT,
    name TEXT NOT NULL,
    description TEXT,
    unit TEXT NOT NULL DEFAULT 'pcs',
    category TEXT,
    min_stock INTEGER,
    version BIGINT NOT NULL DEFAULT 1,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_by_device_id UUID NOT NULL,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);

-- Stock movements are append-only. There is intentionally no updated_at or
-- deleted_at column: corrections are new linked movements.
CREATE TABLE stock_movements (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    product_id UUID NOT NULL,
    delta INTEGER NOT NULL,
    kind TEXT NOT NULL,
    note TEXT,
    occurred_at TIMESTAMPTZ NOT NULL,
    raw_occurred_at TIMESTAMPTZ NOT NULL,
    clock_offset_ms BIGINT NOT NULL DEFAULT 0,
    counted_qty INTEGER,
    reverses_id UUID,
    device_id UUID NOT NULL,
    server_created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);

-- This is a rebuildable read projection; stock_movements remains canonical.
CREATE TABLE product_balances (
    product_id UUID NOT NULL,
    qty BIGINT NOT NULL DEFAULT 0,
    last_movement_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (product_id)
);

-- seq is allocated from sync_seq_counter inside the same domain transaction.
-- It is not backed by a PostgreSQL sequence because rolled-back sequence
-- allocations would create gaps in the client-visible cursor.
CREATE TABLE sync_seq_counter (
    id SMALLINT NOT NULL,
    last_seq BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
);

INSERT INTO sync_seq_counter (id, last_seq)
VALUES (1, 0);

CREATE TABLE change_log (
    seq BIGINT NOT NULL,
    user_id UUID NOT NULL,
    entity TEXT NOT NULL,
    entity_id UUID NOT NULL,
    op TEXT NOT NULL,
    payload JSONB NOT NULL,
    origin_device_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (seq)
);

-- The composite (device_id, op_id) idempotency key is added in task 2.2.
-- response stores the exact result returned to the client for replay.
CREATE TABLE sync_ops (
    device_id UUID NOT NULL,
    op_id UUID NOT NULL,
    user_id UUID NOT NULL,
    status TEXT NOT NULL,
    reason TEXT,
    response JSONB NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMPTZ
);

COMMENT ON TABLE stock_movements IS
    'Immutable signed inventory ledger; corrections are appended as linked movements.';
COMMENT ON TABLE product_balances IS
    'Rebuildable quantity projection derived from stock_movements.';
COMMENT ON TABLE sync_seq_counter IS
    'Single-row transaction-scoped allocator for gap-free committed change_log cursors.';
COMMENT ON TABLE sync_ops IS
    'Durable operation outcomes used to make duplicate synchronization delivery idempotent.';
