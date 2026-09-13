\set ON_ERROR_STOP on

-- Reproducible post-migration constraint validation for 000002.
-- The transaction is rolled back, so this script leaves no fixture data behind.
BEGIN;

DO $$
DECLARE
    user_one UUID := '00000000-0000-4000-8000-000000000001';
    user_two UUID := '00000000-0000-4000-8000-000000000002';
    device_one UUID := '00000000-0000-4000-8000-000000000011';
    device_two UUID := '00000000-0000-4000-8000-000000000012';
    product_one UUID := '00000000-0000-4000-8000-000000000021';
    product_two UUID := '00000000-0000-4000-8000-000000000022';
    deleted_product UUID := '00000000-0000-4000-8000-000000000023';
    movement_one UUID := '00000000-0000-4000-8000-000000000031';
    movement_two UUID := '00000000-0000-4000-8000-000000000032';
    reversal UUID := '00000000-0000-4000-8000-000000000033';
    op_one UUID := '00000000-0000-4000-8000-000000000041';
    constraint_name TEXT;
BEGIN
    -- Positive fixtures: valid ownership, product, ledger, projection, and
    -- idempotency rows are accepted.
    INSERT INTO users (id, email, password_hash)
    VALUES
        (user_one, 'schema-check-one@example.test', 'hash-one'),
        (user_two, 'schema-check-two@example.test', 'hash-two');

    INSERT INTO devices (id, user_id, name, platform)
    VALUES
        (device_one, user_one, 'schema-check-device-one', 'test'),
        (device_two, user_two, 'schema-check-device-two', 'test');

    INSERT INTO products (
        id, user_id, barcode, name, updated_by_device_id, deleted_at
    )
    VALUES
        (product_one, user_one, 'schema-check-barcode', 'Valid product', device_one, NULL),
        (product_two, user_two, 'schema-check-barcode-two', 'Other owner', device_two, NULL),
        (
            deleted_product,
            user_one,
            'schema-check-barcode',
            'Deleted duplicate barcode',
            device_one,
            CURRENT_TIMESTAMP
        );

    INSERT INTO stock_movements (
        id,
        user_id,
        product_id,
        delta,
        kind,
        occurred_at,
        raw_occurred_at,
        device_id
    )
    VALUES (
        movement_one,
        user_one,
        product_one,
        5,
        'receive',
        TIMESTAMPTZ '2026-01-01 00:00:00+00',
        TIMESTAMPTZ '2026-01-01 00:00:00+00',
        device_one
    );

    INSERT INTO stock_movements (
        id,
        user_id,
        product_id,
        delta,
        kind,
        occurred_at,
        raw_occurred_at,
        device_id,
        reverses_id
    )
    VALUES (
        reversal,
        user_one,
        product_one,
        -5,
        'adjust',
        TIMESTAMPTZ '2026-01-01 00:01:00+00',
        TIMESTAMPTZ '2026-01-01 00:01:00+00',
        device_one,
        movement_one
    );

    INSERT INTO product_balances (product_id, qty)
    VALUES (product_one, 0);

    INSERT INTO sync_ops (
        device_id, op_id, user_id, status, response
    )
    VALUES (device_one, op_one, user_one, 'applied', '{}'::JSONB);

    -- The same operation id is valid for another device because idempotency
    -- is scoped by the composite (device_id, op_id) key.
    INSERT INTO sync_ops (
        device_id, op_id, user_id, status, response
    )
    VALUES (device_two, op_one, user_two, 'applied', '{}'::JSONB);

    IF (SELECT version FROM products WHERE id = product_one) <> 1 THEN
        RAISE EXCEPTION 'positive product version fixture was not accepted';
    END IF;

    -- Non-zero movement delta.
    BEGIN
        INSERT INTO stock_movements (
            id, user_id, product_id, delta, kind, occurred_at,
            raw_occurred_at, device_id
        )
        VALUES (
            movement_two, user_one, product_one, 0, 'issue',
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, device_one
        );
        RAISE EXCEPTION 'zero stock movement delta was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'stock_movements_delta_nonzero_check' THEN
            RAISE EXCEPTION 'unexpected constraint for zero delta: %', constraint_name;
        END IF;
    END;

    -- Enumerated movement kind.
    BEGIN
        INSERT INTO stock_movements (
            id, user_id, product_id, delta, kind, occurred_at,
            raw_occurred_at, device_id
        )
        VALUES (
            movement_two, user_one, product_one, 1, 'transfer',
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, device_one
        );
        RAISE EXCEPTION 'unsupported stock movement kind was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'stock_movements_kind_check' THEN
            RAISE EXCEPTION 'unexpected constraint for movement kind: %', constraint_name;
        END IF;
    END;

    -- Product versions are one-based.
    BEGIN
        INSERT INTO products (
            id, user_id, name, version, updated_by_device_id
        )
        VALUES (
            movement_two, user_one, 'Invalid version', 0, device_one
        );
        RAISE EXCEPTION 'zero product version was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'products_version_positive_check' THEN
            RAISE EXCEPTION 'unexpected constraint for product version: %', constraint_name;
        END IF;
    END;

    -- Active barcode uniqueness still allows the same barcode on a tombstone.
    BEGIN
        INSERT INTO products (
            id, user_id, barcode, name, updated_by_device_id
        )
        VALUES (
            movement_two, user_one, 'schema-check-barcode',
            'Active barcode collision', device_one
        );
        RAISE EXCEPTION 'duplicate active barcode was accepted';
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'products_active_barcode_uq' THEN
            RAISE EXCEPTION 'unexpected constraint for active barcode: %', constraint_name;
        END IF;
    END;

    -- Cross-owner product, device, and product-update-device relationships.
    BEGIN
        INSERT INTO stock_movements (
            id, user_id, product_id, delta, kind, occurred_at,
            raw_occurred_at, device_id
        )
        VALUES (
            movement_two, user_one, product_two, 1, 'receive',
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, device_one
        );
        RAISE EXCEPTION 'cross-owner product movement was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'stock_movements_product_owner_fkey' THEN
            RAISE EXCEPTION 'unexpected constraint for product ownership: %', constraint_name;
        END IF;
    END;

    BEGIN
        INSERT INTO stock_movements (
            id, user_id, product_id, delta, kind, occurred_at,
            raw_occurred_at, device_id
        )
        VALUES (
            movement_two, user_one, product_one, 1, 'receive',
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, device_two
        );
        RAISE EXCEPTION 'cross-owner device movement was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'stock_movements_device_owner_fkey' THEN
            RAISE EXCEPTION 'unexpected constraint for device ownership: %', constraint_name;
        END IF;
    END;

    BEGIN
        INSERT INTO products (
            id, user_id, name, updated_by_device_id
        )
        VALUES (
            movement_two, user_one, 'Cross-owner editor', device_two
        );
        RAISE EXCEPTION 'cross-owner product editor was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'products_updated_by_device_owner_fkey' THEN
            RAISE EXCEPTION 'unexpected constraint for product editor: %', constraint_name;
        END IF;
    END;

    -- The idempotency primary key rejects a duplicate delivery for the same
    -- device while allowing the same operation id from another device.
    BEGIN
        INSERT INTO sync_ops (
            device_id, op_id, user_id, status, response
        )
        VALUES (device_one, op_one, user_one, 'applied', '{}'::JSONB);
        RAISE EXCEPTION 'duplicate device operation was accepted';
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'sync_ops_pkey' THEN
            RAISE EXCEPTION 'unexpected constraint for duplicate operation: %', constraint_name;
        END IF;
    END;
END;
$$;

ROLLBACK;

SELECT '000002 constraint validation passed' AS result;
