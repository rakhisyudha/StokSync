package movements

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/stoksync/stoksync/server/internal/db"
)

func TestMovementServiceRejectsInvalidInputBeforeStartingTransaction(t *testing.T) {
	beginner := &scriptedBeginner{}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}

	_, err = service.AppendMovement(context.Background(), AppendInput{
		ID:         uuid.New(),
		UserID:     uuid.New(),
		ProductID:  uuid.New(),
		DeviceID:   uuid.New(),
		Kind:       "issue",
		Delta:      0,
		OccurredAt: time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC),
	})
	if !errors.Is(err, ErrInvalidDelta) {
		t.Fatalf("AppendMovement() error = %v, want ErrInvalidDelta", err)
	}
	if beginner.beginCalls != 0 {
		t.Fatalf("transaction begin calls = %d, want 0 for invalid input", beginner.beginCalls)
	}
}

func TestAppendMovementRollsBackWhenProjectionUpdateFails(t *testing.T) {
	userID := uuid.New()
	productID := uuid.New()
	deviceID := uuid.New()
	movementID := uuid.New()
	occurredAt := time.Date(2026, time.February, 2, 3, 4, 5, 0, time.UTC)
	projectionErr := errors.New("projection update failed")
	beginner := &scriptedBeginner{tx: &scriptedTx{rows: []pgx.Row{
		productRow(productID, userID, deviceID),
		movementRow(movementID, userID, productID, deviceID, 5, "receive", occurredAt),
		staticRow{err: projectionErr},
	}}}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}

	_, err = service.AppendMovement(context.Background(), AppendInput{
		ID:            movementID,
		UserID:        userID,
		ProductID:     productID,
		DeviceID:      deviceID,
		Delta:         5,
		Kind:          "receive",
		OccurredAt:    occurredAt,
		RawOccurredAt: occurredAt,
	})
	if !errors.Is(err, projectionErr) {
		t.Fatalf("AppendMovement() error = %v, want projection error", err)
	}
	if beginner.tx.commitCalls != 0 {
		t.Fatalf("commit calls = %d, want 0 after projection failure", beginner.tx.commitCalls)
	}
	if beginner.tx.rollbackCalls != 1 {
		t.Fatalf("rollback calls = %d, want 1 after projection failure", beginner.tx.rollbackCalls)
	}
}

func TestAppendMovementCommitsAfterLedgerAndProjectionUpdate(t *testing.T) {
	userID := uuid.New()
	productID := uuid.New()
	deviceID := uuid.New()
	movementID := uuid.New()
	occurredAt := time.Date(2026, time.February, 2, 3, 4, 5, 0, time.UTC)
	beginner := &scriptedBeginner{tx: &scriptedTx{rows: []pgx.Row{
		productRow(productID, userID, deviceID),
		movementRow(movementID, userID, productID, deviceID, -3, "issue", occurredAt),
		balanceRow(productID, -3, occurredAt),
	}}}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}

	movement, err := service.AppendMovement(context.Background(), AppendInput{
		ID:            movementID,
		UserID:        userID,
		ProductID:     productID,
		DeviceID:      deviceID,
		Delta:         -3,
		Kind:          "issue",
		OccurredAt:    occurredAt,
		RawOccurredAt: occurredAt,
	})
	if err != nil {
		t.Fatalf("AppendMovement() error = %v", err)
	}
	if movement.ID != movementID || movement.Delta != -3 {
		t.Fatalf("movement = %#v, want movement %s with delta -3", movement, movementID)
	}
	if beginner.tx.commitCalls != 1 || beginner.tx.rollbackCalls != 0 {
		t.Fatalf("transaction calls = (commit %d, rollback %d), want (1, 0)", beginner.tx.commitCalls, beginner.tx.rollbackCalls)
	}
}

func TestAppendStocktakeRecomputesDeltaFromCanonicalLedger(t *testing.T) {
	userID := uuid.New()
	productID := uuid.New()
	deviceID := uuid.New()
	movementID := uuid.New()
	occurredAt := time.Date(2026, time.February, 2, 3, 4, 5, 0, time.UTC)
	countedQty := int32(5)
	beginner := &scriptedBeginner{tx: &scriptedTx{rows: []pgx.Row{
		productRow(productID, userID, deviceID),
		staticRow{values: []any{
			int64(9),
			pgtype.Timestamptz{Time: occurredAt, Valid: true},
		}},
		movementRowWithCounted(
			movementID,
			userID,
			productID,
			deviceID,
			-4,
			"stocktake",
			occurredAt,
			countedQty,
		),
		balanceRow(productID, 5, occurredAt),
	}}}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}

	movement, err := service.AppendMovement(context.Background(), AppendInput{
		ID:         movementID,
		UserID:     userID,
		ProductID:  productID,
		DeviceID:   deviceID,
		Delta:      123, // Client intent is not canonical for stocktakes.
		Kind:       "stocktake",
		CountedQty: &countedQty,
		OccurredAt: occurredAt,
	})
	if err != nil {
		t.Fatalf("AppendMovement() error = %v", err)
	}
	if movement.Delta != -4 || movement.CountedQty == nil || *movement.CountedQty != countedQty {
		t.Fatalf("movement = %#v, want canonical delta -4 and counted quantity %d", movement, countedQty)
	}
	if beginner.tx.commitCalls != 1 || beginner.tx.rollbackCalls != 0 {
		t.Fatalf("transaction calls = (commit %d, rollback %d), want (1, 0)", beginner.tx.commitCalls, beginner.tx.rollbackCalls)
	}
}

