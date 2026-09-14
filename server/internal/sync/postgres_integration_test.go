package sync

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
	"github.com/stoksync/stoksync/server/internal/products"
)

// TestPostgresLostResponseReplaysOneCommittedMovement is opt-in. It uses the
// migrated PostgreSQL database configured by STOKSYNC_TEST_DATABASE_URL to
// prove that a retry after a lost response replays the stored outcome without
// inserting a second movement or change-log entry.
func TestPostgresLostResponseReplaysOneCommittedMovement(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL sync integration tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, db.PoolConfig{URL: databaseURL, MaxConns: 4, MinConns: 0})
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	userID := uuid.New()
	deviceID := uuid.New()
	productID := uuid.New()
	movementID := uuid.New()
	occurredAt := time.Date(2026, time.September, 13, 9, 41, 2, 0, time.UTC)
	if err := pool.WithTx(ctx, func(q *db.Queries) error {
		if _, err := q.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, dbUUID(userID), "sync-reliability-"+userID.String()+"@example.test", "test-hash"); err != nil {
			return err
		}
		_, err := q.DB().Exec(ctx, `
INSERT INTO devices (id, user_id, name, platform)
VALUES ($1, $2, $3, $4)`, dbUUID(deviceID), dbUUID(userID), "sync-reliability-device", "test")
		return err
	}); err != nil {
		t.Fatalf("insert integration account/device: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(q *db.Queries) error {
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM sync_ops WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM change_log WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM product_balances WHERE product_id IN (SELECT id FROM products WHERE user_id = $1)`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM stock_movements WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM products WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			_, err := q.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, dbUUID(userID))
			return err
		})
	})

	productService, err := products.NewService(pool)
	if err != nil {
		t.Fatalf("products.NewService() error = %v", err)
	}
	if _, err := productService.CreateProduct(ctx, products.CreateProductInput{
		ID:                productID,
		UserID:            userID,
		Name:              "Sync reliability product",
		Unit:              "pcs",
		UpdatedByDeviceID: deviceID,
	}); err != nil {
		t.Fatalf("CreateProduct() error = %v", err)
	}

	service, err := NewService(pool)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	identity := auth.Identity{UserID: userID, DeviceID: deviceID}
	operation := Operation{
		OpID: uuid.New(),
		Op:   OperationAddMovement,
		Payload: mustJSON(t, AddMovementPayload{
			ID:            movementID,
			ProductID:     productID,
			Delta:         5,
			Kind:          "receive",
			OccurredAt:    occurredAt,
			RawOccurredAt: &occurredAt,
			DeviceID:      &deviceID,
		}),
	}

	firstResult, err := service.ProcessOperation(ctx, identity, operation)
	if err != nil {
		t.Fatalf("first ProcessOperation() error = %v", err)
	}
	if firstResult.Status != ResultStatusApplied || firstResult.Seq == nil {
		t.Fatalf("first result = %#v, want applied result with a change sequence", firstResult)
	}

	// The response is intentionally ignored before sending the same operation
	// again, which models a timeout or connection loss after commit.
	retryResult, err := service.ProcessOperation(ctx, identity, operation)
	if err != nil {
		t.Fatalf("retry ProcessOperation() error = %v", err)
	}
	if !reflect.DeepEqual(retryResult, firstResult) {
		t.Fatalf("retry result = %#v, want exact original result %#v", retryResult, firstResult)
	}

	movements, err := pool.Queries().ListStockMovements(ctx, userID, productID)
	if err != nil {
		t.Fatalf("ListStockMovements() error = %v", err)
	}
	if len(movements) != 1 || movements[0].ID != movementID || movements[0].Delta != 5 {
		t.Fatalf("movements = %#v, want exactly one committed +5 movement", movements)
	}
	balance, err := pool.Queries().GetProductBalance(ctx, userID, productID)
	if err != nil {
		t.Fatalf("GetProductBalance() error = %v", err)
	}
	if balance.Qty != 5 {
		t.Fatalf("balance = %d, want 5 after one logical movement", balance.Qty)
	}
	changes, err := pool.Queries().ListChangeLog(ctx, db.ListChangeLogParams{
		UserID:     userID,
		AfterSeq:   0,
		MaxChanges: 10,
	})
	if err != nil {
		t.Fatalf("ListChangeLog() error = %v", err)
	}
	if len(changes) != 1 || changes[0].EntityID != movementID {
		t.Fatalf("change log = %#v, want exactly one movement change", changes)
	}
	stored, err := pool.Queries().GetSyncOperation(ctx, userID, deviceID, operation.OpID)
	if err != nil {
		t.Fatalf("GetSyncOperation() error = %v", err)
	}
	var storedResult OperationResult
	if err := json.Unmarshal(stored.Response, &storedResult); err != nil {
		t.Fatalf("decode stored response: %v", err)
	}
	if !reflect.DeepEqual(storedResult, firstResult) {
		t.Fatalf("stored response result = %#v, want original result %#v", storedResult, firstResult)
	}
}

// dbUUID keeps the integration fixture independent from generated query
// parameter helpers while using the same pgx UUID representation as the rest
// of the database tests.
func dbUUID(value uuid.UUID) pgtype.UUID {
	return pgtype.UUID{Bytes: value, Valid: true}
}

// TestPostgresVersionConflictReturnsCanonicalProductState is opt-in. It uses
// two devices in one account to prove that a stale product edit is rejected by
// the canonical version predicate, includes the current product state, and
// replays that structured outcome through the idempotency record.
func TestPostgresVersionConflictReturnsCanonicalProductState(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL sync integration tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, db.PoolConfig{URL: databaseURL, MaxConns: 4, MinConns: 0})
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	userID := uuid.New()
	firstDeviceID := uuid.New()
	secondDeviceID := uuid.New()
	productID := uuid.New()
	if err := pool.WithTx(ctx, func(q *db.Queries) error {
		if _, err := q.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, dbUUID(userID), "sync-version-"+userID.String()+"@example.test", "test-hash"); err != nil {
			return err
		}
		_, err := q.DB().Exec(ctx, `
INSERT INTO devices (id, user_id, name, platform)
VALUES ($1, $2, $3, $4), ($5, $2, $6, $4)`,
			dbUUID(firstDeviceID), dbUUID(userID), "version-device-a", "test",
			dbUUID(secondDeviceID), "version-device-b")
		return err
	}); err != nil {
		t.Fatalf("insert integration account/devices: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(q *db.Queries) error {
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM sync_ops WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM change_log WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM product_balances WHERE product_id IN (SELECT id FROM products WHERE user_id = $1)`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM products WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			_, err := q.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, dbUUID(userID))
			return err
		})
	})

	productService, err := products.NewService(pool)
	if err != nil {
		t.Fatalf("products.NewService() error = %v", err)
	}
	product, err := productService.CreateProduct(ctx, products.CreateProductInput{
		ID:                productID,
		UserID:            userID,
		Name:              "Original product",
		Unit:              "pcs",
		UpdatedByDeviceID: firstDeviceID,
	})
	if err != nil {
		t.Fatalf("CreateProduct() error = %v", err)
	}

	service, err := NewService(pool)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	firstOperation := Operation{
		OpID: uuid.New(), Op: OperationUpsertProduct, BaseVersion: int64Pointer(product.Version),
		Payload: mustJSON(t, UpsertProductPayload{ID: productID, Name: "Device A product", Unit: "pcs"}),
	}
	firstResult, err := service.ProcessOperation(ctx, auth.Identity{UserID: userID, DeviceID: firstDeviceID}, firstOperation)
	if err != nil {
		t.Fatalf("first product update: %v", err)
	}
	if firstResult.Status != ResultStatusApplied || firstResult.Seq == nil {
		t.Fatalf("first result = %#v, want applied result with sequence", firstResult)
	}

	staleOperation := Operation{
		OpID: uuid.New(), Op: OperationUpsertProduct, BaseVersion: int64Pointer(product.Version),
		Payload: mustJSON(t, UpsertProductPayload{ID: productID, Name: "Device B stale product", Unit: "pcs"}),
	}
	identityB := auth.Identity{UserID: userID, DeviceID: secondDeviceID}
	staleResult, err := service.ProcessOperation(ctx, identityB, staleOperation)
	if err != nil {
		t.Fatalf("stale product update: %v", err)
	}
	assertVersionConflictState(t, staleResult, staleOperation.OpID, productID, product.Version+1)

	retryResult, err := service.ProcessOperation(ctx, identityB, staleOperation)
	if err != nil {
		t.Fatalf("stale product retry: %v", err)
	}
	assertReplayedResultMatches(t, retryResult, staleResult)

	canonical, err := pool.Queries().GetProduct(ctx, userID, productID)
	if err != nil {
		t.Fatalf("GetProduct() error = %v", err)
	}
	if canonical.Name != "Device A product" || canonical.Version != product.Version+1 {
		t.Fatalf("canonical product = %#v, want device A version %d", canonical, product.Version+1)
	}
}

