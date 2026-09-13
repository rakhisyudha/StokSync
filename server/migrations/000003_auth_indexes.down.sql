-- Reverse 000003_auth_indexes.

ALTER TABLE refresh_tokens
    DROP CONSTRAINT refresh_tokens_token_hash_nonempty_check;

ALTER TABLE users
    DROP CONSTRAINT users_password_hash_nonempty_check,
    DROP CONSTRAINT users_email_nonempty_check;

DROP INDEX refresh_tokens_token_hash_uq;
DROP INDEX users_email_lower_uq;
