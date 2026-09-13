// Package movements contains account-scoped immutable stock-ledger
// transactions and rebuildable balance projection maintenance.
package movements

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/stoksync/stoksync/server/internal/db"
)

const (
	kindReceive   = "receive"
	kindIssue     = "issue"
	kindAdjust    = "adjust"
	kindStocktake = "stocktake"

	minInt32Value int64 = -1 << 31
	maxInt32Value int64 = 1<<31 - 1
)

var (
	// ErrInvalidInput means a movement request cannot satisfy the domain shape
	// before it reaches PostgreSQL.
	ErrInvalidInput = errors.New("invalid movement input")
	// ErrInvalidDelta means a movement would have a zero or non-representable
	// signed quantity change.
	ErrInvalidDelta = errors.New("movement delta must be non-zero")
	// ErrInvalidKind means the movement type is outside the v1 enum.
	ErrInvalidKind = errors.New("invalid movement kind")
	// ErrProductNotFound means the referenced product identifier does not exist.
	ErrProductNotFound = errors.New("product not found")
	// ErrProductDeleted means the referenced product is a retained tombstone.
	ErrProductDeleted = errors.New("product is deleted")
	// ErrOwnershipViolation means the account/device relationship is invalid.
	ErrOwnershipViolation = errors.New("movement ownership violation")
	// ErrMovementNotFound means a reversal target does not exist.
	ErrMovementNotFound = errors.New("movement not found")
	// ErrInvalidReversal means the reversal target cannot be linked to this
	// product or its delta cannot be represented by the ledger schema.
	ErrInvalidReversal = errors.New("invalid movement reversal")
	// ErrMovementConflict means a client reused an existing movement id.
	ErrMovementConflict = errors.New("movement already exists")
	// ErrInvalidStocktake means counted quantity was not valid for a stocktake.
	ErrInvalidStocktake = errors.New("invalid stocktake")

	// Compatibility aliases for callers that use more descriptive names.
	ErrInvalidMovementKind = ErrInvalidKind
	ErrStaleProduct        = ErrProductNotFound
)

// Service owns immutable movement transactions. It accepts the transaction
// beginner interface so tests can assert rollback behavior without a live
// PostgreSQL server; *db.Pool satisfies it.
type Service struct {
	beginner db.TxBeginner
}

// NewService creates a movement service bound to a PostgreSQL transaction
// beginner.
func NewService(beginner db.TxBeginner) (*Service, error) {
	if beginner == nil {
		return nil, errors.New("movement transaction beginner must not be nil")
	}
	return &Service{beginner: beginner}, nil
}

// AppendInput is the immutable movement shape accepted by AppendMovement.
type AppendInput = db.CreateStockMovementParams

// CreateInput is a concise alias for AppendInput.
type CreateInput = AppendInput

// ReverseInput requests a new adjust movement that reverses an existing
// immutable movement. OriginalMovementID is accepted as a readable alias for
// MovementID; exactly one identifier must be supplied.
type ReverseInput struct {
	ID                 uuid.UUID
	UserID             uuid.UUID
	DeviceID           uuid.UUID
	MovementID         uuid.UUID
	OriginalMovementID uuid.UUID
	Note               *string
	OccurredAt         time.Time
	RawOccurredAt      time.Time
	ClockOffsetMs      int64
}

// StocktakeInput captures an absolute counted quantity. The service derives
// the signed delta from the canonical ledger while the product row is locked.
type StocktakeInput struct {
	ID            uuid.UUID
	UserID        uuid.UUID
	ProductID     uuid.UUID
	DeviceID      uuid.UUID
	CountedQty    int32
	Note          *string
	OccurredAt    time.Time
	RawOccurredAt time.Time
	ClockOffsetMs int64
}

// ProjectionMismatch describes a difference between a ledger-derived balance
// and its stored read projection. A nil ActualQty means the projection row is
// missing; ExpectedQty and ActualQty are always based on the same product.
type ProjectionMismatch struct {
	ProductID      uuid.UUID
	Kind           string
	ExpectedQty    int64
	ActualQty      *int64
	ExpectedLastAt *time.Time
	ActualLastAt   *time.Time
}

