package db

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

const (
	insertUserSQL = `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)
ON CONFLICT (lower(email)) DO NOTHING
RETURNING id, email, password_hash, created_at, updated_at`

	getUserByEmailSQL = `
SELECT id, email, password_hash, created_at, updated_at
FROM users
WHERE lower(email) = $1`

	getDeviceSQL = `
SELECT id, user_id, name, platform, last_seen_at, last_ack_seq, created_at
FROM devices
WHERE user_id = $1 AND id = $2`

	registerDeviceSQL = `
INSERT INTO devices (id, user_id, name, platform, last_seen_at)
VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    platform = EXCLUDED.platform,
    last_seen_at = CURRENT_TIMESTAMP
WHERE devices.user_id = EXCLUDED.user_id
RETURNING id, user_id, name, platform, last_seen_at, last_ack_seq, created_at`

	getRefreshTokenForUpdateSQL = `
SELECT id, user_id, device_id, token_hash, expires_at, revoked_at,
       rotated_at, created_at
FROM refresh_tokens
WHERE token_hash = $1
FOR UPDATE`

	insertRefreshTokenSQL = `
INSERT INTO refresh_tokens (id, user_id, device_id, token_hash, expires_at)
VALUES ($1, $2, $3, $4, $5)
RETURNING id, user_id, device_id, token_hash, expires_at, revoked_at,
          rotated_at, created_at`

	markRefreshTokenRotatedSQL = `
UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP,
    rotated_at = CURRENT_TIMESTAMP
WHERE id = $1 AND revoked_at IS NULL
RETURNING id, user_id, device_id, token_hash, expires_at, revoked_at,
          rotated_at, created_at`

	revokeRefreshTokenSQL = `
UPDATE refresh_tokens
SET revoked_at = COALESCE(revoked_at, CURRENT_TIMESTAMP)
WHERE id = $1
RETURNING id, user_id, device_id, token_hash, expires_at, revoked_at,
          rotated_at, created_at`

	revokeDeviceRefreshTokensSQL = `
UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP
WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL`
)

// InsertUser creates one account row. Email normalization and password policy
// belong to the auth service, not the persistence layer.
func (q *Queries) InsertUser(ctx context.Context, params CreateUserParams) (User, error) {
	return scanUser(q.db.QueryRow(ctx, insertUserSQL,
		uuidArg(params.ID), params.Email, params.PasswordHash))
}

// GetUserByEmail performs a case-insensitive lookup using the normalized email
// index. It returns pgx.ErrNoRows without revealing whether an account exists.
func (q *Queries) GetUserByEmail(ctx context.Context, email string) (User, error) {
	return scanUser(q.db.QueryRow(ctx, getUserByEmailSQL, email))
}

// GetDevice returns a registered installation only when it belongs to the
// requested account. The ownership predicate prevents a valid token from
// using a device UUID registered to another account.
func (q *Queries) GetDevice(ctx context.Context, userID, deviceID uuid.UUID) (Device, error) {
	return scanDevice(q.db.QueryRow(ctx, getDeviceSQL, uuidArg(userID), uuidArg(deviceID)))
}

// RegisterDevice creates or refreshes an installation only when the existing
// device row belongs to the same account. A cross-account UUID returns
// pgx.ErrNoRows and is mapped by the auth service to a device conflict.
func (q *Queries) RegisterDevice(ctx context.Context, params RegisterDeviceParams) (Device, error) {
	return scanDevice(q.db.QueryRow(ctx, registerDeviceSQL,
		uuidArg(params.ID), uuidArg(params.UserID), params.Name, params.Platform))
}

// GetRefreshTokenForUpdate locks an opaque token record for an atomic refresh
// decision. The unique token-hash index makes this one-row lookup bounded.
func (q *Queries) GetRefreshTokenForUpdate(ctx context.Context, tokenHash string) (RefreshToken, error) {
	return scanRefreshToken(q.db.QueryRow(ctx, getRefreshTokenForUpdateSQL, tokenHash))
}

