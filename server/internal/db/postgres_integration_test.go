package db

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

// TestPostgresPersistenceIntegration is opt-in so offline unit-test runs do
// not require Docker. Set STOKSYNC_TEST_DATABASE_URL to a migrated PostgreSQL
// database to exercise transaction boundaries and representative mappings.
func TestPostgresPersistenceIntegration(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL integration tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool, err := Open(ctx, PoolConfig{
		URL:               databaseURL,
		MaxConns:          4,
		MinConns:          0,
		MaxConnLifetime:   time.Hour,
		MaxConnIdleTime:   30 * time.Minute,
		HealthCheckPeriod: time.Minute,
	})
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	var usersTable string
	if err := pool.QueryRow(ctx, `SELECT to_regclass('public.users')`).Scan(&usersTable); err != nil {
		t.Fatalf("check migrated schema: %v", err)
	}
	if usersTable != "users" {
		t.Fatalf("users table = %q, want migrated users table", usersTable)
	}

	rollbackUserID := uuid.New()
	rollbackErr := errors.New("force rollback for integration test")
	err = pool.WithTx(ctx, func(queries *Queries) error {
		_, err := queries.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, uuidArg(rollbackUserID), "rollback@example.test", "test-hash")
		if err != nil {
			return err
		}
		return rollbackErr
	})
	if !errors.Is(err, rollbackErr) {
		t.Fatalf("rollback transaction error = %v, want callback error", err)
	}
	var rollbackCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE id = $1`, uuidArg(rollbackUserID)).Scan(&rollbackCount); err != nil {
		t.Fatalf("check rollback fixture: %v", err)
	}
	if rollbackCount != 0 {
		t.Fatalf("rollback fixture count = %d, want 0", rollbackCount)
	}

	userID := uuid.New()
	deviceID := uuid.New()
	productID := uuid.New()
	movementID := uuid.New()
	opID := uuid.New()
	occurredAt := time.Date(2026, time.May, 6, 7, 8, 9, 0, time.UTC)
	response := []byte(`{"op_id":"` + opID.String() + `","status":"applied"}`)

	cleanup := func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(queries *Queries) error {
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM sync_ops WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM change_log WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM product_balances WHERE product_id = $1`, uuidArg(productID)); err != nil {
				return err
			}
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM stock_movements WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM products WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			if _, err := queries.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			_, err := queries.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, uuidArg(userID))
			return err
		})
	}
	t.Cleanup(cleanup)

	completedAt := occurredAt.Add(time.Second)
	err = pool.WithTx(ctx, func(queries *Queries) error {
		if _, err := queries.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, uuidArg(userID), "integration@example.test", "test-hash"); err != nil {
			return err
		}
		if _, err := queries.DB().Exec(ctx, `
INSERT INTO devices (id, user_id, name, platform)
VALUES ($1, $2, $3, $4)`, uuidArg(deviceID), uuidArg(userID), "integration-device", "test"); err != nil {
			return err
		}

		if _, err := queries.InsertProduct(ctx, CreateProductParams{
			ID:                productID,
			UserID:            userID,
			Name:              "Integration product",
			Unit:              "pcs",
			UpdatedByDeviceID: deviceID,
		}); err != nil {
			return err
		}
		if _, err := queries.InsertStockMovement(ctx, CreateStockMovementParams{
			ID:            movementID,
			UserID:        userID,
			ProductID:     productID,
			Delta:         5,
			Kind:          "receive",
			OccurredAt:    occurredAt,
			RawOccurredAt: occurredAt,
			DeviceID:      deviceID,
		}); err != nil {
			return err
		}
		if _, err := queries.IncrementProductBalance(ctx, IncrementProductBalanceParams{
			UserID:     userID,
			ProductID:  productID,
			Delta:      5,
			OccurredAt: occurredAt,
		}); err != nil {
			return err
		}
		if _, err := queries.AppendChangeLog(ctx, AppendChangeLogParams{
			UserID:         userID,
			Entity:         "stock_movement",
			EntityID:       movementID,
			Op:             "upsert",
			Payload:        []byte(`{"id":"` + movementID.String() + `"}`),
			OriginDeviceID: &deviceID,
		}); err != nil {
			return err
		}
		operation, inserted, err := queries.TryInsertSyncOperation(ctx, InsertSyncOperationParams{
			DeviceID:    deviceID,
			OpID:        opID,
			UserID:      userID,
			Status:      "applied",
			Response:    response,
			CompletedAt: &completedAt,
		})
		if err != nil {
			return err
		}
		if !inserted || operation.Status != "applied" {
			return errors.New("sync operation was not inserted")
		}
		_, inserted, err = queries.TryInsertSyncOperation(ctx, InsertSyncOperationParams{
			DeviceID: deviceID,
			OpID:     opID,
			UserID:   userID,
			Status:   "applied",
			Response: response,
		})
		if err != nil {
			return err
		}
		if inserted {
			return errors.New("duplicate sync operation was inserted")
		}
		return nil
	})
	if err != nil {
		t.Fatalf("commit transaction error = %v", err)
	}

	queries := pool.Queries()
	product, err := queries.GetProduct(ctx, userID, productID)
	if err != nil {
		t.Fatalf("GetProduct() after commit: %v", err)
	}
	if product.Name != "Integration product" || product.Version != 1 {
		t.Errorf("product after commit = (%q, version %d), want integration product/version 1", product.Name, product.Version)
	}
	movements, err := queries.ListStockMovements(ctx, userID, productID)
	if err != nil {
		t.Fatalf("ListStockMovements() after commit: %v", err)
	}
	if len(movements) != 1 || movements[0].Delta != 5 {
		t.Errorf("movements after commit = %#v, want one +5 movement", movements)
	}
	balance, err := queries.GetProductBalance(ctx, userID, productID)
	if err != nil {
		t.Fatalf("GetProductBalance() after commit: %v", err)
	}
	if balance.Qty != 5 {
		t.Errorf("balance after commit = %d, want 5", balance.Qty)
	}
	changes, err := queries.ListChangeLog(ctx, ListChangeLogParams{UserID: userID, AfterSeq: 0, MaxChanges: 10})
	if err != nil {
		t.Fatalf("ListChangeLog() after commit: %v", err)
	}
	if len(changes) != 1 || changes[0].EntityID != movementID {
		t.Errorf("changes after commit = %#v, want one movement change", changes)
	}
	operation, err := queries.GetSyncOperation(ctx, userID, deviceID, opID)
	if err != nil {
		t.Fatalf("GetSyncOperation() after commit: %v", err)
	}
	if string(operation.Response) != string(response) {
		t.Errorf("stored response = %s, want %s", operation.Response, response)
	}
}