const (
	MismatchMissingProjection    = "missing_projection"
	MismatchQuantity             = "quantity_mismatch"
	MismatchLastMovement         = "last_movement_mismatch"
	MismatchUnexpectedProjection = "unexpected_projection"
)

// ProjectionVerification is a read-only consistency report. A mismatch is a
// result, not an error: callers can inspect it and choose whether to rebuild.
type ProjectionVerification struct {
	UserID          uuid.UUID
	CheckedProducts int
	Mismatches      []ProjectionMismatch
	Consistent      bool
}

// AppendMovement appends one immutable movement and increments the balance
// projection in the same transaction. Stocktake deltas are computed from the
// canonical ledger; ordinary movements use the supplied non-zero delta.
func (s *Service) AppendMovement(ctx context.Context, input AppendInput) (db.StockMovement, error) {
	normalized, err := normalizeAppendInput(input)
	if err != nil {
		return db.StockMovement{}, err
	}
	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (db.StockMovement, error) {
		return s.appendInTransaction(ctx, queries, normalized)
	})
}

// AppendMovementInTransaction appends one immutable movement using queries
// bound to an outer transaction. Synchronization uses this method so the
// ledger, balance projection, change log, and operation outcome commit as one.
func (s *Service) AppendMovementInTransaction(ctx context.Context, queries *db.Queries, input AppendInput) (db.StockMovement, error) {
	if s == nil || queries == nil {
		return db.StockMovement{}, ErrInvalidInput
	}
	normalized, err := normalizeAppendInput(input)
	if err != nil {
		return db.StockMovement{}, err
	}
	return s.appendInTransaction(ctx, queries, normalized)
}

// Append is a concise alias for AppendMovement.
func (s *Service) Append(ctx context.Context, input CreateInput) (db.StockMovement, error) {
	return s.AppendMovement(ctx, input)
}

// ReverseMovement appends an adjust movement with the opposite delta and a
// reverses_id link. The original row is never updated or removed.
func (s *Service) ReverseMovement(ctx context.Context, input ReverseInput) (db.StockMovement, error) {
	input, err := normalizeReverseInput(input)
	if err != nil {
		return db.StockMovement{}, err
	}
	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (db.StockMovement, error) {
		original, err := queries.GetStockMovementByID(ctx, input.movementID())
		if errors.Is(err, pgx.ErrNoRows) {
			return db.StockMovement{}, ErrMovementNotFound
		}
		if err != nil {
			return db.StockMovement{}, err
		}
		if original.UserID != input.UserID {
			return db.StockMovement{}, ErrOwnershipViolation
		}
		if int64(original.Delta) == minInt32Value {
			return db.StockMovement{}, ErrInvalidReversal
		}
		return s.appendInTransaction(ctx, queries, db.CreateStockMovementParams{
			ID:            input.ID,
			UserID:        input.UserID,
			ProductID:     original.ProductID,
			Delta:         -original.Delta,
			Kind:          kindAdjust,
			Note:          input.Note,
			OccurredAt:    input.OccurredAt,
			RawOccurredAt: input.RawOccurredAt,
			ClockOffsetMs: input.ClockOffsetMs,
			ReversesID:    &original.ID,
			DeviceID:      input.DeviceID,
		})
	})
}

// Reverse is a concise alias for ReverseMovement.
func (s *Service) Reverse(ctx context.Context, input ReverseInput) (db.StockMovement, error) {
	return s.ReverseMovement(ctx, input)
}

