-- StokSync authentication invariants, version 3.
--
-- Account email lookup is normalized by the auth service and made unique
-- case-insensitively. Refresh-token digests are unique so a bearer value can
-- never resolve to more than one rotation record.

CREATE UNIQUE INDEX users_email_lower_uq
    ON users (lower(email));

CREATE UNIQUE INDEX refresh_tokens_token_hash_uq
    ON refresh_tokens (token_hash);

ALTER TABLE users
    ADD CONSTRAINT users_email_nonempty_check
        CHECK (btrim(email) <> ''),
    ADD CONSTRAINT users_password_hash_nonempty_check
        CHECK (btrim(password_hash) <> '');

ALTER TABLE refresh_tokens
    ADD CONSTRAINT refresh_tokens_token_hash_nonempty_check
        CHECK (btrim(token_hash) <> '');