func TestCompareBalancesDetectsCorruptedProjection(t *testing.T) {
	productID := uuid.New()
	occurredAt := time.Date(2026, time.March, 3, 4, 5, 6, 0, time.UTC)
	canonical := []db.LedgerBalance{{ProductID: productID, Qty: 7, LastMovementAt: &occurredAt}}
	actualQty := int64(6)
	projected := []db.ProductBalance{{ProductID: productID, Qty: actualQty, LastMovementAt: &occurredAt}}

	report := compareBalances(uuid.New(), canonical, projected)
	if report.Consistent {
		t.Fatal("compareBalances() Consistent = true for corrupted quantity")
	}
	if report.CheckedProducts != 1 || len(report.Mismatches) != 1 {
		t.Fatalf("report = %#v, want one checked product and one mismatch", report)
	}
	mismatch := report.Mismatches[0]
	if mismatch.Kind != MismatchQuantity || mismatch.ExpectedQty != 7 || mismatch.ActualQty == nil || *mismatch.ActualQty != 6 {
		t.Fatalf("mismatch = %#v, want quantity mismatch expected 7/actual 6", mismatch)
	}
}

func TestMovementServiceMapsPostgresDomainConstraints(t *testing.T) {
	tests := []struct {
		name       string
		constraint string
		want       error
	}{
		{name: "zero delta", constraint: "stock_movements_delta_nonzero_check", want: ErrInvalidDelta},
		{name: "kind", constraint: "stock_movements_kind_check", want: ErrInvalidKind},
		{name: "ownership", constraint: "stock_movements_product_owner_fkey", want: ErrOwnershipViolation},
		{name: "reversal target", constraint: "stock_movements_reverses_id_fkey", want: ErrInvalidReversal},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := mapMovementError(&pgconn.PgError{ConstraintName: tt.constraint})
			if !errors.Is(err, tt.want) {
				t.Fatalf("mapped error = %v, want %v", err, tt.want)
			}
		})
	}
}

type scriptedBeginner struct {
	tx         *scriptedTx
	beginCalls int
}

func (b *scriptedBeginner) BeginTx(context.Context) (db.Tx, error) {
	b.beginCalls++
	return b.tx, nil
}

type scriptedTx struct {
	rows          []pgx.Row
	rowIndex      int
	commitCalls   int
	rollbackCalls int
}

func (tx *scriptedTx) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}

func (tx *scriptedTx) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, errors.New("unexpected query in scripted transaction")
}

func (tx *scriptedTx) QueryRow(context.Context, string, ...any) pgx.Row {
	if tx.rowIndex >= len(tx.rows) {
		return staticRow{err: errors.New("unexpected query row")}
	}
	row := tx.rows[tx.rowIndex]
	tx.rowIndex++
	return row
}

func (tx *scriptedTx) Commit(context.Context) error {
	tx.commitCalls++
	return nil
}

func (tx *scriptedTx) Rollback(context.Context) error {
	tx.rollbackCalls++
	return nil
}

type staticRow struct {
	values []any
	err    error
}

func (r staticRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if len(dest) != len(r.values) {
		return fmt.Errorf("scan destinations = %d, values = %d", len(dest), len(r.values))
	}
	for i := range dest {
		destination := reflect.ValueOf(dest[i])
		if destination.Kind() != reflect.Pointer || destination.IsNil() {
			return fmt.Errorf("destination %d is not a non-nil pointer", i)
		}
		target := destination.Elem()
		if r.values[i] == nil {
			target.Set(reflect.Zero(target.Type()))
			continue
		}
		source := reflect.ValueOf(r.values[i])
		if source.Type().AssignableTo(target.Type()) {
			target.Set(source)
			continue
		}
		if source.Type().ConvertibleTo(target.Type()) {
			target.Set(source.Convert(target.Type()))
			continue
		}
		return fmt.Errorf("value %d has type %s, destination has type %s", i, source.Type(), target.Type())
	}
	return nil
}

func productRow(productID, userID, deviceID uuid.UUID) pgx.Row {
	now := time.Date(2026, time.February, 1, 0, 0, 0, 0, time.UTC)
	return staticRow{values: []any{
		uuidArg(productID), uuidArg(userID), pgtype.Text{}, pgtype.Text{}, "Test product",
		pgtype.Text{}, "pcs", pgtype.Text{}, pgtype.Int4{}, int64(1), now,
		uuidArg(deviceID), pgtype.Timestamptz{}, now,
	}}
}

func movementRow(movementID, userID, productID, deviceID uuid.UUID, delta int32, kind string, occurredAt time.Time) pgx.Row {
	return staticRow{values: []any{
		uuidArg(movementID), uuidArg(userID), uuidArg(productID), delta, kind,
		pgtype.Text{}, occurredAt, occurredAt, int64(0), pgtype.Int4{}, pgtype.UUID{},
		uuidArg(deviceID), occurredAt.Add(time.Minute),
	}}
}

func movementRowWithCounted(movementID, userID, productID, deviceID uuid.UUID, delta int32, kind string, occurredAt time.Time, countedQty int32) pgx.Row {
	return staticRow{values: []any{
		uuidArg(movementID), uuidArg(userID), uuidArg(productID), delta, kind,
		pgtype.Text{}, occurredAt, occurredAt, int64(0),
		pgtype.Int4{Int32: countedQty, Valid: true}, pgtype.UUID{},
		uuidArg(deviceID), occurredAt.Add(time.Minute),
	}}
}

func balanceRow(productID uuid.UUID, qty int64, occurredAt time.Time) pgx.Row {
	return staticRow{values: []any{
		uuidArg(productID), qty, pgtype.Timestamptz{Time: occurredAt, Valid: true}, occurredAt.Add(time.Minute),
	}}
}

func uuidArg(value uuid.UUID) pgtype.UUID {
	return pgtype.UUID{Bytes: value, Valid: true}
}