// RecordStocktake computes and appends a stocktake adjustment from the
// canonical ledger while serializing on the product row.
func (s *Service) RecordStocktake(ctx context.Context, input StocktakeInput) (db.StockMovement, error) {
	if input.CountedQty < 0 {
		return db.StockMovement{}, ErrInvalidStocktake
	}
	countedQty := input.CountedQty
	return s.AppendMovement(ctx, AppendInput{
		ID:            input.ID,
		UserID:        input.UserID,
		ProductID:     input.ProductID,
		Delta:         0,
		Kind:          kindStocktake,
		Note:          input.Note,
		OccurredAt:    input.OccurredAt,
		RawOccurredAt: input.RawOccurredAt,
		ClockOffsetMs: input.ClockOffsetMs,
		CountedQty:    &countedQty,
		DeviceID:      input.DeviceID,
	})
}

// Stocktake is a concise alias for RecordStocktake.
func (s *Service) Stocktake(ctx context.Context, input StocktakeInput) (db.StockMovement, error) {
	return s.RecordStocktake(ctx, input)
}

// RebuildProductBalances repairs all projection rows for one account from the
// immutable ledger in one transaction. It does not alter stock movements.
func (s *Service) RebuildProductBalances(ctx context.Context, userID uuid.UUID) error {
	if userID == uuid.Nil {
		return ErrInvalidInput
	}
	return db.WithTx(ctx, s.beginner, func(queries *db.Queries) error {
		return mapMovementError(queries.RebuildProductBalances(ctx, userID))
	})
}

// RebuildBalances is a concise alias for RebuildProductBalances.
func (s *Service) RebuildBalances(ctx context.Context, userID uuid.UUID) error {
	return s.RebuildProductBalances(ctx, userID)
}

// VerifyProductBalances compares projection rows with balances recomputed from
// stock_movements. It runs both reads in one transaction for a consistent
// report and never uses the projection to calculate expected quantities.
func (s *Service) VerifyProductBalances(ctx context.Context, userID uuid.UUID) (ProjectionVerification, error) {
	if userID == uuid.Nil {
		return ProjectionVerification{}, ErrInvalidInput
	}
	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (ProjectionVerification, error) {
		canonical, err := queries.ListLedgerBalances(ctx, userID)
		if err != nil {
			return ProjectionVerification{}, err
		}
		projected, err := queries.ListProductBalances(ctx, userID)
		if err != nil {
			return ProjectionVerification{}, err
		}
		return compareBalances(userID, canonical, projected), nil
	})
}

// VerifyBalances is a concise alias for VerifyProductBalances.
func (s *Service) VerifyBalances(ctx context.Context, userID uuid.UUID) (ProjectionVerification, error) {
	return s.VerifyProductBalances(ctx, userID)
}

// VerifyProjection is a concise alias for VerifyProductBalances.
func (s *Service) VerifyProjection(ctx context.Context, userID uuid.UUID) (ProjectionVerification, error) {
	return s.VerifyProductBalances(ctx, userID)
}

func (s *Service) appendInTransaction(ctx context.Context, queries *db.Queries, input AppendInput) (db.StockMovement, error) {
	product, err := queries.GetProductForUpdate(ctx, input.UserID, input.ProductID)
	if errors.Is(err, pgx.ErrNoRows) {
		return db.StockMovement{}, classifyProductMiss(ctx, queries, input.UserID, input.ProductID)
	}
	if err != nil {
		return db.StockMovement{}, err
	}
	if product.DeletedAt != nil {
		return db.StockMovement{}, ErrProductDeleted
	}

	if input.ReversesID != nil {
		original, err := queries.GetStockMovementByID(ctx, *input.ReversesID)
		if errors.Is(err, pgx.ErrNoRows) {
			return db.StockMovement{}, ErrMovementNotFound
		}
		if err != nil {
			return db.StockMovement{}, err
		}
		if original.UserID != input.UserID {
			return db.StockMovement{}, ErrOwnershipViolation
		}
		if original.ProductID != input.ProductID {
			return db.StockMovement{}, ErrInvalidReversal
		}
	}

	delta := input.Delta
	if input.Kind == kindStocktake {
		canonical, err := queries.GetProductLedgerBalance(ctx, input.UserID, input.ProductID)
		if err != nil {
			return db.StockMovement{}, err
		}
		delta64 := int64(*input.CountedQty) - canonical.Qty
		if delta64 == 0 || delta64 < minInt32Value || delta64 > maxInt32Value {
			return db.StockMovement{}, ErrInvalidDelta
		}
		delta = int32(delta64)
	}
	if delta == 0 {
		return db.StockMovement{}, ErrInvalidDelta
	}

	input.Delta = delta
	movement, err := queries.InsertStockMovement(ctx, input)
	if errors.Is(err, pgx.ErrNoRows) {
		return db.StockMovement{}, classifyProductMiss(ctx, queries, input.UserID, input.ProductID)
	}
	if err != nil {
		return db.StockMovement{}, mapMovementError(err)
	}
	if _, err := queries.IncrementProductBalance(ctx, db.IncrementProductBalanceParams{
		UserID:     input.UserID,
		ProductID:  input.ProductID,
		Delta:      movement.Delta,
		OccurredAt: movement.OccurredAt,
	}); err != nil {
		return db.StockMovement{}, mapMovementError(err)
	}
	return movement, nil
}

