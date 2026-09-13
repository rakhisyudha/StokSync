package snapshot

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/stoksync/stoksync/server/internal/db"
)

// TestPostgresSnapshotIntegration is opt-in. It proves that snapshot rows and
// the cursor come from one repeatable-read PostgreSQL view, while also
// checking tombstone retention and account isolation. Set
// STOKSYNC_TEST_DATABASE_URL to a database with migrations applied.
func TestPostgresSnapshotIntegration(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL snapshot integration tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, db.PoolConfig{URL: databaseURL, MaxConns: 8, MinConns: 0})
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	fixture := createSnapshotFixture(t, ctx, pool)
	service, err := NewService(pool)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}

	got, err := service.GetSnapshot(ctx, fixture.userID)
	if err != nil {
		t.Fatalf("GetSnapshot() error = %v", err)
	}
	if len(got.Products) != 2 {
		t.Fatalf("owner products = %d, want active plus retained tombstone", len(got.Products))
	}
	if len(got.Movements) != 1 || got.Movements[0].ID != fixture.movementID {
		t.Fatalf("owner movements = %#v, want one account-scoped movement", got.Movements)
	}
	if len(got.Balances) != 2 {
		t.Fatalf("owner balances = %d, want one balance for each owner product", len(got.Balances))
	}
	var foundTombstone, foundOtherAccountRow bool
	for _, product := range got.Products {
		if product.ID == fixture.deletedProductID {
			foundTombstone = product.DeletedAt != nil
		}
		if product.ID == fixture.otherProductID {
			foundOtherAccountRow = true
		}
	}
	if !foundTombstone {
		t.Fatal("snapshot omitted the owner's retained product tombstone")
	}
	if foundOtherAccountRow {
		t.Fatal("snapshot returned a product owned by another account")
	}
	if got.Cursor != fixture.highWater {
		t.Fatalf("snapshot cursor = %d, want consistent high-water cursor %d", got.Cursor, fixture.highWater)
	}

	writerProductID := uuid.New()
	writerMovementID := uuid.New()
	started := make(chan error, 1)
	writerDone := make(chan error, 1)
	readResult := make(chan consistentSnapshotRead, 1)
	go func() {
		result, err := db.WithSnapshotResult(ctx, pool, func(q *db.Queries) (consistentSnapshotReadResult, error) {
			products, truncated, err := q.ListSnapshotProducts(ctx, fixture.userID, 100)
			if err != nil {
				started <- err
				return consistentSnapshotReadResult{}, err
			}
			if truncated {
				err := errors.New("unexpected fixture product truncation")
				started <- err
				return consistentSnapshotReadResult{}, err
			}
			cursorBefore, err := q.CurrentChangeSequence(ctx)
			if err != nil {
				started <- err
				return consistentSnapshotReadResult{}, err
			}
			started <- nil
			if err := <-writerDone; err != nil {
				return consistentSnapshotReadResult{}, err
			}
			movements, truncated, err := q.ListSnapshotMovements(ctx, fixture.userID, 100)
			if err != nil {
				return consistentSnapshotReadResult{}, err
			}
			if truncated {
				return consistentSnapshotReadResult{}, errors.New("unexpected fixture movement truncation")
			}
			cursorAfter, err := q.CurrentChangeSequence(ctx)
			if err != nil {
				return consistentSnapshotReadResult{}, err
			}
			return consistentSnapshotReadResult{
				productCount:  len(products),
				movementCount: len(movements),
				cursorBefore:  cursorBefore,
				cursorAfter:   cursorAfter,
			}, nil
		})
		readResult <- consistentSnapshotRead{result: result, err: err}
	}()

	readyErr := <-started
	if readyErr != nil {
		t.Fatalf("start repeatable-read snapshot: %v", readyErr)
	}
	writerDone <- appendConcurrentSnapshotRows(ctx, pool, fixture.userID, fixture.deviceID, writerProductID, writerMovementID)
	consistent := <-readResult
	if consistent.err != nil {
		t.Fatalf("repeatable-read snapshot error = %v", consistent.err)
	}
	if consistent.result.productCount != 2 || consistent.result.movementCount != 1 {
		t.Fatalf("repeatable-read rows = (products %d, movements %d), want pre-writer (2, 1)", consistent.result.productCount, consistent.result.movementCount)
	}
	if consistent.result.cursorBefore != fixture.highWater || consistent.result.cursorAfter != fixture.highWater {
		t.Fatalf("repeatable-read cursors = (%d, %d), want fixture high-water %d", consistent.result.cursorBefore, consistent.result.cursorAfter, fixture.highWater)
	}
	var writerRows int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM products WHERE user_id = $1 AND id = $2`, asPGUUID(fixture.userID), asPGUUID(writerProductID)).Scan(&writerRows); err != nil {
		t.Fatalf("check committed writer row: %v", err)
	}
	if writerRows != 1 {
		t.Fatalf("writer rows after snapshot = %d, want committed writer row", writerRows)
	}
}

type consistentSnapshotRead struct {
	result consistentSnapshotReadResult
	err    error
}

type consistentSnapshotReadResult struct {
	productCount  int
	movementCount int
	cursorBefore  int64
	cursorAfter   int64
}

type snapshotFixture struct {
	userID           uuid.UUID
	deviceID         uuid.UUID
	otherUserID      uuid.UUID
	otherDeviceID    uuid.UUID
	productID        uuid.UUID
	deletedProductID uuid.UUID
	otherProductID   uuid.UUID
	movementID       uuid.UUID
	highWater        int64
}

func createSnapshotFixture(t *testing.T, ctx context.Context, pool *db.Pool) snapshotFixture {
	t.Helper()
	fixture := snapshotFixture{
		userID:           uuid.New(),
		deviceID:         uuid.New(),
		otherUserID:      uuid.New(),
		otherDeviceID:    uuid.New(),
		productID:        uuid.New(),
		deletedProductID: uuid.New(),
		otherProductID:   uuid.New(),
		movementID:       uuid.New(),
	}
	occurredAt := time.Date(2026, time.November, 5, 6, 7, 8, 0, time.UTC)
	deletedAt := occurredAt.Add(time.Hour)
	if err := pool.WithTx(ctx, func(q *db.Queries) error {
		for _, account := range []struct {
			userID   uuid.UUID
			deviceID uuid.UUID
			email    string
		}{
			{fixture.userID, fixture.deviceID, "snapshot-" + fixture.userID.String() + "@example.test"},
			{fixture.otherUserID, fixture.otherDeviceID, "snapshot-" + fixture.otherUserID.String() + "@example.test"},
		} {
			if _, err := q.DB().Exec(ctx, `INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)`, asPGUUID(account.userID), account.email, "test-hash"); err != nil {
				return err
			}
			if _, err := q.DB().Exec(ctx, `INSERT INTO devices (id, user_id, name, platform) VALUES ($1, $2, $3, $4)`, asPGUUID(account.deviceID), asPGUUID(account.userID), "snapshot-device", "test"); err != nil {
				return err
			}
		}
		if _, err := q.InsertProduct(ctx, db.CreateProductParams{ID: fixture.productID, UserID: fixture.userID, Name: "Snapshot active", Unit: "pcs", UpdatedByDeviceID: fixture.deviceID}); err != nil {
			return err
		}
		if _, err := q.UpsertProductBalance(ctx, db.UpsertProductBalanceParams{UserID: fixture.userID, ProductID: fixture.productID, Qty: 0}); err != nil {
			return err
		}
		if _, err := q.InsertProduct(ctx, db.CreateProductParams{ID: fixture.deletedProductID, UserID: fixture.userID, Name: "Snapshot deleted", Unit: "pcs", UpdatedByDeviceID: fixture.deviceID}); err != nil {
			return err
		}
		if _, err := q.DB().Exec(ctx, `UPDATE products SET deleted_at = $1, version = 2, updated_at = $1 WHERE user_id = $2 AND id = $3`, deletedAt, asPGUUID(fixture.userID), asPGUUID(fixture.deletedProductID)); err != nil {
			return err
		}
		if _, err := q.InsertProduct(ctx, db.CreateProductParams{ID: fixture.otherProductID, UserID: fixture.otherUserID, Name: "Other account", Unit: "pcs", UpdatedByDeviceID: fixture.otherDeviceID}); err != nil {
			return err
		}
		if _, err := q.InsertStockMovement(ctx, db.CreateStockMovementParams{ID: fixture.movementID, UserID: fixture.userID, ProductID: fixture.productID, Delta: 5, Kind: "receive", OccurredAt: occurredAt, RawOccurredAt: occurredAt, DeviceID: fixture.deviceID}); err != nil {
			return err
		}
		if _, err := q.IncrementProductBalance(ctx, db.IncrementProductBalanceParams{UserID: fixture.userID, ProductID: fixture.productID, Delta: 5, OccurredAt: occurredAt}); err != nil {
			return err
		}
		for _, event := range []struct {
			userID   uuid.UUID
			deviceID uuid.UUID
			entityID uuid.UUID
			entity   string
		}{
			{fixture.userID, fixture.deviceID, fixture.productID, "product"},
			{fixture.userID, fixture.deviceID, fixture.deletedProductID, "product"},
			{fixture.userID, fixture.deviceID, fixture.movementID, "stock_movement"},
			{fixture.otherUserID, fixture.otherDeviceID, fixture.otherProductID, "product"},
		} {
			if _, err := q.AppendChangeLog(ctx, db.AppendChangeLogParams{UserID: event.userID, Entity: event.entity, EntityID: event.entityID, Op: "upsert", Payload: []byte(`{"id":"` + event.entityID.String() + `"}`), OriginDeviceID: &event.deviceID}); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatalf("create snapshot fixture: %v", err)
	}
	var err error
	fixture.highWater, err = pool.Queries().CurrentChangeSequence(ctx)
	if err != nil {
		t.Fatalf("read fixture cursor: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = pool.WithTx(cleanupCtx, func(q *db.Queries) error {
			for _, userID := range []uuid.UUID{fixture.userID, fixture.otherUserID} {
				if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM change_log WHERE user_id = $1`, asPGUUID(userID)); err != nil {
					return err
				}
				if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM product_balances WHERE product_id IN (SELECT id FROM products WHERE user_id = $1)`, asPGUUID(userID)); err != nil {
					return err
				}
				if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM stock_movements WHERE user_id = $1`, asPGUUID(userID)); err != nil {
					return err
				}
				if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM products WHERE user_id = $1`, asPGUUID(userID)); err != nil {
					return err
				}
				if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1`, asPGUUID(userID)); err != nil {
					return err
				}
				if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, asPGUUID(userID)); err != nil {
					return err
				}
			}
			return nil
		})
	})
	return fixture
}

