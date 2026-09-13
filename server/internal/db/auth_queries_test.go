package db

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
)

func TestRegisterDeviceQueryPreservesOwnershipPredicate(t *testing.T) {
	t.Parallel()

	deviceID := uuid.New()
	userID := uuid.New()
	now := time.Now().UTC()
	fake := &fakeQueryDB{row: staticRow{values: []any{
		uuidArg(deviceID), uuidArg(userID), "Phone", "android",
		pgtype.Timestamptz{Time: now, Valid: true}, int64(0),
		pgtype.Timestamptz{Time: now, Valid: true},
	}}}
	device, err := NewQueries(fake).RegisterDevice(context.Background(), RegisterDeviceParams{
		ID: deviceID, UserID: userID, Name: "Phone", Platform: "android",
	})
	if err != nil {
		t.Fatalf("RegisterDevice() error = %v", err)
	}
	if device.ID != deviceID || device.UserID != userID {
		t.Fatalf("device = %#v, want requested owner", device)
	}
	if !strings.Contains(fake.lastQuery, "WHERE devices.user_id = EXCLUDED.user_id") {
		t.Error("RegisterDevice query can update a device across account ownership")
	}
}

func TestRefreshTokenQueriesLockAndPersistOnlyDigest(t *testing.T) {
	t.Parallel()

	id := uuid.New()
	userID := uuid.New()
	deviceID := uuid.New()
	expiresAt := time.Now().Add(time.Hour).UTC()
	fake := &fakeQueryDB{row: staticRow{values: []any{
		uuidArg(id), uuidArg(userID), uuidArg(deviceID),
		"digest", pgtype.Timestamptz{Time: expiresAt, Valid: true},
		pgtype.Timestamptz{}, pgtype.Timestamptz{}, pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true},
	}}}
	token, err := NewQueries(fake).GetRefreshTokenForUpdate(context.Background(), "digest")
	if err != nil {
		t.Fatalf("GetRefreshTokenForUpdate() error = %v", err)
	}
	if token.TokenHash != "digest" || token.ID != id {
		t.Fatalf("token = %#v, want digest row", token)
	}
	if !strings.Contains(fake.lastQuery, "FOR UPDATE") {
		t.Error("refresh lookup does not lock the row for rotation")
	}
}