func normalizeAppendInput(input AppendInput) (AppendInput, error) {
	if input.ID == uuid.Nil || input.UserID == uuid.Nil || input.ProductID == uuid.Nil || input.DeviceID == uuid.Nil {
		return AppendInput{}, ErrInvalidInput
	}
	input.Kind = strings.TrimSpace(input.Kind)
	if !isMovementKind(input.Kind) {
		return AppendInput{}, ErrInvalidKind
	}
	if input.OccurredAt.IsZero() {
		return AppendInput{}, ErrInvalidInput
	}
	input.OccurredAt = input.OccurredAt.UTC()
	if input.RawOccurredAt.IsZero() {
		input.RawOccurredAt = input.OccurredAt
	} else {
		input.RawOccurredAt = input.RawOccurredAt.UTC()
	}
	input.Note = normalizeOptionalString(input.Note)
	if input.ReversesID != nil && (*input.ReversesID == uuid.Nil || input.Kind != kindAdjust) {
		return AppendInput{}, ErrInvalidReversal
	}
	if input.Kind == kindStocktake {
		if input.CountedQty == nil || *input.CountedQty < 0 {
			return AppendInput{}, ErrInvalidStocktake
		}
	} else {
		if input.CountedQty != nil {
			return AppendInput{}, ErrInvalidStocktake
		}
		if input.Delta == 0 {
			return AppendInput{}, ErrInvalidDelta
		}
	}
	return input, nil
}

func normalizeReverseInput(input ReverseInput) (ReverseInput, error) {
	if input.ID == uuid.Nil || input.UserID == uuid.Nil || input.DeviceID == uuid.Nil {
		return ReverseInput{}, ErrInvalidInput
	}
	if input.MovementID == uuid.Nil && input.OriginalMovementID == uuid.Nil {
		return ReverseInput{}, ErrInvalidReversal
	}
	if input.MovementID != uuid.Nil && input.OriginalMovementID != uuid.Nil && input.MovementID != input.OriginalMovementID {
		return ReverseInput{}, ErrInvalidReversal
	}
	if input.OccurredAt.IsZero() {
		return ReverseInput{}, ErrInvalidInput
	}
	input.OccurredAt = input.OccurredAt.UTC()
	if input.RawOccurredAt.IsZero() {
		input.RawOccurredAt = input.OccurredAt
	} else {
		input.RawOccurredAt = input.RawOccurredAt.UTC()
	}
	input.Note = normalizeOptionalString(input.Note)
	return input, nil
}

func (input ReverseInput) movementID() uuid.UUID {
	if input.MovementID != uuid.Nil {
		return input.MovementID
	}
	return input.OriginalMovementID
}

