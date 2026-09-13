-- Reverse 000002_constraints_and_indexes in dependency order.

-- Remove explicitly-created access paths first. The indexes backing UNIQUE
-- constraints are removed when their constraints are dropped below.
DROP INDEX products_active_barcode_uq;
DROP INDEX products_user_updated_at_idx;
DROP INDEX devices_user_last_seen_at_idx;
DROP INDEX refresh_tokens_token_hash_idx;
DROP INDEX refresh_tokens_device_expiry_idx;
DROP INDEX stock_movements_product_occurred_at_idx;
DROP INDEX stock_movements_user_server_created_at_idx;
DROP INDEX change_log_user_seq_idx;
DROP INDEX sync_ops_user_received_at_idx;

-- Remove foreign keys before the composite unique keys they reference.
ALTER TABLE sync_ops
    DROP CONSTRAINT sync_ops_device_owner_fkey,
    DROP CONSTRAINT sync_ops_device_id_fkey,
    DROP CONSTRAINT sync_ops_user_id_fkey,
    DROP CONSTRAINT sync_ops_pkey;

ALTER TABLE change_log
    DROP CONSTRAINT change_log_origin_device_owner_fkey,
    DROP CONSTRAINT change_log_origin_device_id_fkey,
    DROP CONSTRAINT change_log_user_id_fkey;

ALTER TABLE product_balances
    DROP CONSTRAINT product_balances_product_id_fkey;

ALTER TABLE stock_movements
    DROP CONSTRAINT stock_movements_kind_check,
    DROP CONSTRAINT stock_movements_delta_nonzero_check,
    DROP CONSTRAINT stock_movements_reverses_owner_fkey,
    DROP CONSTRAINT stock_movements_reverses_id_fkey,
    DROP CONSTRAINT stock_movements_device_owner_fkey,
    DROP CONSTRAINT stock_movements_device_id_fkey,
    DROP CONSTRAINT stock_movements_product_owner_fkey,
    DROP CONSTRAINT stock_movements_product_id_fkey,
    DROP CONSTRAINT stock_movements_user_id_fkey;

ALTER TABLE products
    DROP CONSTRAINT products_version_positive_check,
    DROP CONSTRAINT products_updated_by_device_owner_fkey,
    DROP CONSTRAINT products_updated_by_device_id_fkey,
    DROP CONSTRAINT products_user_id_fkey;

ALTER TABLE refresh_tokens
    DROP CONSTRAINT refresh_tokens_device_owner_fkey,
    DROP CONSTRAINT refresh_tokens_device_id_fkey,
    DROP CONSTRAINT refresh_tokens_user_id_fkey;

ALTER TABLE devices
    DROP CONSTRAINT devices_last_ack_seq_nonnegative_check,
    DROP CONSTRAINT devices_user_id_fkey;

-- These keys were introduced solely to support the ownership-aware foreign
-- keys above and must be removed last.
ALTER TABLE stock_movements
    DROP CONSTRAINT stock_movements_user_id_id_key;

ALTER TABLE products
    DROP CONSTRAINT products_user_id_id_key;

ALTER TABLE devices
    DROP CONSTRAINT devices_user_id_id_key;