func appendConcurrentSnapshotRows(ctx context.Context, pool *db.Pool, userID, deviceID, productID, movementID uuid.UUID) error {
	occurredAt := time.Date(2026, time.November, 5, 7, 7, 8, 0, time.UTC)
	return pool.WithTx(ctx, func(q *db.Queries) error {
		if _, err := q.InsertProduct(ctx, db.CreateProductParams{ID: productID, UserID: userID, Name: "Writer product", Unit: "pcs", UpdatedByDeviceID: deviceID}); err != nil {
			return err
		}
		if _, err := q.InsertStockMovement(ctx, db.CreateStockMovementParams{ID: movementID, UserID: userID, ProductID: productID, Delta: 2, Kind: "receive", OccurredAt: occurredAt, RawOccurredAt: occurredAt, DeviceID: deviceID}); err != nil {
			return err
		}
		if _, err := q.IncrementProductBalance(ctx, db.IncrementProductBalanceParams{UserID: userID, ProductID: productID, Delta: 2, OccurredAt: occurredAt}); err != nil {
			return err
		}
		_, err := q.AppendChangeLog(ctx, db.AppendChangeLogParams{UserID: userID, Entity: "stock_movement", EntityID: movementID, Op: "upsert", Payload: []byte(`{"id":"` + movementID.String() + `"}`), OriginDeviceID: &deviceID})
		return err
	})
}

func asPGUUID(value uuid.UUID) pgtype.UUID {
	return pgtype.UUID{Bytes: value, Valid: true}
}
