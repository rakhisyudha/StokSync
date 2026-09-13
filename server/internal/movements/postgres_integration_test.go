package movements

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/stoksync/stoksync/server/internal/db"
	"github.com/stoksync/stoksync/server/internal/products"
)

// TestPostgresCanonicalDomainTransactions is opt-in. It exercises the real
// product/movement service transactions, immutable history, projection repair,
// and rollback behavior when STOKSYNC_TEST_DATABASE_URL points at a migrated
// PostgreSQL database.
func TestPostgresCanonicalDomainTransactions(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL domain integration tests")
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
	rollbackMovementID := uuid.New()
	occurredAt := time.Date(2026, time.June, 7, 8, 9, 10, 0, time.UTC)
	barcode := "domain-integration-" + uuid.New().String()

	if err := pool.WithTx(ctx, func(q *db.Queries) error {
		if _, err := q.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, asPGUUID(userID), "domain-"+uuid.New().String()+"@example.test", "test-hash"); err != nil {
			return err
		}
		_, err := q.DB().Exec(ctx, `
INSERT INTO devices (id, user_id, name, platform)
VALUES ($1, $2, $3, $4)`, asPGUUID(deviceID), asPGUUID(userID), "domain-test-device", "test")
		return err
	}); err != nil {
		t.Fatalf("insert integration account/device: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(q *db.Queries) error {
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
			_, err := q.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, asPGUUID(userID))
			return err
		})
	})

	productService, err := products.NewService(pool)
	if err != nil {
		t.Fatalf("products.NewService() error = %v", err)
	}
	movementService, err := NewService(pool)
	if err != nil {
		t.Fatalf("movements.NewService() error = %v", err)
	}
	product, err := productService.CreateProduct(ctx, products.CreateProductInput{
		ID:                productID,
		UserID:            userID,
		Barcode:           &barcode,
		Name:              "Canonical integration product",
		UpdatedByDeviceID: deviceID,
	})
	if err != nil {
		t.Fatalf("CreateProduct() error = %v", err)
	}
	if product.Version != 1 {
		t.Fatalf("created product version = %d, want 1", product.Version)
	}
	balance, err := pool.Queries().GetProductBalance(ctx, userID, productID)
	if err != nil {
		t.Fatalf("zero balance after product creation: %v", err)
	}
	if balance.Qty != 0 {
		t.Fatalf("zero balance after product creation = %d, want 0", balance.Qty)
	}

	firstMovementID := uuid.New()
	firstMovement, err := movementService.AppendMovement(ctx, AppendInput{
		ID:            firstMovementID,
		UserID:        userID,
		ProductID:     productID,
		DeviceID:      deviceID,
		Delta:         10,
		Kind:          "receive",
		OccurredAt:    occurredAt,
		RawOccurredAt: occurredAt,
	})
	if err != nil {
		t.Fatalf("append receive movement: %v", err)
	}
	secondMovement, err := movementService.AppendMovement(ctx, AppendInput{
		ID:            uuid.New(),
		UserID:        userID,
		ProductID:     productID,
		DeviceID:      deviceID,
		Delta:         -3,
		Kind:          "issue",
		OccurredAt:    occurredAt.Add(time.Minute),
		RawOccurredAt: occurredAt.Add(time.Minute),
	})
	if err != nil {
		t.Fatalf("append issue movement: %v", err)
	}
	balance, err = pool.Queries().GetProductBalance(ctx, userID, productID)
	if err != nil {
		t.Fatalf("balance after movements: %v", err)
	}
	if balance.Qty != 7 {
		t.Fatalf("balance after +10/-3 = %d, want 7", balance.Qty)
	}

	reversal, err := movementService.ReverseMovement(ctx, ReverseInput{
		ID:            uuid.New(),
		UserID:        userID,
		DeviceID:      deviceID,
		MovementID:    firstMovement.ID,
		OccurredAt:    occurredAt.Add(2 * time.Minute),
		RawOccurredAt: occurredAt.Add(2 * time.Minute),
		Note:          stringPointer("correct receive"),
	})
	if err != nil {
		t.Fatalf("reverse movement: %v", err)
	}
	if reversal.Delta != -10 || reversal.ReversesID == nil || *reversal.ReversesID != firstMovement.ID {
		t.Fatalf("reversal = %#v, want -10 linked to %s", reversal, firstMovement.ID)
	}

	stocktake, err := movementService.RecordStocktake(ctx, StocktakeInput{
		ID:            uuid.New(),
		UserID:        userID,
		ProductID:     productID,
		DeviceID:      deviceID,
		CountedQty:    5,
		OccurredAt:    occurredAt.Add(3 * time.Minute),
		RawOccurredAt: occurredAt.Add(3 * time.Minute),
	})
	if err != nil {
		t.Fatalf("record stocktake: %v", err)
	}
	if stocktake.Kind != "stocktake" || stocktake.CountedQty == nil || *stocktake.CountedQty != 5 || stocktake.Delta != 8 {
		t.Fatalf("stocktake = %#v, want counted 5 and canonical delta +8", stocktake)
	}
	balance, err = pool.Queries().GetProductBalance(ctx, userID, productID)
	if err != nil {
		t.Fatalf("balance after stocktake: %v", err)
	}
	if balance.Qty != 5 {
		t.Fatalf("balance after stocktake = %d, want 5", balance.Qty)
	}

	movements, err := pool.Queries().ListStockMovements(ctx, userID, productID)
	if err != nil {
		t.Fatalf("ListStockMovements() error = %v", err)
	}
	if len(movements) != 4 {
		t.Fatalf("movement count = %d, want 4 immutable rows", len(movements))
	}
	if movements[0].ID != firstMovement.ID || movements[0].Delta != 10 || movements[1].ID != secondMovement.ID {
		t.Fatalf("movement history = %#v, original history was changed", movements)
	}

	report, err := movementService.VerifyProductBalances(ctx, userID)
	if err != nil {
		t.Fatalf("VerifyProductBalances() before corruption: %v", err)
	}
	if !report.Consistent {
		t.Fatalf("projection report before corruption = %#v, want consistent", report)
	}

	if _, err := pool.Exec(ctx, `UPDATE product_balances SET qty = qty + 100 WHERE product_id = $1`, asPGUUID(productID)); err != nil {
		t.Fatalf("corrupt projection fixture: %v", err)
	}
	report, err = movementService.VerifyProductBalances(ctx, userID)
	if err != nil {
		t.Fatalf("VerifyProductBalances() after corruption: %v", err)
	}
	if report.Consistent || len(report.Mismatches) != 1 || report.Mismatches[0].Kind != MismatchQuantity {
		t.Fatalf("corrupted projection report = %#v, want one quantity mismatch", report)
	}
	if err := movementService.RebuildProductBalances(ctx, userID); err != nil {
		t.Fatalf("RebuildProductBalances() error = %v", err)
	}
	report, err = movementService.VerifyProductBalances(ctx, userID)
	if err != nil {
		t.Fatalf("VerifyProductBalances() after rebuild: %v", err)
	}
	if !report.Consistent {
		t.Fatalf("projection report after rebuild = %#v, want consistent", report)
	}
	movementsAfterRebuild, err := pool.Queries().ListStockMovements(ctx, userID, productID)
	if err != nil {
		t.Fatalf("ListStockMovements() after rebuild: %v", err)
	}
	if len(movementsAfterRebuild) != len(movements) {
		t.Fatalf("movement count after rebuild = %d, want %d; rebuild must not mutate ledger", len(movementsAfterRebuild), len(movements))
	}

	rollbackErr := errors.New("intentional domain transaction rollback")
	err = pool.WithTx(ctx, func(q *db.Queries) error {
		if _, err := q.InsertStockMovement(ctx, db.CreateStockMovementParams{
			ID:            rollbackMovementID,
			UserID:        userID,
			ProductID:     productID,
			Delta:         2,
			Kind:          "adjust",
			OccurredAt:    occurredAt.Add(4 * time.Minute),
			RawOccurredAt: occurredAt.Add(4 * time.Minute),
			DeviceID:      deviceID,
		}); err != nil {
			return err
		}
		if _, err := q.IncrementProductBalance(ctx, db.IncrementProductBalanceParams{
			UserID: userID, ProductID: productID, Delta: 2, OccurredAt: occurredAt.Add(4 * time.Minute),
		}); err != nil {
			return err
		}
		return rollbackErr
	})
	if !errors.Is(err, rollbackErr) {
		t.Fatalf("forced rollback error = %v, want callback error", err)
	}
	if _, err := pool.Queries().GetStockMovement(ctx, userID, rollbackMovementID); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("rolled-back movement lookup error = %v, want pgx.ErrNoRows", err)
	}
	balance, err = pool.Queries().GetProductBalance(ctx, userID, productID)
	if err != nil {
		t.Fatalf("balance after rollback: %v", err)
	}
	if balance.Qty != 5 {
		t.Fatalf("balance after rollback = %d, want 5", balance.Qty)
	}

	updated, err := productService.UpdateProduct(ctx, products.UpdateProductInput{
		ID:                productID,
		UserID:            userID,
		Name:              "Updated canonical product",
		Unit:              "pcs",
		BaseVersion:       product.Version,
		UpdatedByDeviceID: deviceID,
	})
	if err != nil {
		t.Fatalf("UpdateProduct() error = %v", err)
	}
	if updated.Version != 2 {
		t.Fatalf("updated product version = %d, want 2", updated.Version)
	}
	if _, err := productService.UpdateProduct(ctx, products.UpdateProductInput{
		ID:                productID,
		UserID:            userID,
		Name:              "Stale edit",
		Unit:              "pcs",
		BaseVersion:       product.Version,
		UpdatedByDeviceID: deviceID,
	}); !errors.Is(err, products.ErrVersionConflict) {
		t.Fatalf("stale UpdateProduct() error = %v, want ErrVersionConflict", err)
	}
	if _, err := productService.SoftDeleteProduct(ctx, products.SoftDeleteProductInput{
		ID:                productID,
		UserID:            userID,
		BaseVersion:       updated.Version,
		UpdatedByDeviceID: deviceID,
	}); err != nil {
		t.Fatalf("SoftDeleteProduct() error = %v", err)
	}
	if _, err := movementService.AppendMovement(ctx, AppendInput{
		ID: uuid.New(), UserID: userID, ProductID: productID, DeviceID: deviceID,
		Delta: 1, Kind: "receive", OccurredAt: occurredAt.Add(5 * time.Minute),
	}); !errors.Is(err, ErrProductDeleted) {
		t.Fatalf("append to deleted product error = %v, want ErrProductDeleted", err)
	}
}

func asPGUUID(value uuid.UUID) pgtype.UUID {
	return pgtype.UUID{Bytes: value, Valid: true}
}

func stringPointer(value string) *string {
	return &value
}
