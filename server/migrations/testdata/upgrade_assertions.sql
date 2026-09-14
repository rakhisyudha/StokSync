\set ON_ERROR_STOP on

-- Assertions for both v1->latest and v2->latest upgrade runs. The fixture
-- rows are intentionally checked before the constraint probes below.
DO $$
DECLARE
    constraint_name TEXT;
BEGIN
    IF (SELECT COUNT(*) FROM users) <> 1 THEN
        RAISE EXCEPTION 'user fixture was not preserved';
    END IF;
    IF (SELECT email FROM users LIMIT 1) <> 'migration-upgrade@example.test' THEN
        RAISE EXCEPTION 'user data changed during migration upgrade';
    END IF;
    IF (SELECT COUNT(*) FROM devices) <> 1 THEN
        RAISE EXCEPTION 'device fixture was not preserved';
    END IF;
    IF (SELECT COUNT(*) FROM refresh_tokens) <> 1 THEN
        RAISE EXCEPTION 'refresh-token fixture was not preserved';
    END IF;
    IF (SELECT COUNT(*) FROM products) <> 2 THEN
        RAISE EXCEPTION 'product and tombstone fixtures were not preserved';
    END IF;
    IF (SELECT deleted_at IS NULL FROM products WHERE id = '00000000-0000-4000-8000-000000000021') IS NOT TRUE THEN
        RAISE EXCEPTION 'active product fixture changed during migration upgrade';
    END IF;
    IF (SELECT deleted_at IS NULL FROM products WHERE id = '00000000-0000-4000-8000-000000000022') IS NOT FALSE THEN
        RAISE EXCEPTION 'product tombstone was not preserved';
    END IF;
    IF (SELECT COUNT(*) FROM stock_movements) <> 1 THEN
        RAISE EXCEPTION 'stock movement fixture was not preserved';
    END IF;
    IF (SELECT delta FROM stock_movements LIMIT 1) <> 7
       OR (SELECT kind FROM stock_movements LIMIT 1) <> 'stocktake'
       OR (SELECT counted_qty FROM stock_movements LIMIT 1) <> 7 THEN
        RAISE EXCEPTION 'stocktake fields changed during migration upgrade';
    END IF;
    IF (SELECT qty FROM product_balances LIMIT 1) <> 7 THEN
        RAISE EXCEPTION 'balance projection fixture was not preserved';
    END IF;
    IF (SELECT last_seq FROM sync_seq_counter WHERE id = 1) <> 1 THEN
        RAISE EXCEPTION 'sync sequence counter was not preserved';
    END IF;
    IF (SELECT COUNT(*) FROM change_log) <> 1
       OR (SELECT payload ->> 'counted_qty' FROM change_log LIMIT 1) <> '7' THEN
        RAISE EXCEPTION 'change-log stocktake fixture was not preserved';
    END IF;
    IF (SELECT reason FROM sync_ops LIMIT 1) <> 'stocktake_conflict'
       OR (SELECT response ->> 'reason' FROM sync_ops LIMIT 1) <> 'stocktake_conflict' THEN
        RAISE EXCEPTION 'sync conflict outcome was not preserved';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE indexname = 'products_active_barcode_uq'
    ) THEN
        RAISE EXCEPTION 'active barcode index was not installed';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE indexname = 'users_email_lower_uq'
    ) THEN
        RAISE EXCEPTION 'case-insensitive email index was not installed';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE indexname = 'refresh_tokens_token_hash_uq'
    ) THEN
        RAISE EXCEPTION 'refresh-token digest index was not installed';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'sync_ops_pkey'
    ) THEN
        RAISE EXCEPTION 'composite sync idempotency key was not installed';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_kind_check'
    ) THEN
        RAISE EXCEPTION 'movement-kind constraint was not installed';
    END IF;

    BEGIN
        INSERT INTO products (
            id, user_id, barcode, name, updated_by_device_id
        )
        VALUES (
            '00000000-0000-4000-8000-000000000099',
            '00000000-0000-4000-8000-000000000001',
            'legacy-barcode',
            'Active barcode collision',
            '00000000-0000-4000-8000-000000000011'
        );
        RAISE EXCEPTION 'active barcode uniqueness was not restored';
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'products_active_barcode_uq' THEN
            RAISE EXCEPTION 'unexpected active-barcode constraint: %', constraint_name;
        END IF;
    END;

    BEGIN
        INSERT INTO stock_movements (
            id, user_id, product_id, delta, kind, occurred_at,
            raw_occurred_at, device_id
        )
        VALUES (
            '00000000-0000-4000-8000-000000000099',
            '00000000-0000-4000-8000-000000000001',
            '00000000-0000-4000-8000-000000000021',
            0,
            'issue',
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP,
            '00000000-0000-4000-8000-000000000011'
        );
        RAISE EXCEPTION 'zero movement delta was accepted after upgrade';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'stock_movements_delta_nonzero_check' THEN
            RAISE EXCEPTION 'unexpected zero-delta constraint: %', constraint_name;
        END IF;
    END;

    BEGIN
        INSERT INTO stock_movements (
            id, user_id, product_id, delta, kind, occurred_at,
            raw_occurred_at, device_id
        )
        VALUES (
            '00000000-0000-4000-8000-000000000099',
            '00000000-0000-4000-8000-000000000001',
            '00000000-0000-4000-8000-000000000021',
            1,
            'transfer',
            CURRENT_TIMESTAMP,
            CURRENT_TIMESTAMP,
            '00000000-0000-4000-8000-000000000011'
        );
        RAISE EXCEPTION 'unsupported movement kind was accepted after upgrade';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'stock_movements_kind_check' THEN
            RAISE EXCEPTION 'unexpected movement-kind constraint: %', constraint_name;
        END IF;
    END;

    BEGIN
        INSERT INTO sync_ops (
            device_id, op_id, user_id, status, response
        )
        VALUES (
            '00000000-0000-4000-8000-000000000011',
            '00000000-0000-4000-8000-000000000041',
            '00000000-0000-4000-8000-000000000001',
            'rejected',
            '{}'::JSONB
        );
        RAISE EXCEPTION 'duplicate sync operation was accepted after upgrade';
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'sync_ops_pkey' THEN
            RAISE EXCEPTION 'unexpected idempotency constraint: %', constraint_name;
        END IF;
    END;

    BEGIN
        INSERT INTO users (id, email, password_hash)
        VALUES (
            '00000000-0000-4000-8000-000000000099',
            '',
            'hash'
        );
        RAISE EXCEPTION 'empty user email was accepted after upgrade';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'users_email_nonempty_check' THEN
            RAISE EXCEPTION 'unexpected email constraint: %', constraint_name;
        END IF;
    END;
END;
$$;

SELECT 'migration upgrade validation passed' AS result;
