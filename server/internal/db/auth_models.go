package db

import (
	"time"

	"github.com/google/uuid"
)

// User is the persisted account identity used by authentication.
type User struct {
	ID           uuid.UUID
	Email        string
	PasswordHash string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

// CreateUserParams contains normalized account fields accepted by the
// registration service. Passwords are hashed before they reach this layer.
type CreateUserParams struct {
	ID           uuid.UUID
	Email        string
	PasswordHash string
}

// Device is an account-owned installation identity. A device UUID cannot be
// reassigned to another account.
type Device struct {
	ID         uuid.UUID
	UserID     uuid.UUID
	Name       string
	Platform   string
	LastSeenAt *time.Time
	LastAckSeq int64
	CreatedAt  time.Time
}

// RegisterDeviceParams identifies a client installation and its display
// metadata. RegisterDevice is an idempotent same-owner upsert.
type RegisterDeviceParams struct {
	ID       uuid.UUID
	UserID   uuid.UUID
	Name     string
	Platform string
}

// RefreshToken is an opaque-token record. TokenHash is persisted instead of
// the bearer value; the row is locked during rotation or reuse handling.
type RefreshToken struct {
	ID        uuid.UUID
	UserID    uuid.UUID
	DeviceID  uuid.UUID
	TokenHash string
	ExpiresAt time.Time
	RevokedAt *time.Time
	RotatedAt *time.Time
	CreatedAt time.Time
}

// CreateRefreshTokenParams contains one newly generated refresh-token record.
type CreateRefreshTokenParams struct {
	ID        uuid.UUID
	UserID    uuid.UUID
	DeviceID  uuid.UUID
	TokenHash string
	ExpiresAt time.Time
}
