-- StokSync PostgreSQL integrity constraints and access-path indexes, version 2.
--
-- This migration is applied after 000001_initial_schema. Ownership-aware
-- foreign keys prevent a device from writing another user's rows while the
-- ledger, product, and idempotency invariants remain enforced by PostgreSQL.

-- Composite keys used by ownership-aware foreign keys. The user-first order
-- also supports the common user-scoped snapshot and device queries.
ALTER TABLE devices
    ADD CONSTRAINT devices_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE products
    ADD CONSTRAINT products_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_user_id_id_key UNIQUE (user_id, id);

-- Core row ownership and relationship constraints.
ALTER TABLE devices
    ADD CONSTRAINT devices_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id),
    ADD CONSTRAINT devices_last_ack_seq_nonnegative_check
        CHECK (last_ack_seq >= 0);

ALTER TABLE refresh_tokens
    ADD CONSTRAINT refresh_tokens_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id),
    ADD CONSTRAINT refresh_tokens_device_id_fkey
        FOREIGN KEY (device_id) REFERENCES devices (id),
    ADD CONSTRAINT refresh_tokens_device_owner_fkey
        FOREIGN KEY (user_id, device_id) REFERENCES devices (user_id, id);

ALTER TABLE products
    ADD CONSTRAINT products_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id),
    ADD CONSTRAINT products_updated_by_device_id_fkey
        FOREIGN KEY (updated_by_device_id) REFERENCES devices (id),
    ADD CONSTRAINT products_updated_by_device_owner_fkey
        FOREIGN KEY (user_id, updated_by_device_id) REFERENCES devices (user_id, id),
    ADD CONSTRAINT products_version_positive_check
        CHECK (version >= 1);

ALTER TABLE stock_movements
    ADD CONSTRAINT stock_movements_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id),
    ADD CONSTRAINT stock_movements_product_id_fkey
        FOREIGN KEY (product_id) REFERENCES products (id),
    ADD CONSTRAINT stock_movements_product_owner_fkey
        FOREIGN KEY (user_id, product_id) REFERENCES products (user_id, id),
    ADD CONSTRAINT stock_movements_device_id_fkey
        FOREIGN KEY (device_id) REFERENCES devices (id),
    ADD CONSTRAINT stock_movements_device_owner_fkey
        FOREIGN KEY (user_id, device_id) REFERENCES devices (user_id, id),
    ADD CONSTRAINT stock_movements_reverses_id_fkey
        FOREIGN KEY (reverses_id) REFERENCES stock_movements (id),
    ADD CONSTRAINT stock_movements_reverses_owner_fkey
        FOREIGN KEY (user_id, reverses_id) REFERENCES stock_movements (user_id, id),
    ADD CONSTRAINT stock_movements_delta_nonzero_check
        CHECK (delta <> 0),
    ADD CONSTRAINT stock_movements_kind_check
        CHECK (kind IN ('receive', 'issue', 'adjust', 'stocktake'));

ALTER TABLE product_balances
    ADD CONSTRAINT product_balances_product_id_fkey
        FOREIGN KEY (product_id) REFERENCES products (id);

ALTER TABLE change_log
    ADD CONSTRAINT change_log_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id),
    ADD CONSTRAINT change_log_origin_device_id_fkey
        FOREIGN KEY (origin_device_id) REFERENCES devices (id),
    ADD CONSTRAINT change_log_origin_device_owner_fkey
        FOREIGN KEY (user_id, origin_device_id) REFERENCES devices (user_id, id);

-- entity_id is intentionally polymorphic: its target table is selected by
-- entity and therefore cannot be represented by one relational foreign key.
ALTER TABLE sync_ops
    ADD CONSTRAINT sync_ops_pkey PRIMARY KEY (device_id, op_id),
    ADD CONSTRAINT sync_ops_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id),
    ADD CONSTRAINT sync_ops_device_id_fkey
        FOREIGN KEY (device_id) REFERENCES devices (id),
    ADD CONSTRAINT sync_ops_device_owner_fkey
        FOREIGN KEY (user_id, device_id) REFERENCES devices (user_id, id);

-- Active products may share no barcode. PostgreSQL's normal NULL semantics
-- still permit multiple products without a barcode.
CREATE UNIQUE INDEX products_active_barcode_uq
    ON products (barcode)
    WHERE deleted_at IS NULL;

-- User-scoped catalog replication and active-catalog listing paths.
CREATE INDEX products_user_updated_at_idx
    ON products (user_id, updated_at DESC, id);

-- Device and refresh-token lookup paths used by authentication/device services.
CREATE INDEX devices_user_last_seen_at_idx
    ON devices (user_id, last_seen_at DESC);

CREATE INDEX refresh_tokens_token_hash_idx
    ON refresh_tokens (token_hash);

CREATE INDEX refresh_tokens_device_expiry_idx
    ON refresh_tokens (device_id, revoked_at, expires_at);

-- Ledger history, per-user snapshot, and balance-related access paths.
CREATE INDEX stock_movements_product_occurred_at_idx
    ON stock_movements (product_id, occurred_at DESC, id);

CREATE INDEX stock_movements_user_server_created_at_idx
    ON stock_movements (user_id, server_created_at, id);

-- Incremental replication reads changes by user and ascending cursor.
CREATE INDEX change_log_user_seq_idx
    ON change_log (user_id, seq);

-- Operational inspection of idempotency outcomes by account/device and time.
CREATE INDEX sync_ops_user_received_at_idx
    ON sync_ops (user_id, received_at);
