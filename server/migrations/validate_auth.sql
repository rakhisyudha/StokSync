\set ON_ERROR_STOP on

-- Reproducible validation for 000003 authentication invariants.
-- The transaction is rolled back and leaves no fixture data behind.
BEGIN;

DO $$
DECLARE
    user_one UUID := '00000000-0000-4000-8000-000000000101';
    user_two UUID := '00000000-0000-4000-8000-000000000102';
    device_one UUID := '00000000-0000-4000-8000-000000000111';
    token_one UUID := '00000000-0000-4000-8000-000000000121';
    token_two UUID := '00000000-0000-4000-8000-000000000122';
    constraint_name TEXT;
BEGIN
    INSERT INTO users (id, email, password_hash)
    VALUES (user_one, 'Auth-Check@example.test', 'bcrypt-hash');

    -- The unique index is case-insensitive because the service normalizes
    -- email addresses before querying or inserting them.
    BEGIN
        INSERT INTO users (id, email, password_hash)
        VALUES (user_two, 'auth-check@EXAMPLE.test', 'bcrypt-hash');
        RAISE EXCEPTION 'case-insensitive duplicate email was accepted';
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'users_email_lower_uq' THEN
            RAISE EXCEPTION 'unexpected constraint for duplicate email: %', constraint_name;
        END IF;
    END;

    INSERT INTO devices (id, user_id, name, platform)
    VALUES (device_one, user_one, 'auth check device', 'test');

    INSERT INTO refresh_tokens (id, user_id, device_id, token_hash, expires_at)
    VALUES (token_one, user_one, device_one, repeat('a', 64), CURRENT_TIMESTAMP + INTERVAL '1 hour');

    BEGIN
        INSERT INTO refresh_tokens (id, user_id, device_id, token_hash, expires_at)
        VALUES (token_two, user_one, device_one, repeat('a', 64), CURRENT_TIMESTAMP + INTERVAL '1 hour');
        RAISE EXCEPTION 'duplicate refresh-token digest was accepted';
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS constraint_name = CONSTRAINT_NAME;
        IF constraint_name <> 'refresh_tokens_token_hash_uq' THEN
            RAISE EXCEPTION 'unexpected constraint for duplicate digest: %', constraint_name;
        END IF;
    END;
END $$;

ROLLBACK;
\echo '000003 authentication validation passed'