// InsertRefreshToken stores only a digest of the bearer refresh token.
func (q *Queries) InsertRefreshToken(ctx context.Context, params CreateRefreshTokenParams) (RefreshToken, error) {
	return scanRefreshToken(q.db.QueryRow(ctx, insertRefreshTokenSQL,
		uuidArg(params.ID), uuidArg(params.UserID), uuidArg(params.DeviceID),
		params.TokenHash, params.ExpiresAt))
}

// MarkRefreshTokenRotated atomically consumes a refresh token during a
// successful rotation. pgx.ErrNoRows indicates an unexpected concurrent state.
func (q *Queries) MarkRefreshTokenRotated(ctx context.Context, tokenID uuid.UUID) (RefreshToken, error) {
	return scanRefreshToken(q.db.QueryRow(ctx, markRefreshTokenRotatedSQL, uuidArg(tokenID)))
}

// RevokeRefreshToken makes a token unusable without deleting its audit row.
func (q *Queries) RevokeRefreshToken(ctx context.Context, tokenID uuid.UUID) (RefreshToken, error) {
	return scanRefreshToken(q.db.QueryRow(ctx, revokeRefreshTokenSQL, uuidArg(tokenID)))
}

// RevokeDeviceRefreshTokens revokes every currently active token for a device.
// It is used for explicit logout and for refresh-token reuse detection.
func (q *Queries) RevokeDeviceRefreshTokens(ctx context.Context, userID, deviceID uuid.UUID) (int64, error) {
	result, err := q.db.Exec(ctx, revokeDeviceRefreshTokensSQL, uuidArg(userID), uuidArg(deviceID))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected(), nil
}

func scanUser(row pgx.Row) (User, error) {
	var id pgtype.UUID
	var email, passwordHash string
	var createdAt, updatedAt pgtype.Timestamptz
	if err := row.Scan(&id, &email, &passwordHash, &createdAt, &updatedAt); err != nil {
		return User{}, err
	}
	return User{
		ID:           uuidFromPG(id),
		Email:        email,
		PasswordHash: passwordHash,
		CreatedAt:    createdAt.Time,
		UpdatedAt:    updatedAt.Time,
	}, nil
}

func scanDevice(row pgx.Row) (Device, error) {
	var id, userID pgtype.UUID
	var name, platform string
	var lastSeenAt pgtype.Timestamptz
	var lastAckSeq int64
	var createdAt pgtype.Timestamptz
	if err := row.Scan(&id, &userID, &name, &platform, &lastSeenAt, &lastAckSeq, &createdAt); err != nil {
		return Device{}, err
	}
	return Device{
		ID:         uuidFromPG(id),
		UserID:     uuidFromPG(userID),
		Name:       name,
		Platform:   platform,
		LastSeenAt: timeFromPG(lastSeenAt),
		LastAckSeq: lastAckSeq,
		CreatedAt:  createdAt.Time,
	}, nil
}

func scanRefreshToken(row pgx.Row) (RefreshToken, error) {
	var id, userID, deviceID pgtype.UUID
	var tokenHash string
	var expiresAt, revokedAt, rotatedAt, createdAt pgtype.Timestamptz
	if err := row.Scan(
		&id, &userID, &deviceID, &tokenHash, &expiresAt, &revokedAt,
		&rotatedAt, &createdAt,
	); err != nil {
		return RefreshToken{}, err
	}
	return RefreshToken{
		ID:        uuidFromPG(id),
		UserID:    uuidFromPG(userID),
		DeviceID:  uuidFromPG(deviceID),
		TokenHash: tokenHash,
		ExpiresAt: expiresAt.Time,
		RevokedAt: timeFromPG(revokedAt),
		RotatedAt: timeFromPG(rotatedAt),
		CreatedAt: createdAt.Time,
	}, nil
}
