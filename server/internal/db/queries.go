package db

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// The SQL below is intentionally kept beside its typed methods. This is the
// repository's documented sqlc-equivalent: every statement is static and
// parameterized, and every result is mapped by a typed scan function. Keeping
// the query constants in source control makes ownership predicates and
// transaction-sensitive statements reviewable without a code generator.
const (
	insertProductSQL = `
INSERT INTO products (
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    updated_by_device_id
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
RETURNING
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at`

	getProductSQL = `
SELECT
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at
FROM products
WHERE user_id = $1 AND id = $2`

	getProductByIDSQL = `
SELECT
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at
FROM products
WHERE id = $1`

	getProductForUpdateSQL = `
SELECT
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at
FROM products
WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
FOR UPDATE`

	listProductsSQL = `
SELECT
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at
FROM products
WHERE user_id = $1 AND ($2::boolean OR deleted_at IS NULL)
ORDER BY updated_at DESC, id`

	listSnapshotProductsSQL = `
SELECT
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at
FROM products
WHERE user_id = $1
ORDER BY id
LIMIT $2`

	updateProductSQL = `
UPDATE products
SET barcode = $3,
    sku = $4,
    name = $5,
    description = $6,
    unit = $7,
    category = $8,
    min_stock = $9,
    version = version + 1,
    updated_at = CURRENT_TIMESTAMP,
    updated_by_device_id = $10
WHERE user_id = $1 AND id = $2 AND version = $11 AND deleted_at IS NULL
RETURNING
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at`

	softDeleteProductSQL = `
UPDATE products
SET deleted_at = CURRENT_TIMESTAMP,
    version = version + 1,
    updated_at = CURRENT_TIMESTAMP,
    updated_by_device_id = $4
WHERE user_id = $1 AND id = $2 AND version = $3 AND deleted_at IS NULL
RETURNING
    id, user_id, barcode, sku, name, description, unit, category, min_stock,
    version, updated_at, updated_by_device_id, deleted_at, created_at`

	insertStockMovementSQL = `
INSERT INTO stock_movements (
    id, user_id, product_id, delta, kind, note, occurred_at, raw_occurred_at,
    clock_offset_ms, counted_qty, reverses_id, device_id
)
SELECT
    $1, p.user_id, p.id, $4, $5, $6, $7, $8, $9, $10, $11, $12
FROM products AS p
WHERE p.user_id = $2 AND p.id = $3 AND p.deleted_at IS NULL
RETURNING
    id, user_id, product_id, delta, kind, note, occurred_at, raw_occurred_at,
    clock_offset_ms, counted_qty, reverses_id, device_id, server_created_at`

	getStockMovementSQL = `
SELECT
    id, user_id, product_id, delta, kind, note, occurred_at, raw_occurred_at,
    clock_offset_ms, counted_qty, reverses_id, device_id, server_created_at
FROM stock_movements
WHERE user_id = $1 AND id = $2`

	getStockMovementByIDSQL = `
SELECT
    id, user_id, product_id, delta, kind, note, occurred_at, raw_occurred_at,
    clock_offset_ms, counted_qty, reverses_id, device_id, server_created_at
FROM stock_movements
WHERE id = $1`

	getProductLedgerBalanceSQL = `
SELECT COALESCE(SUM(delta), 0)::bigint, MAX(occurred_at)
FROM stock_movements
WHERE user_id = $1 AND product_id = $2`

	listLedgerBalancesSQL = `
SELECT p.id, COALESCE(SUM(sm.delta), 0)::bigint, MAX(sm.occurred_at)
FROM products AS p
LEFT JOIN stock_movements AS sm
    ON sm.user_id = p.user_id AND sm.product_id = p.id
WHERE p.user_id = $1
GROUP BY p.id
ORDER BY p.id`

	listProductBalancesSQL = `
SELECT pb.product_id, pb.qty, pb.last_movement_at, pb.updated_at
FROM product_balances AS pb
JOIN products AS p ON p.id = pb.product_id AND p.user_id = $1
ORDER BY pb.product_id`

	rebuildProductBalancesSQL = `
INSERT INTO product_balances (product_id, qty, last_movement_at)
SELECT p.id, COALESCE(SUM(sm.delta), 0)::bigint, MAX(sm.occurred_at)
FROM products AS p
LEFT JOIN stock_movements AS sm
    ON sm.user_id = p.user_id AND sm.product_id = p.id
WHERE p.user_id = $1
GROUP BY p.id
ON CONFLICT (product_id) DO UPDATE
SET qty = EXCLUDED.qty,
    last_movement_at = EXCLUDED.last_movement_at,
    updated_at = CURRENT_TIMESTAMP`

	listStockMovementsSQL = `
SELECT
    id, user_id, product_id, delta, kind, note, occurred_at, raw_occurred_at,
    clock_offset_ms, counted_qty, reverses_id, device_id, server_created_at
FROM stock_movements
WHERE user_id = $1 AND product_id = $2
ORDER BY occurred_at ASC, id`

	listSnapshotMovementsSQL = `
SELECT
    id, user_id, product_id, delta, kind, note, occurred_at, raw_occurred_at,
    clock_offset_ms, counted_qty, reverses_id, device_id, server_created_at
FROM stock_movements
WHERE user_id = $1
ORDER BY product_id, occurred_at ASC, id
LIMIT $2`

	listSnapshotBalancesSQL = `
SELECT p.id, COALESCE(SUM(sm.delta), 0)::bigint, MAX(sm.occurred_at)
FROM products AS p
LEFT JOIN stock_movements AS sm
    ON sm.user_id = p.user_id AND sm.product_id = p.id
WHERE p.user_id = $1
GROUP BY p.id
ORDER BY p.id
LIMIT $2`

	currentDatabaseTimeSQL = `
SELECT CURRENT_TIMESTAMP`

	incrementProductBalanceSQL = `
INSERT INTO product_balances (product_id, qty, last_movement_at)
SELECT p.id, $3, $4
FROM products AS p
WHERE p.user_id = $1 AND p.id = $2
ON CONFLICT (product_id) DO UPDATE
SET qty = product_balances.qty + EXCLUDED.qty,
    last_movement_at = CASE
        WHEN product_balances.last_movement_at IS NULL
          OR EXCLUDED.last_movement_at > product_balances.last_movement_at
        THEN EXCLUDED.last_movement_at
        ELSE product_balances.last_movement_at
    END,
    updated_at = CURRENT_TIMESTAMP
RETURNING product_id, qty, last_movement_at, updated_at`

	upsertProductBalanceSQL = `
INSERT INTO product_balances (product_id, qty, last_movement_at)
SELECT p.id, $3, $4
FROM products AS p
WHERE p.user_id = $1 AND p.id = $2
ON CONFLICT (product_id) DO UPDATE
SET qty = EXCLUDED.qty,
    last_movement_at = EXCLUDED.last_movement_at,
    updated_at = CURRENT_TIMESTAMP
RETURNING product_id, qty, last_movement_at, updated_at`

	getProductBalanceSQL = `
SELECT pb.product_id, pb.qty, pb.last_movement_at, pb.updated_at
FROM product_balances AS pb
JOIN products AS p ON p.id = pb.product_id AND p.user_id = $1
WHERE pb.product_id = $2`

	allocateChangeSequenceSQL = `
UPDATE sync_seq_counter
SET last_seq = last_seq + 1
WHERE id = 1
RETURNING last_seq`

	currentChangeSequenceSQL = `
SELECT last_seq
FROM sync_seq_counter
WHERE id = 1`

	insertChangeLogSQL = `
INSERT INTO change_log (
    seq, user_id, entity, entity_id, op, payload, origin_device_id
)
SELECT $1, $2, $3, $4, $5, $6, $7
WHERE $7::uuid IS NULL
   OR EXISTS (
       SELECT 1 FROM devices
       WHERE id = $7 AND user_id = $2
   )
RETURNING seq, user_id, entity, entity_id, op, payload, origin_device_id, created_at`

	listChangeLogSQL = `
SELECT seq, user_id, entity, entity_id, op, payload, origin_device_id, created_at
FROM change_log
WHERE user_id = $1 AND seq > $2
ORDER BY seq ASC
LIMIT $3`

	getSyncOperationSQL = `
SELECT device_id, op_id, user_id, status, reason, response, received_at, completed_at
FROM sync_ops
WHERE user_id = $1 AND device_id = $2 AND op_id = $3`

	tryInsertSyncOperationSQL = `
INSERT INTO sync_ops (
    device_id, op_id, user_id, status, reason, response, received_at, completed_at
)
SELECT $2, $3, $1, $4, $5, $6, CURRENT_TIMESTAMP, $7
FROM devices
WHERE id = $2 AND user_id = $1
ON CONFLICT (device_id, op_id) DO NOTHING
RETURNING device_id, op_id, user_id, status, reason, response, received_at, completed_at`

	updateSyncOperationSQL = `
UPDATE sync_ops
SET status = $4,
    reason = $5,
    response = $6,
    completed_at = $7
WHERE user_id = $1 AND device_id = $2 AND op_id = $3
RETURNING device_id, op_id, user_id, status, reason, response, received_at, completed_at`
)