func classifyProductMiss(ctx context.Context, queries *db.Queries, userID, productID uuid.UUID) error {
	product, err := queries.GetProductByID(ctx, productID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrProductNotFound
	}
	if err != nil {
		return err
	}
	if product.UserID != userID {
		return ErrOwnershipViolation
	}
	if product.DeletedAt != nil {
		return ErrProductDeleted
	}
	return ErrProductNotFound
}

func compareBalances(userID uuid.UUID, canonical []db.LedgerBalance, projected []db.ProductBalance) ProjectionVerification {
	canonicalByID := make(map[uuid.UUID]db.LedgerBalance, len(canonical))
	for _, balance := range canonical {
		canonicalByID[balance.ProductID] = balance
	}
	projectedByID := make(map[uuid.UUID]db.ProductBalance, len(projected))
	for _, balance := range projected {
		projectedByID[balance.ProductID] = balance
	}

	mismatches := make([]ProjectionMismatch, 0)
	for _, expected := range canonical {
		actual, ok := projectedByID[expected.ProductID]
		if !ok {
			mismatches = append(mismatches, ProjectionMismatch{
				ProductID:      expected.ProductID,
				Kind:           MismatchMissingProjection,
				ExpectedQty:    expected.Qty,
				ExpectedLastAt: cloneTime(expected.LastMovementAt),
			})
			continue
		}
		actualQty := actual.Qty
		if actual.Qty != expected.Qty {
			mismatches = append(mismatches, ProjectionMismatch{
				ProductID:      expected.ProductID,
				Kind:           MismatchQuantity,
				ExpectedQty:    expected.Qty,
				ActualQty:      &actualQty,
				ExpectedLastAt: cloneTime(expected.LastMovementAt),
				ActualLastAt:   cloneTime(actual.LastMovementAt),
			})
			continue
		}
		if !sameTime(expected.LastMovementAt, actual.LastMovementAt) {
			mismatches = append(mismatches, ProjectionMismatch{
				ProductID:      expected.ProductID,
				Kind:           MismatchLastMovement,
				ExpectedQty:    expected.Qty,
				ActualQty:      &actualQty,
				ExpectedLastAt: cloneTime(expected.LastMovementAt),
				ActualLastAt:   cloneTime(actual.LastMovementAt),
			})
		}
	}
	for _, actual := range projected {
		if _, ok := canonicalByID[actual.ProductID]; ok {
			continue
		}
		actualQty := actual.Qty
		mismatches = append(mismatches, ProjectionMismatch{
			ProductID:    actual.ProductID,
			Kind:         MismatchUnexpectedProjection,
			ActualQty:    &actualQty,
			ActualLastAt: cloneTime(actual.LastMovementAt),
		})
	}
	sort.Slice(mismatches, func(i, j int) bool {
		return mismatches[i].ProductID.String() < mismatches[j].ProductID.String()
	})
	return ProjectionVerification{
		UserID:          userID,
		CheckedProducts: len(canonical),
		Mismatches:      mismatches,
		Consistent:      len(mismatches) == 0,
	}
}

func sameTime(left, right *time.Time) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return left.Equal(*right)
}

func cloneTime(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func normalizeOptionalString(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func isMovementKind(kind string) bool {
	switch kind {
	case kindReceive, kindIssue, kindAdjust, kindStocktake:
		return true
	default:
		return false
	}
}

func mapMovementError(err error) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return err
	}
	switch pgErr.ConstraintName {
	case "stock_movements_delta_nonzero_check":
		return ErrInvalidDelta
	case "stock_movements_kind_check":
		return ErrInvalidKind
	case "stock_movements_product_owner_fkey", "stock_movements_product_id_fkey", "stock_movements_device_owner_fkey", "stock_movements_device_id_fkey", "stock_movements_user_id_fkey":
		return ErrOwnershipViolation
	case "stock_movements_reverses_owner_fkey", "stock_movements_reverses_id_fkey":
		return ErrInvalidReversal
	case "stock_movements_pkey":
		return ErrMovementConflict
	default:
		return err
	}
}
