package auth

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestTokenManagerIssuesAndValidatesBoundAccessToken(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.January, 2, 3, 4, 5, 600_000_000, time.UTC)
	manager, err := NewTokenManager(
		"01234567890123456789012345678901",
		"stoksync-api",
		"stoksync-client",
		15*time.Minute,
		func() time.Time { return now },
	)
	if err != nil {
		t.Fatalf("NewTokenManager() error = %v", err)
	}
	userID := uuid.New()
	deviceID := uuid.New()
	token, expiresAt, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	claims, err := manager.ValidateAccessToken(token)
	if err != nil {
		t.Fatalf("ValidateAccessToken() error = %v", err)
	}
	if claims.UserID != userID || claims.DeviceID != deviceID {
		t.Fatalf("claims identity = (%s, %s), want (%s, %s)", claims.UserID, claims.DeviceID, userID, deviceID)
	}
	if !claims.ExpiresAt.Equal(expiresAt) || !claims.IssuerMatches("stoksync-api") {
		t.Fatalf("claims = %#v, want issued expiry/issuer", claims)
	}
}

func TestTokenManagerRejectsTamperingAndExpiry(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.February, 3, 4, 5, 6, 0, time.UTC)
	manager, err := NewTokenManager(
		"01234567890123456789012345678901",
		"stoksync-api",
		"stoksync-client",
		time.Minute,
		func() time.Time { return now },
	)
	if err != nil {
		t.Fatalf("NewTokenManager() error = %v", err)
	}
	token, _, err := manager.IssueAccessToken(uuid.New(), uuid.New())
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	parts := strings.Split(token, ".")
	last := parts[1][len(parts[1])-1]
	if last == 'A' {
		last = 'B'
	} else {
		last = 'A'
	}
	parts[1] = parts[1][:len(parts[1])-1] + string(last)
	if _, err := manager.ValidateAccessToken(strings.Join(parts, ".")); err == nil {
		t.Error("ValidateAccessToken() accepted a tampered payload")
	}

	now = now.Add(2 * time.Minute)
	if _, err := manager.ValidateAccessToken(token); err == nil {
		t.Error("ValidateAccessToken() accepted an expired token")
	}
}

func TestNewTokenManagerRejectsWeakSecret(t *testing.T) {
	t.Parallel()

	if _, err := NewTokenManager("too-short", "issuer", "audience", time.Minute, time.Now); err == nil {
		t.Fatal("NewTokenManager() accepted a weak signing secret")
	}
}

// IssuerMatches keeps the test readable while the production claims remain
// intentionally field-based and immutable.
func (c AccessClaims) IssuerMatches(want string) bool { return c.Issuer == want }