// TestPostgresDeleteWinsAgainstAnAlreadyAcceptedEdit is opt-in. It applies an
// edit first, then submits a delete based on the older version from another
// device. The delete must still commit the tombstone, and a later edit must
// receive the structured canonical deleted state.
func TestPostgresDeleteWinsAgainstAnAlreadyAcceptedEdit(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL sync integration tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, db.PoolConfig{URL: databaseURL, MaxConns: 4, MinConns: 0})
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	userID := uuid.New()
	editDeviceID := uuid.New()
	deleteDeviceID := uuid.New()
	productID := uuid.New()
	if err := pool.WithTx(ctx, func(q *db.Queries) error {
		if _, err := q.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, dbUUID(userID), "sync-delete-wins-"+userID.String()+"@example.test", "test-hash"); err != nil {
			return err
		}
		_, err := q.DB().Exec(ctx, `
INSERT INTO devices (id, user_id, name, platform)
VALUES ($1, $2, $3, $4), ($5, $2, $6, $4)`,
			dbUUID(editDeviceID), dbUUID(userID), "delete-wins-edit-device", "test",
			dbUUID(deleteDeviceID), "delete-wins-delete-device")
		return err
	}); err != nil {
		t.Fatalf("insert integration account/devices: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(q *db.Queries) error {
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM sync_ops WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM change_log WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM product_balances WHERE product_id IN (SELECT id FROM products WHERE user_id = $1)`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM products WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			_, err := q.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, dbUUID(userID))
			return err
		})
	})

	productService, err := products.NewService(pool)
	if err != nil {
		t.Fatalf("products.NewService() error = %v", err)
	}
	product, err := productService.CreateProduct(ctx, products.CreateProductInput{
		ID: productID, UserID: userID, Name: "Original product", Unit: "pcs", UpdatedByDeviceID: editDeviceID,
	})
	if err != nil {
		t.Fatalf("CreateProduct() error = %v", err)
	}

	service, err := NewService(pool)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	editOperation := Operation{
		OpID: uuid.New(), Op: OperationUpsertProduct, BaseVersion: int64Pointer(product.Version),
		Payload: mustJSON(t, UpsertProductPayload{ID: productID, Name: "Edit before deletion", Unit: "pcs"}),
	}
	editResult, err := service.ProcessOperation(ctx, auth.Identity{UserID: userID, DeviceID: editDeviceID}, editOperation)
	if err != nil || editResult.Status != ResultStatusApplied {
		t.Fatalf("edit result = %#v, error = %v; want applied edit", editResult, err)
	}

	deleteOperation := Operation{
		OpID: uuid.New(), Op: OperationDeleteProduct, BaseVersion: int64Pointer(product.Version),
		Payload: mustJSON(t, DeleteProductPayload{ID: productID}),
	}
	deleteResult, err := service.ProcessOperation(ctx, auth.Identity{UserID: userID, DeviceID: deleteDeviceID}, deleteOperation)
	if err != nil || deleteResult.Status != ResultStatusApplied {
		t.Fatalf("delete result = %#v, error = %v; want applied delete-wins tombstone", deleteResult, err)
	}

	staleEdit := Operation{
		OpID: uuid.New(), Op: OperationUpsertProduct, BaseVersion: int64Pointer(product.Version + 1),
		Payload: mustJSON(t, UpsertProductPayload{ID: productID, Name: "Resurrection attempt", Unit: "pcs"}),
	}
	staleResult, err := service.ProcessOperation(ctx, auth.Identity{UserID: userID, DeviceID: editDeviceID}, staleEdit)
	if err != nil {
		t.Fatalf("stale edit after tombstone: %v", err)
	}
	if staleResult.Status != ResultStatusRejected || staleResult.Reason != ReasonProductDeleted {
		t.Fatalf("stale edit result = %#v, want product-deleted rejection", staleResult)
	}
	var state map[string]any
	if err := json.Unmarshal(staleResult.ServerState, &state); err != nil {
		t.Fatalf("decode stale edit canonical state: %v", err)
	}
	if state["id"] != productID.String() || state["name"] != "Edit before deletion" || state["deleted_at"] == nil {
		t.Fatalf("stale edit server state = %#v, want deleted edited product", state)
	}

	canonical, err := pool.Queries().GetProduct(ctx, userID, productID)
	if err != nil {
		t.Fatalf("GetProduct() error = %v", err)
	}
	if canonical.Name != "Edit before deletion" || canonical.Version != product.Version+2 || canonical.DeletedAt == nil {
		t.Fatalf("canonical product = %#v, want deleted version %d retaining edit", canonical, product.Version+2)
	}
	changes, err := pool.Queries().ListChangeLog(ctx, db.ListChangeLogParams{UserID: userID, AfterSeq: 0, MaxChanges: 10})
	if err != nil {
		t.Fatalf("ListChangeLog() error = %v", err)
	}
	if len(changes) != 2 {
		t.Fatalf("change log = %#v, want edit plus tombstone only", changes)
	}
}

// TestPostgresDuplicateBarcodeConflictReturnsCanonicalOwner is opt-in. It
// uses the migrated partial unique index to prove that a concurrent/offline
// product create becomes a structured, durable conflict rather than a generic
// transaction failure or a duplicate active barcode.
func TestPostgresDuplicateBarcodeConflictReturnsCanonicalOwner(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL sync integration tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, db.PoolConfig{URL: databaseURL, MaxConns: 4, MinConns: 0})
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	userID := uuid.New()
	ownerDeviceID := uuid.New()
	contenderDeviceID := uuid.New()
	ownerProductID := uuid.New()
	contenderProductID := uuid.New()
	if err := pool.WithTx(ctx, func(q *db.Queries) error {
		if _, err := q.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, dbUUID(userID), "sync-barcode-"+userID.String()+"@example.test", "test-hash"); err != nil {
			return err
		}
		_, err := q.DB().Exec(ctx, `
INSERT INTO devices (id, user_id, name, platform)
VALUES ($1, $2, $3, $4), ($5, $2, $6, $4)`,
			dbUUID(ownerDeviceID), dbUUID(userID), "barcode-device-owner", "test",
			dbUUID(contenderDeviceID), "barcode-device-contender")
		return err
	}); err != nil {
		t.Fatalf("insert integration account/devices: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(q *db.Queries) error {
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM sync_ops WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM change_log WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM product_balances WHERE product_id IN (SELECT id FROM products WHERE user_id = $1)`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM stock_movements WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM products WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1`, dbUUID(userID)); err != nil {
				return err
			}
			_, err := q.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, dbUUID(userID))
			return err
		})
	})

	barcode := "offline-shared-barcode"
	productService, err := products.NewService(pool)
	if err != nil {
		t.Fatalf("products.NewService() error = %v", err)
	}
	owner, err := productService.CreateProduct(ctx, products.CreateProductInput{
		ID:                ownerProductID,
		UserID:            userID,
		Barcode:           &barcode,
		Name:              "Canonical owner",
		Unit:              "pcs",
		UpdatedByDeviceID: ownerDeviceID,
	})
	if err != nil {
		t.Fatalf("CreateProduct() error = %v", err)
	}

	service, err := NewService(pool)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	operation := Operation{
		OpID: uuid.New(), Op: OperationUpsertProduct,
		Payload: mustJSON(t, UpsertProductPayload{
			ID: contenderProductID, Barcode: &barcode, Name: "Offline contender", Unit: "pcs",
		}),
	}
	identity := auth.Identity{UserID: userID, DeviceID: contenderDeviceID}
	result, err := service.ProcessOperation(ctx, identity, operation)
	if err != nil {
		t.Fatalf("duplicate barcode ProcessOperation() error = %v", err)
	}
	assertBarcodeConflictState(t, result, operation.OpID, owner.ID, barcode)

	retryResult, err := service.ProcessOperation(ctx, identity, operation)
	if err != nil {
		t.Fatalf("duplicate barcode retry: %v", err)
	}
	assertReplayedResultMatches(t, retryResult, result)

	if _, err := pool.Queries().GetProduct(ctx, userID, contenderProductID); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("contender product lookup error = %v, want no duplicate product", err)
	}
	changes, err := pool.Queries().ListChangeLog(ctx, db.ListChangeLogParams{
		UserID: userID, AfterSeq: 0, MaxChanges: 10,
	})
	if err != nil {
		t.Fatalf("ListChangeLog() error = %v", err)
	}
	if len(changes) != 0 {
		t.Fatalf("change log = %#v, want no change for rejected barcode conflict", changes)
	}
	stored, err := pool.Queries().GetSyncOperation(ctx, userID, contenderDeviceID, operation.OpID)
	if err != nil {
		t.Fatalf("GetSyncOperation() error = %v", err)
	}
	var storedResult OperationResult
	if err := json.Unmarshal(stored.Response, &storedResult); err != nil {
		t.Fatalf("decode stored barcode conflict: %v", err)
	}
	assertBarcodeConflictState(t, storedResult, operation.OpID, owner.ID, barcode)
}

func assertBarcodeConflictState(t *testing.T, result OperationResult, operationID, ownerID uuid.UUID, barcode string) {
	t.Helper()
	if result.OpID != operationID || result.Status != ResultStatusRejected || result.Reason != ReasonBarcodeConflict {
		t.Fatalf("result = %#v, want barcode conflict for %s", result, operationID)
	}
	var state map[string]any
	if err := json.Unmarshal(result.ServerState, &state); err != nil {
		t.Fatalf("decode barcode conflict server state: %v", err)
	}
	if state["id"] != ownerID.String() || state["barcode"] != barcode {
		t.Fatalf("server state = %#v, want owner %s with barcode %q", state, ownerID, barcode)
	}
}

// assertReplayedResultMatches compares a duplicate-delivery replay against the
// original outcome. sync_ops.response is JSONB, so PostgreSQL normalizes object
// key order and whitespace when the reserved outcome is stored. server_state is
// therefore compared as decoded JSON while every scalar field must still match
// the original result exactly.
func assertReplayedResultMatches(t *testing.T, got, want OperationResult) {
	t.Helper()
	if got.OpID != want.OpID || got.Status != want.Status || got.Reason != want.Reason {
		t.Fatalf("replayed result = %#v, want original outcome %#v", got, want)
	}
	if (got.Seq == nil) != (want.Seq == nil) || (got.Seq != nil && *got.Seq != *want.Seq) {
		t.Fatalf("replayed sequence = %v, want %v", got.Seq, want.Seq)
	}
	if (len(got.ServerState) == 0) != (len(want.ServerState) == 0) {
		t.Fatalf("replayed server state = %s, want %s", got.ServerState, want.ServerState)
	}
	if len(want.ServerState) == 0 {
		return
	}
	var gotState, wantState any
	if err := json.Unmarshal(got.ServerState, &gotState); err != nil {
		t.Fatalf("decode replayed server state %s: %v", got.ServerState, err)
	}
	if err := json.Unmarshal(want.ServerState, &wantState); err != nil {
		t.Fatalf("decode original server state %s: %v", want.ServerState, err)
	}
	if !reflect.DeepEqual(gotState, wantState) {
		t.Fatalf("replayed server state = %s, want equivalent to %s", got.ServerState, want.ServerState)
	}
}