// Queries is the typed query/data-access object. It can be bound to a pool for
// reads or to a transaction returned by WithTx for atomic mutations.
type Queries struct {
	db DBTX
}

// NewQueries binds the centralized SQL statements to a pool or transaction.
func NewQueries(db DBTX) *Queries {
	return &Queries{db: db}
}

// DB exposes the underlying narrow executor for composition by future service
// packages without exposing a concrete pool dependency.
func (q *Queries) DB() DBTX {
	if q == nil {
		return nil
	}
	return q.db
}

// InsertProduct inserts a canonical product and returns server-managed fields.
func (q *Queries) InsertProduct(ctx context.Context, params CreateProductParams) (Product, error) {
	return scanProduct(q.db.QueryRow(ctx, insertProductSQL,
		uuidArg(params.ID),
		uuidArg(params.UserID),
		optionalStringArg(params.Barcode),
		optionalStringArg(params.SKU),
		params.Name,
		optionalStringArg(params.Description),
		params.Unit,
		optionalStringArg(params.Category),
		optionalInt32Arg(params.MinStock),
		uuidArg(params.UpdatedByDeviceID),
	))
}

// GetProduct returns a product only when it belongs to userID.
func (q *Queries) GetProduct(ctx context.Context, userID, productID uuid.UUID) (Product, error) {
	return scanProduct(q.db.QueryRow(ctx, getProductSQL, uuidArg(userID), uuidArg(productID)))
}

