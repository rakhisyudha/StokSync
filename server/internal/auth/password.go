// Package auth implements account authentication and device-bound sessions.
package auth

import (
	"errors"
	"fmt"

	"golang.org/x/crypto/bcrypt"
)

const (
	// DefaultPasswordHashCost is intentionally adaptive and can be overridden
	// only for controlled tests or an explicit deployment decision.
	DefaultPasswordHashCost      = 12
	MinRegistrationPasswordBytes = 8
	MaxPasswordBytes             = 72 // bcrypt's maximum input length.
)

var (
	ErrPasswordEmpty   = errors.New("password must not be empty")
	ErrPasswordTooLong = errors.New("password is too long")
)

// PasswordHasher wraps bcrypt so password material stays inside the auth
// package and is never returned in an error or log field.
type PasswordHasher struct {
	cost      int
	dummyHash []byte
}

// NewPasswordHasher creates a bcrypt hasher and a dummy hash used for
// user-not-found login attempts to reduce account-enumeration timing leaks.
func NewPasswordHasher(cost int) (*PasswordHasher, error) {
	if cost == 0 {
		cost = DefaultPasswordHashCost
	}
	if cost < bcrypt.MinCost || cost > bcrypt.MaxCost {
		return nil, fmt.Errorf("password hash cost must be between %d and %d", bcrypt.MinCost, bcrypt.MaxCost)
	}
	dummyHash, err := bcrypt.GenerateFromPassword([]byte("stoksync-login-timing-dummy"), cost)
	if err != nil {
		return nil, fmt.Errorf("initialize password verifier: %w", err)
	}
	return &PasswordHasher{cost: cost, dummyHash: dummyHash}, nil
}

// Hash creates an adaptive bcrypt hash. Registration-specific minimum length
// policy is enforced by the service; this method also supports hashing an
// existing non-empty password for migrations and tests.
func (h *PasswordHasher) Hash(password string) (string, error) {
	if h == nil {
		return "", errors.New("password hasher is nil")
	}
	if err := validatePasswordBytes(password); err != nil {
		return "", err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), h.cost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	return string(hash), nil
}

// Verify compares a password with a stored bcrypt hash. It intentionally
// returns only a boolean so callers cannot accidentally expose hash details.
func (h *PasswordHasher) Verify(storedHash, password string) bool {
	if h == nil || storedHash == "" || validatePasswordBytes(password) != nil {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(password)) == nil
}

// VerifyDummy performs the same bcrypt comparison used for a missing account.
func (h *PasswordHasher) VerifyDummy(password string) bool {
	if h == nil {
		return false
	}
	return h.Verify(string(h.dummyHash), password)
}

func validatePasswordBytes(password string) error {
	if len(password) == 0 {
		return ErrPasswordEmpty
	}
	if len([]byte(password)) > MaxPasswordBytes {
		return ErrPasswordTooLong
	}
	return nil
}
