package auth

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/stoksync/stoksync/server/internal/db"
)

// TestPostgresAuthSessionLifecycle is opt-in and exercises the real
// transaction boundaries when STOKSYNC_TEST_DATABASE_URL points at migrated
// PostgreSQL. Offline CI still covers all token and handler behavior.
func TestPostgresAuthSessionLifecycle(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL auth integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, db.PoolConfig{URL: databaseURL, MaxConns: 4, MinConns: 0})
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	service, err := NewService(pool, Config{
		AccessTokenSecret: "01234567890123456789012345678901",
		AccessTokenTTL:    15 * time.Minute,
		RefreshTokenTTL:   time.Hour,
		PasswordHashCost:  4,
	})
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	deviceID := uuid.New()
	input := LoginInput{
		Email:      "auth-integration-" + uuid.New().String() + "@example.test",
		Password:   "correct horse battery staple",
		DeviceID:   deviceID,
		DeviceName: "integration phone",
		Platform:   "test",
	}
	registered, err := service.Register(ctx, input)
	if err != nil {
		t.Fatalf("Register() error = %v", err)
	}
	if _, err := service.Register(ctx, input); !errors.Is(err, ErrEmailTaken) {
		t.Fatalf("duplicate account registration error = %v, want ErrEmailTaken", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(queries *db.Queries) error {
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM refresh_tokens WHERE user_id = $1::uuid`, registered.UserID.String()); err != nil {
				return err
			}
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1::uuid`, registered.UserID.String()); err != nil {
				return err
			}
			_, err := queries.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1::uuid`, registered.UserID.String())
			return err
		})
	})

	claims, err := service.tokens.ValidateAccessToken(registered.AccessToken)
	if err != nil || claims.UserID != registered.UserID || claims.DeviceID != deviceID {
		t.Fatalf("registered access claims = (%#v, %v), want account/device identity", claims, err)
	}
	rotated, err := service.Refresh(ctx, registered.RefreshToken)
	if err != nil {
		t.Fatalf("Refresh() error = %v", err)
	}
	if rotated.RefreshToken == registered.RefreshToken {
		t.Fatal("Refresh() returned the same refresh token")
	}
	secondEmail := "auth-integration-device-conflict-" + uuid.New().String() + "@example.test"
	if _, err := service.Register(ctx, LoginInput{
		Email:      secondEmail,
		Password:   "correct horse battery staple",
		DeviceID:   deviceID,
		DeviceName: "other phone",
		Platform:   "test",
	}); !errors.Is(err, ErrDeviceOwnership) {
		t.Fatalf("cross-account device registration error = %v, want ErrDeviceOwnership", err)
	}
	if _, err := pool.Queries().GetUserByEmail(ctx, secondEmail); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("cross-account device registration left account row, lookup error = %v", err)
	}
	if err := service.RevokeDeviceSessions(ctx, registered.UserID, deviceID); err != nil {
		t.Fatalf("RevokeDeviceSessions() error = %v", err)
	}
	if _, err := service.Refresh(ctx, rotated.RefreshToken); !errors.Is(err, ErrRefreshTokenReuse) {
		t.Fatalf("revoked refresh token error = %v, want ErrRefreshTokenReuse", err)
	}
	if _, err := service.Refresh(ctx, registered.RefreshToken); !errors.Is(err, ErrRefreshTokenReuse) {
		t.Fatalf("reused refresh token error = %v, want ErrRefreshTokenReuse", err)
	}
}