// GetProductByID returns a product without applying a user predicate. Services
// use it only to classify an attempted mutation as missing versus cross-owner;
// callers must not expose this lookup as a general account-scoped read.
func (q *Queries) GetProductByID(ctx context.Context, productID uuid.UUID) (Product, error) {
	return scanProduct(q.db.QueryRow(ctx, getProductByIDSQL, uuidArg(productID)))
}

// GetProductForUpdate returns an active product in the user's account while
// taking a row lock. Movement and stocktake transactions use this lock to
// serialize canonical ledger calculations with other service mutations.
func (q *Queries) GetProductForUpdate(ctx context.Context, userID, productID uuid.UUID) (Product, error) {
	return scanProduct(q.db.QueryRow(ctx, getProductForUpdateSQL, uuidArg(userID), uuidArg(productID)))
}

// ListProducts returns all products for a user when includeDeleted is true;
// otherwise it returns only active catalog rows.
func (q *Queries) ListProducts(ctx context.Context, userID uuid.UUID, includeDeleted bool) ([]Product, error) {
	rows, err := q.db.Query(ctx, listProductsSQL, uuidArg(userID), includeDeleted)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	products := make([]Product, 0)
	for rows.Next() {
		product, err := scanProduct(rows)
		if err != nil {
			return nil, err
		}
		products = append(products, product)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return products, nil
}

// ListSnapshotProducts returns all account-owned products, including retained
// tombstones, up to maxRows. truncated is true when the database contained
// more rows than the requested bound.
func (q *Queries) ListSnapshotProducts(ctx context.Context, userID uuid.UUID, maxRows int32) (products []Product, truncated bool, err error) {
	if maxRows <= 0 || maxRows == int32(^uint32(0)>>1) {
		return nil, false, fmt.Errorf("snapshot product limit must be between 1 and %d", int32(^uint32(0)>>1)-1)
	}
	rows, err := q.db.Query(ctx, listSnapshotProductsSQL, uuidArg(userID), maxRows+1)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()

	products = make([]Product, 0)
	for rows.Next() {
		product, err := scanProduct(rows)
		if err != nil {
			return nil, false, err
		}
		products = append(products, product)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	if len(products) > int(maxRows) {
		return products[:maxRows], true, nil
	}
	return products, false, nil
}

// UpdateProduct performs a full version-checked edit. pgx.ErrNoRows means the
// product is missing, deleted, not owned by the caller, or has a stale version.
func (q *Queries) UpdateProduct(ctx context.Context, params UpdateProductParams) (Product, error) {
	return scanProduct(q.db.QueryRow(ctx, updateProductSQL,
		uuidArg(params.UserID),
		uuidArg(params.ID),
		optionalStringArg(params.Barcode),
		optionalStringArg(params.SKU),
		params.Name,
		optionalStringArg(params.Description),
		params.Unit,
		optionalStringArg(params.Category),
		optionalInt32Arg(params.MinStock),
		uuidArg(params.UpdatedByDeviceID),
		params.BaseVersion,
	))
}

// SoftDeleteProduct creates a product tombstone with a version check. It never
// removes the row or its historical movements.
func (q *Queries) SoftDeleteProduct(ctx context.Context, params SoftDeleteProductParams) (Product, error) {
	return scanProduct(q.db.QueryRow(ctx, softDeleteProductSQL,
		uuidArg(params.UserID),
		uuidArg(params.ID),
		params.BaseVersion,
		uuidArg(params.UpdatedByDeviceID),
	))
}

// InsertStockMovement appends one immutable movement for an active product
// owned by UserID. There is deliberately no update/delete counterpart.
func (q *Queries) InsertStockMovement(ctx context.Context, params CreateStockMovementParams) (StockMovement, error) {
	return scanStockMovement(q.db.QueryRow(ctx, insertStockMovementSQL,
		uuidArg(params.ID),
		uuidArg(params.UserID),
		uuidArg(params.ProductID),
		params.Delta,
		params.Kind,
		optionalStringArg(params.Note),
		params.OccurredAt,
		params.RawOccurredAt,
		params.ClockOffsetMs,
		optionalInt32Arg(params.CountedQty),
		optionalUUIDArg(params.ReversesID),
		uuidArg(params.DeviceID),
	))
}

// GetStockMovement returns a ledger row only from the requested user's scope.
func (q *Queries) GetStockMovement(ctx context.Context, userID, movementID uuid.UUID) (StockMovement, error) {
	return scanStockMovement(q.db.QueryRow(ctx, getStockMovementSQL, uuidArg(userID), uuidArg(movementID)))
}

// GetStockMovementByID is used internally to distinguish a missing movement
// from a movement owned by another account before returning a domain error.
func (q *Queries) GetStockMovementByID(ctx context.Context, movementID uuid.UUID) (StockMovement, error) {
	return scanStockMovement(q.db.QueryRow(ctx, getStockMovementByIDSQL, uuidArg(movementID)))
}

// GetProductLedgerBalance computes the canonical quantity and latest
// occurrence directly from immutable stock movements. It never reads the
// product_balances projection.
func (q *Queries) GetProductLedgerBalance(ctx context.Context, userID, productID uuid.UUID) (LedgerBalance, error) {
	var qty int64
	var lastMovementAt pgtype.Timestamptz
	if err := q.db.QueryRow(ctx, getProductLedgerBalanceSQL,
		uuidArg(userID), uuidArg(productID)).Scan(&qty, &lastMovementAt); err != nil {
		return LedgerBalance{}, err
	}
	return LedgerBalance{
		ProductID:      productID,
		Qty:            qty,
		LastMovementAt: timeFromPG(lastMovementAt),
	}, nil
}

// ListLedgerBalances computes one canonical balance for every product in the
// account directly from stock_movements, including zero-movement products.
func (q *Queries) ListLedgerBalances(ctx context.Context, userID uuid.UUID) ([]LedgerBalance, error) {
	rows, err := q.db.Query(ctx, listLedgerBalancesSQL, uuidArg(userID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	balances := make([]LedgerBalance, 0)
	for rows.Next() {
		var productID pgtype.UUID
		var qty int64
		var lastMovementAt pgtype.Timestamptz
		if err := rows.Scan(&productID, &qty, &lastMovementAt); err != nil {
			return nil, err
		}
		balances = append(balances, LedgerBalance{
			ProductID:      uuidFromPG(productID),
			Qty:            qty,
			LastMovementAt: timeFromPG(lastMovementAt),
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return balances, nil
}

// ListProductBalances returns the stored projection rows for an account. The
// account predicate is applied through products because product_balances is a
// deliberately small projection keyed only by product ID.
func (q *Queries) ListProductBalances(ctx context.Context, userID uuid.UUID) ([]ProductBalance, error) {
	rows, err := q.db.Query(ctx, listProductBalancesSQL, uuidArg(userID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	balances := make([]ProductBalance, 0)
	for rows.Next() {
		balance, err := scanProductBalance(rows)
		if err != nil {
			return nil, err
		}
		balances = append(balances, balance)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return balances, nil
}

// RebuildProductBalances recomputes projection rows from the ledger in one
// statement. It is a repair operation, never a source of truth for domain
// decisions.
func (q *Queries) RebuildProductBalances(ctx context.Context, userID uuid.UUID) error {
	_, err := q.db.Exec(ctx, rebuildProductBalancesSQL, uuidArg(userID))
	return err
}

// ListStockMovements returns immutable ledger history in occurrence order.
func (q *Queries) ListStockMovements(ctx context.Context, userID, productID uuid.UUID) ([]StockMovement, error) {
	rows, err := q.db.Query(ctx, listStockMovementsSQL, uuidArg(userID), uuidArg(productID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	movements := make([]StockMovement, 0)
	for rows.Next() {
		movement, err := scanStockMovement(rows)
		if err != nil {
			return nil, err
		}
		movements = append(movements, movement)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return movements, nil
}

// ListSnapshotMovements returns every retained immutable movement for an
// account in deterministic product/occurrence order, up to maxRows.
func (q *Queries) ListSnapshotMovements(ctx context.Context, userID uuid.UUID, maxRows int32) (movements []StockMovement, truncated bool, err error) {
	if maxRows <= 0 || maxRows == int32(^uint32(0)>>1) {
		return nil, false, fmt.Errorf("snapshot movement limit must be between 1 and %d", int32(^uint32(0)>>1)-1)
	}
	rows, err := q.db.Query(ctx, listSnapshotMovementsSQL, uuidArg(userID), maxRows+1)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()

	movements = make([]StockMovement, 0)
	for rows.Next() {
		movement, err := scanStockMovement(rows)
		if err != nil {
			return nil, false, err
		}
		movements = append(movements, movement)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	if len(movements) > int(maxRows) {
		return movements[:maxRows], true, nil
	}
	return movements, false, nil
}

// ListSnapshotBalances derives one canonical balance per account product from
// immutable movements. It intentionally does not read product_balances, so a
// stale or missing projection cannot corrupt bootstrap data.
func (q *Queries) ListSnapshotBalances(ctx context.Context, userID uuid.UUID, maxRows int32) (balances []LedgerBalance, truncated bool, err error) {
	if maxRows <= 0 || maxRows == int32(^uint32(0)>>1) {
		return nil, false, fmt.Errorf("snapshot balance limit must be between 1 and %d", int32(^uint32(0)>>1)-1)
	}
	rows, err := q.db.Query(ctx, listSnapshotBalancesSQL, uuidArg(userID), maxRows+1)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()

	balances = make([]LedgerBalance, 0)
	for rows.Next() {
		var productID pgtype.UUID
		var qty int64
		var lastMovementAt pgtype.Timestamptz
		if err := rows.Scan(&productID, &qty, &lastMovementAt); err != nil {
			return nil, false, err
		}
		balances = append(balances, LedgerBalance{
			ProductID:      uuidFromPG(productID),
			Qty:            qty,
			LastMovementAt: timeFromPG(lastMovementAt),
		})
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	if len(balances) > int(maxRows) {
		return balances[:maxRows], true, nil
	}
	return balances, false, nil
}

// CurrentDatabaseTime returns PostgreSQL's transaction timestamp. It is used
// in snapshot responses so the reported server time belongs to the same
// consistent read view as the returned rows and cursor.
func (q *Queries) CurrentDatabaseTime(ctx context.Context) (time.Time, error) {
	var current time.Time
	if err := q.db.QueryRow(ctx, currentDatabaseTimeSQL).Scan(&current); err != nil {
		return time.Time{}, err
	}
	return current.UTC(), nil
}

// IncrementProductBalance updates the rebuildable projection by one movement
// delta. Call it in the same transaction as InsertStockMovement.
func (q *Queries) IncrementProductBalance(ctx context.Context, params IncrementProductBalanceParams) (ProductBalance, error) {
	return scanProductBalance(q.db.QueryRow(ctx, incrementProductBalanceSQL,
		uuidArg(params.UserID),
		uuidArg(params.ProductID),
		params.Delta,
		params.OccurredAt,
	))
}

// UpsertProductBalance sets a projection value for a user-owned product. It is
// intended for projection rebuilds and bootstrap, not as a replacement for
// ledger writes.
func (q *Queries) UpsertProductBalance(ctx context.Context, params UpsertProductBalanceParams) (ProductBalance, error) {
	return scanProductBalance(q.db.QueryRow(ctx, upsertProductBalanceSQL,
		uuidArg(params.UserID),
		uuidArg(params.ProductID),
		params.Qty,
		optionalTimeArg(params.LastMovementAt),
	))
}

// GetProductBalance returns the projection only when the product belongs to
// the requested user.
func (q *Queries) GetProductBalance(ctx context.Context, userID, productID uuid.UUID) (ProductBalance, error) {
	return scanProductBalance(q.db.QueryRow(ctx, getProductBalanceSQL, uuidArg(userID), uuidArg(productID)))
}

// AllocateChangeSequence increments the transaction-scoped allocator row. It
// must be called in the same transaction as the domain/change-log insert.
func (q *Queries) AllocateChangeSequence(ctx context.Context) (int64, error) {
	var seq int64
	if err := q.db.QueryRow(ctx, allocateChangeSequenceSQL).Scan(&seq); err != nil {
		return 0, err
	}
	return seq, nil
}

// CurrentChangeSequence reads the allocator high-water mark.
func (q *Queries) CurrentChangeSequence(ctx context.Context) (int64, error) {
	var seq int64
	if err := q.db.QueryRow(ctx, currentChangeSequenceSQL).Scan(&seq); err != nil {
		return 0, err
	}
	return seq, nil
}

// InsertChangeLog records a replication event with an ownership check for the
// optional originating device. It is the low-level insert used by
// AppendChangeLog after the transaction-scoped sequence has been allocated;
// callers should not provide cursor values themselves.
func (q *Queries) InsertChangeLog(ctx context.Context, params InsertChangeLogParams) (ChangeLogEntry, error) {
	return scanChangeLogEntry(q.db.QueryRow(ctx, insertChangeLogSQL,
		params.Seq,
		uuidArg(params.UserID),
		params.Entity,
		uuidArg(params.EntityID),
		params.Op,
		params.Payload,
		optionalUUIDArg(params.OriginDeviceID),
	))
}

// AppendChangeLog allocates the next change cursor from sync_seq_counter and
// inserts the corresponding event on this same query executor. The Queries
// value must be transaction-bound with WithTx when this is paired with a
// domain mutation. The returned sequence is only a committed cursor after the
// enclosing transaction commits; rolling back restores both the counter and
// the change-log row.
func (q *Queries) AppendChangeLog(ctx context.Context, params AppendChangeLogParams) (ChangeLogEntry, error) {
	seq, err := q.AllocateChangeSequence(ctx)
	if err != nil {
		return ChangeLogEntry{}, err
	}
	return q.InsertChangeLog(ctx, InsertChangeLogParams{
		Seq:            seq,
		UserID:         params.UserID,
		Entity:         params.Entity,
		EntityID:       params.EntityID,
		Op:             params.Op,
		Payload:        params.Payload,
		OriginDeviceID: params.OriginDeviceID,
	})
}

// ListChangeLog returns changes strictly after AfterSeq in ascending cursor
// order and no more than MaxChanges rows.
func (q *Queries) ListChangeLog(ctx context.Context, params ListChangeLogParams) ([]ChangeLogEntry, error) {
	if params.MaxChanges <= 0 {
		return nil, fmt.Errorf("max changes must be greater than zero")
	}
	rows, err := q.db.Query(ctx, listChangeLogSQL,
		uuidArg(params.UserID), params.AfterSeq, params.MaxChanges)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	changes := make([]ChangeLogEntry, 0)
	for rows.Next() {
		change, err := scanChangeLogEntry(rows)
		if err != nil {
			return nil, err
		}
		changes = append(changes, change)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return changes, nil
}

// GetSyncOperation returns the canonical idempotency outcome in the user's
// device scope.
func (q *Queries) GetSyncOperation(ctx context.Context, userID, deviceID, opID uuid.UUID) (SyncOperation, error) {
	return scanSyncOperation(q.db.QueryRow(ctx, getSyncOperationSQL,
		uuidArg(userID), uuidArg(deviceID), uuidArg(opID)))
}

// TryInsertSyncOperation atomically reserves an operation key. inserted is
// false when the composite (device_id, op_id) already exists; callers can then
// leave duplicate-response replay to the synchronization layer without
// reapplying domain logic.
func (q *Queries) TryInsertSyncOperation(ctx context.Context, params InsertSyncOperationParams) (operation SyncOperation, inserted bool, err error) {
	row := q.db.QueryRow(ctx, tryInsertSyncOperationSQL,
		uuidArg(params.UserID),
		uuidArg(params.DeviceID),
		uuidArg(params.OpID),
		params.Status,
		optionalStringArg(params.Reason),
		params.Response,
		optionalTimeArg(params.CompletedAt),
	)

	operation, err = scanSyncOperation(row)
	if err == pgx.ErrNoRows {
		return SyncOperation{}, false, nil
	}
	if err != nil {
		return SyncOperation{}, false, err
	}
	return operation, true, nil
}

// UpdateSyncOperation finalizes a previously reserved operation outcome in the
// same transaction as its domain mutation and change-log entry.
func (q *Queries) UpdateSyncOperation(ctx context.Context, params UpdateSyncOperationParams) (SyncOperation, error) {
	return scanSyncOperation(q.db.QueryRow(ctx, updateSyncOperationSQL,
		uuidArg(params.UserID),
		uuidArg(params.DeviceID),
		uuidArg(params.OpID),
		params.Status,
		optionalStringArg(params.Reason),
		params.Response,
		optionalTimeArg(params.CompletedAt),
	))
}

func scanProduct(row pgx.Row) (Product, error) {
	var (
		id, userID, updatedByDeviceID       pgtype.UUID
		barcode, sku, description, category pgtype.Text
		minStock                            pgtype.Int4
		name, unit                          string
		version                             int64
		updatedAt, createdAt                time.Time
		deletedAt                           pgtype.Timestamptz
	)
	if err := row.Scan(
		&id, &userID, &barcode, &sku, &name, &description, &unit,
		&category, &minStock, &version, &updatedAt, &updatedByDeviceID,
		&deletedAt, &createdAt,
	); err != nil {
		return Product{}, err
	}
	return Product{
		ID:                uuidFromPG(id),
		UserID:            uuidFromPG(userID),
		Barcode:           stringFromPG(barcode),
		SKU:               stringFromPG(sku),
		Name:              name,
		Description:       stringFromPG(description),
		Unit:              unit,
		Category:          stringFromPG(category),
		MinStock:          int32FromPG(minStock),
		Version:           version,
		UpdatedAt:         updatedAt,
		UpdatedByDeviceID: uuidFromPG(updatedByDeviceID),
		DeletedAt:         timeFromPG(deletedAt),
		CreatedAt:         createdAt,
	}, nil
}

func scanStockMovement(row pgx.Row) (StockMovement, error) {
	var (
		id, userID, productID, reversesID, deviceID pgtype.UUID
		note                                        pgtype.Text
		countedQty                                  pgtype.Int4
		delta                                       int32
		kind                                        string
		occurredAt, rawOccurredAt, serverCreatedAt  time.Time
		clockOffsetMs                               int64
	)
	if err := row.Scan(
		&id, &userID, &productID, &delta, &kind, &note, &occurredAt,
		&rawOccurredAt, &clockOffsetMs, &countedQty, &reversesID, &deviceID,
		&serverCreatedAt,
	); err != nil {
		return StockMovement{}, err
	}
	return StockMovement{
		ID:              uuidFromPG(id),
		UserID:          uuidFromPG(userID),
		ProductID:       uuidFromPG(productID),
		Delta:           delta,
		Kind:            kind,
		Note:            stringFromPG(note),
		OccurredAt:      occurredAt,
		RawOccurredAt:   rawOccurredAt,
		ClockOffsetMs:   clockOffsetMs,
		CountedQty:      int32FromPG(countedQty),
		ReversesID:      uuidPointerFromPG(reversesID),
		DeviceID:        uuidFromPG(deviceID),
		ServerCreatedAt: serverCreatedAt,
	}, nil
}

func scanProductBalance(row pgx.Row) (ProductBalance, error) {
	var productID pgtype.UUID
	var qty int64
	var lastMovementAt pgtype.Timestamptz
	var updatedAt time.Time
	if err := row.Scan(&productID, &qty, &lastMovementAt, &updatedAt); err != nil {
		return ProductBalance{}, err
	}
	return ProductBalance{
		ProductID:      uuidFromPG(productID),
		Qty:            qty,
		LastMovementAt: timeFromPG(lastMovementAt),
		UpdatedAt:      updatedAt,
	}, nil
}

func scanChangeLogEntry(row pgx.Row) (ChangeLogEntry, error) {
	var seq int64
	var userID, entityID, originDeviceID pgtype.UUID
	var entity, op string
	var payload []byte
	var createdAt time.Time
	if err := row.Scan(
		&seq, &userID, &entity, &entityID, &op, &payload, &originDeviceID,
		&createdAt,
	); err != nil {
		return ChangeLogEntry{}, err
	}
	return ChangeLogEntry{
		Seq:            seq,
		UserID:         uuidFromPG(userID),
		Entity:         entity,
		EntityID:       uuidFromPG(entityID),
		Op:             op,
		Payload:        append([]byte(nil), payload...),
		OriginDeviceID: uuidPointerFromPG(originDeviceID),
		CreatedAt:      createdAt,
	}, nil
}

func scanSyncOperation(row pgx.Row) (SyncOperation, error) {
	var deviceID, opID, userID pgtype.UUID
	var status string
	var reason pgtype.Text
	var response []byte
	var receivedAt time.Time
	var completedAt pgtype.Timestamptz
	if err := row.Scan(
		&deviceID, &opID, &userID, &status, &reason, &response, &receivedAt,
		&completedAt,
	); err != nil {
		return SyncOperation{}, err
	}
	return SyncOperation{
		DeviceID:    uuidFromPG(deviceID),
		OpID:        uuidFromPG(opID),
		UserID:      uuidFromPG(userID),
		Status:      status,
		Reason:      stringFromPG(reason),
		Response:    append([]byte(nil), response...),
		ReceivedAt:  receivedAt,
		CompletedAt: timeFromPG(completedAt),
	}, nil
}

func uuidArg(value uuid.UUID) pgtype.UUID {
	return pgtype.UUID{Bytes: value, Valid: true}
}

func optionalUUIDArg(value *uuid.UUID) any {
	if value == nil {
		return nil
	}
	return uuidArg(*value)
}

func optionalStringArg(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func optionalInt32Arg(value *int32) any {
	if value == nil {
		return nil
	}
	return *value
}

func optionalTimeArg(value *time.Time) any {
	if value == nil {
		return nil
	}
	return *value
}

func uuidFromPG(value pgtype.UUID) uuid.UUID {
	return uuid.UUID(value.Bytes)
}

func uuidPointerFromPG(value pgtype.UUID) *uuid.UUID {
	if !value.Valid {
		return nil
	}
	result := uuidFromPG(value)
	return &result
}

func stringFromPG(value pgtype.Text) *string {
	if !value.Valid {
		return nil
	}
	result := value.String
	return &result
}

func stringFromPGValue(value pgtype.Text) string {
	if !value.Valid {
		return ""
	}
	return value.String
}

func int32FromPG(value pgtype.Int4) *int32 {
	if !value.Valid {
		return nil
	}
	result := value.Int32
	return &result
}

func timeFromPG(value pgtype.Timestamptz) *time.Time {
	if !value.Valid {
		return nil
	}
	result := value.Time
	return &result
}
