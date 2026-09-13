package sync

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
	"github.com/stoksync/stoksync/server/internal/movements"
	"github.com/stoksync/stoksync/server/internal/products"
)

func TestServiceAppliesSupportedOperationsAndPersistsExactResults(t *testing.T) {
	t.Parallel()

	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}
	occurredAt := time.Date(2026, time.July, 8, 9, 10, 11, 0, time.UTC)
	productID := uuid.New()
	movementID := uuid.New()
	cases := []struct {
		name          string
		operation     Operation
		rows          []pgx.Row
		wantEntity    string
		wantChangeOp  string
		wantEntityID  uuid.UUID
		wantResultSeq int64
	}{
		{
			name: "add movement",
			operation: Operation{
				OpID: uuid.New(), Op: OperationAddMovement,
				Payload: mustJSON(t, AddMovementPayload{
					ID: movementID, ProductID: productID, Delta: 5, Kind: "receive",
					OccurredAt: occurredAt, RawOccurredAt: &occurredAt, DeviceID: &identity.DeviceID,
				}),
			},
			rows: []pgx.Row{
				syncOperationRow(identity, uuid.New(), "processing", []byte(`{}`)),
				syncProductRow(productID, identity.UserID, identity.DeviceID, 1, nil),
				syncMovementRow(movementID, identity.UserID, productID, identity.DeviceID, 5, "receive", occurredAt),
				syncBalanceRow(productID, 5, occurredAt),
				syncSequenceRow(101),
				syncChangeRow(101, identity.UserID, "stock_movement", movementID, "upsert", []byte(`{"id":"movement"}`), identity.DeviceID, occurredAt),
				syncOperationRow(identity, uuid.New(), ResultStatusApplied, []byte(`{"status":"applied"}`)),
			},
			wantEntity: "stock_movement", wantChangeOp: "upsert", wantEntityID: movementID, wantResultSeq: 101,
		},
		{
			name: "upsert product create",
			operation: Operation{
				OpID: uuid.New(), Op: OperationUpsertProduct,
				Payload: mustJSON(t, UpsertProductPayload{ID: productID, Name: "Created product", Unit: "pcs"}),
			},
			rows: []pgx.Row{
				syncOperationRow(identity, uuid.New(), "processing", []byte(`{}`)),
				syncErrorRow(pgx.ErrNoRows),
				syncProductRow(productID, identity.UserID, identity.DeviceID, 1, nil),
				syncBalanceRow(productID, 0, occurredAt),
				syncSequenceRow(102),
				syncChangeRow(102, identity.UserID, "product", productID, "upsert", []byte(`{"id":"product"}`), identity.DeviceID, occurredAt),
				syncOperationRow(identity, uuid.New(), ResultStatusApplied, []byte(`{"status":"applied"}`)),
			},
			wantEntity: "product", wantChangeOp: "upsert", wantEntityID: productID, wantResultSeq: 102,
		},
		{
			name: "upsert product update",
			operation: Operation{
				OpID: uuid.New(), Op: OperationUpsertProduct, BaseVersion: int64Pointer(1),
				Payload: mustJSON(t, UpsertProductPayload{ID: productID, Name: "Updated product", Unit: "pcs"}),
			},
			rows: []pgx.Row{
				syncOperationRow(identity, uuid.New(), "processing", []byte(`{}`)),
				syncProductRow(productID, identity.UserID, identity.DeviceID, 1, nil),
				syncProductRow(productID, identity.UserID, identity.DeviceID, 2, nil),
				syncSequenceRow(103),
				syncChangeRow(103, identity.UserID, "product", productID, "upsert", []byte(`{"id":"product"}`), identity.DeviceID, occurredAt),
				syncOperationRow(identity, uuid.New(), ResultStatusApplied, []byte(`{"status":"applied"}`)),
			},
			wantEntity: "product", wantChangeOp: "upsert", wantEntityID: productID, wantResultSeq: 103,
		},
		{
			name: "delete product",
			operation: Operation{
				OpID: uuid.New(), Op: OperationDeleteProduct, BaseVersion: int64Pointer(1),
				Payload: mustJSON(t, DeleteProductPayload{ID: productID}),
			},
			rows: []pgx.Row{
				syncOperationRow(identity, uuid.New(), "processing", []byte(`{}`)),
				syncProductRow(productID, identity.UserID, identity.DeviceID, 2, syncTimePointer(occurredAt.Add(time.Minute))),
				syncSequenceRow(104),
				syncChangeRow(104, identity.UserID, "product", productID, "delete", []byte(`{"id":"product"}`), identity.DeviceID, occurredAt),
				syncOperationRow(identity, uuid.New(), ResultStatusApplied, []byte(`{"status":"applied"}`)),
			},
			wantEntity: "product", wantChangeOp: "delete", wantEntityID: productID, wantResultSeq: 104,
		},
	}

	for _, testCase := range cases {
		testCase := testCase
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			tx := &syncScriptedTx{rows: testCase.rows}
			service := newScriptedSyncService(t, tx)
			result, err := service.ProcessOperation(context.Background(), identity, testCase.operation)
			if err != nil {
				t.Fatalf("ProcessOperation() error = %v", err)
			}
			if result.Status != ResultStatusApplied || result.OpID != testCase.operation.OpID || result.Seq == nil || *result.Seq != testCase.wantResultSeq {
				t.Fatalf("result = %#v, want applied op %s seq %d", result, testCase.operation.OpID, testCase.wantResultSeq)
			}
			if tx.commitCalls != 1 || tx.rollbackCalls != 0 {
				t.Fatalf("transaction lifecycle = (commit %d, rollback %d), want (1, 0)", tx.commitCalls, tx.rollbackCalls)
			}
			assertSyncOperationStatementOrder(t, tx)
			assertStoredOperationResult(t, tx, result)
			assertChangeStatement(t, tx, testCase.wantEntity, testCase.wantChangeOp, testCase.wantEntityID)
		})
	}
}

func TestServicePersistsStableOwnershipRejectionWithoutChangeLog(t *testing.T) {
	t.Parallel()

	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}
	otherUserID := uuid.New()
	productID := uuid.New()
	operation := Operation{
		OpID: uuid.New(), Op: OperationAddMovement,
		Payload: mustJSON(t, AddMovementPayload{
			ID: uuid.New(), ProductID: productID, Delta: -2, Kind: "issue",
			OccurredAt: time.Now().UTC(),
		}),
	}
	tx := &syncScriptedTx{rows: []pgx.Row{
		syncOperationRow(identity, uuid.New(), "processing", []byte(`{}`)),
		syncErrorRow(pgx.ErrNoRows),
		syncProductRow(productID, otherUserID, uuid.New(), 1, nil),
		syncOperationRow(identity, uuid.New(), ResultStatusRejected, []byte(`{"status":"rejected"}`)),
	}}
	service := newScriptedSyncService(t, tx)

	result, err := service.ProcessOperation(context.Background(), identity, operation)
	if err != nil {
		t.Fatalf("ProcessOperation() error = %v", err)
	}
	if result.Status != ResultStatusRejected || result.Reason != ReasonOwnershipViolation {
		t.Fatalf("result = %#v, want stable ownership rejection", result)
	}
	if tx.commitCalls != 1 || tx.rollbackCalls != 0 {
		t.Fatalf("transaction lifecycle = (commit %d, rollback %d), want rejected outcome commit", tx.commitCalls, tx.rollbackCalls)
	}
	for _, query := range tx.queries {
		if strings.Contains(query, "INSERT INTO change_log") {
			t.Fatal("ownership rejection inserted a change-log row")
		}
	}
	assertStoredOperationResult(t, tx, result)
}

func TestServiceRollsBackDomainAndReservedOutcomeWhenChangeLogFails(t *testing.T) {
	t.Parallel()

	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}
	productID := uuid.New()
	occurredAt := time.Date(2026, time.August, 1, 2, 3, 4, 0, time.UTC)
	operation := Operation{
		OpID: uuid.New(), Op: OperationAddMovement,
		Payload: mustJSON(t, AddMovementPayload{
			ID: uuid.New(), ProductID: productID, Delta: 4, Kind: "receive",
			OccurredAt: occurredAt,
		}),
	}
	tx := &syncScriptedTx{rows: []pgx.Row{
		syncOperationRow(identity, uuid.New(), "processing", []byte(`{}`)),
		syncProductRow(productID, identity.UserID, identity.DeviceID, 1, nil),
		syncMovementRow(uuid.New(), identity.UserID, productID, identity.DeviceID, 4, "receive", occurredAt),
		syncBalanceRow(productID, 4, occurredAt),
		syncErrorRow(errors.New("change sequence allocation failed")),
	}}
	service := newScriptedSyncService(t, tx)

	if _, err := service.ProcessOperation(context.Background(), identity, operation); err == nil {
		t.Fatal("ProcessOperation() error = nil, want change-log failure")
	}
	if tx.commitCalls != 0 || tx.rollbackCalls != 1 {
		t.Fatalf("transaction lifecycle = (commit %d, rollback %d), want rollback", tx.commitCalls, tx.rollbackCalls)
	}
	for _, query := range tx.queries {
		if strings.Contains(query, "UPDATE sync_ops") {
			t.Fatal("failed change-log transaction finalized the reserved sync outcome")
		}
	}
}

func TestServiceDetectsDuplicateBeforeDomainApplication(t *testing.T) {
	t.Parallel()

	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}
	operation := Operation{
		OpID: uuid.New(), Op: OperationDeleteProduct, BaseVersion: int64Pointer(1),
		Payload: mustJSON(t, DeleteProductPayload{ID: uuid.New()}),
	}
	tx := &syncScriptedTx{rows: []pgx.Row{syncErrorRow(pgx.ErrNoRows)}}
	service := newScriptedSyncService(t, tx)

	result, err := service.ProcessOperation(context.Background(), identity, operation)
	if err != nil {
		t.Fatalf("ProcessOperation() error = %v", err)
	}
	if result.Status != ResultStatusRejected || result.Reason != ReasonDuplicateOperation {
		t.Fatalf("result = %#v, want duplicate-operation seam rejection", result)
	}
	if tx.commitCalls != 0 || tx.rollbackCalls != 1 {
		t.Fatalf("transaction lifecycle = (commit %d, rollback %d), want rollback without replay", tx.commitCalls, tx.rollbackCalls)
	}
	if len(tx.queries) != 1 || !strings.Contains(tx.queries[0], "INSERT INTO sync_ops") {
		t.Fatalf("queries = %#v, want only atomic idempotency reservation", tx.queries)
	}
}

func TestRejectedForDomainErrorUsesStableReasons(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want string
	}{
		{name: "barcode", err: products.ErrBarcodeConflict, want: ReasonBarcodeConflict},
		{name: "version", err: products.ErrVersionConflict, want: ReasonVersionConflict},
		{name: "product deleted", err: products.ErrProductDeleted, want: ReasonProductDeleted},
		{name: "movement delta", err: movements.ErrInvalidDelta, want: ReasonInvalidDelta},
		{name: "movement kind", err: movements.ErrInvalidKind, want: ReasonInvalidMovementKind},
		{name: "movement target", err: movements.ErrMovementNotFound, want: ReasonMovementNotFound},
		{name: "stocktake", err: movements.ErrInvalidStocktake, want: ReasonInvalidStocktake},
	}
	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			result, ok := rejectedForDomainError(uuid.New(), testCase.err)
			if !ok || result.Reason != testCase.want || result.Status != ResultStatusRejected {
				t.Fatalf("result = %#v, classified = %v, want reason %q", result, ok, testCase.want)
			}
		})
	}
}

func newScriptedSyncService(t *testing.T, tx *syncScriptedTx) *Service {
	t.Helper()
	service, err := NewService(&syncScriptedBeginner{tx: tx})
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	service.now = func() time.Time { return time.Date(2026, time.August, 2, 3, 4, 5, 0, time.UTC) }
	return service
}

func assertSyncOperationStatementOrder(t *testing.T, tx *syncScriptedTx) {
	t.Helper()
	if len(tx.queries) < 3 || !strings.Contains(tx.queries[0], "INSERT INTO sync_ops") {
		t.Fatalf("first queries = %#v, want idempotency reservation first", tx.queries)
	}
	var changeIndex, updateIndex = -1, -1
	for index, query := range tx.queries {
		if strings.Contains(query, "INSERT INTO change_log") {
			changeIndex = index
		}
		if strings.Contains(query, "UPDATE sync_ops") {
			updateIndex = index
		}
	}
	if changeIndex < 0 || updateIndex < 0 || changeIndex >= updateIndex {
		t.Fatalf("queries = %#v, want change-log before final sync_ops update", tx.queries)
	}
}

func assertStoredOperationResult(t *testing.T, tx *syncScriptedTx, want OperationResult) {
	t.Helper()
	for index, query := range tx.queries {
		if !strings.Contains(query, "UPDATE sync_ops") {
			continue
		}
		if len(tx.args[index]) < 6 {
			t.Fatalf("sync_ops update args = %#v, want response at index 5", tx.args[index])
		}
		storedBytes, ok := tx.args[index][5].([]byte)
		if !ok {
			t.Fatalf("stored response type = %T, want []byte", tx.args[index][5])
		}
		var stored OperationResult
		if err := json.Unmarshal(storedBytes, &stored); err != nil {
			t.Fatalf("decode stored operation response: %v", err)
		}
		if !reflect.DeepEqual(stored, want) {
			t.Fatalf("stored result = %#v, want exact result %#v", stored, want)
		}
		return
	}
	t.Fatalf("queries = %#v, want final sync_ops update", tx.queries)
}

func assertChangeStatement(t *testing.T, tx *syncScriptedTx, wantEntity, wantOp string, wantID uuid.UUID) {
	t.Helper()
	for index, query := range tx.queries {
		if !strings.Contains(query, "INSERT INTO change_log") {
			continue
		}
		args := tx.args[index]
		if len(args) < 7 || args[2] != wantEntity || args[4] != wantOp {
			t.Fatalf("change-log args = %#v, want entity %q op %q", args, wantEntity, wantOp)
		}
		entityID, ok := args[3].(pgtype.UUID)
		if !ok || uuid.UUID(entityID.Bytes) != wantID {
			t.Fatalf("change-log entity id = %#v, want %s", args[3], wantID)
		}
		if _, ok := args[5].([]byte); !ok {
			t.Fatalf("change-log payload type = %T, want []byte", args[5])
		}
		return
	}
	t.Fatalf("queries = %#v, want change-log insert", tx.queries)
}

type syncScriptedBeginner struct {
	tx *syncScriptedTx
}

func (b *syncScriptedBeginner) BeginTx(context.Context) (db.Tx, error) {
	return b.tx, nil
}

type syncScriptedTx struct {
	rows          []pgx.Row
	queries       []string
	args          [][]any
	commitCalls   int
	rollbackCalls int
}

func (tx *syncScriptedTx) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}

func (tx *syncScriptedTx) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, errors.New("unexpected query")
}

func (tx *syncScriptedTx) QueryRow(_ context.Context, query string, args ...any) pgx.Row {
	tx.queries = append(tx.queries, query)
	tx.args = append(tx.args, args)
	if len(tx.rows) == 0 {
		return syncErrorRow(errors.New("unexpected query row"))
	}
	row := tx.rows[0]
	tx.rows = tx.rows[1:]
	return row
}

func (tx *syncScriptedTx) Commit(context.Context) error {
	tx.commitCalls++
	return nil
}

func (tx *syncScriptedTx) Rollback(context.Context) error {
	tx.rollbackCalls++
	return nil
}

type syncStaticRow struct {
	values []any
	err    error
}

func (r syncStaticRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if len(dest) != len(r.values) {
		return fmt.Errorf("scan destinations = %d, values = %d", len(dest), len(r.values))
	}
	for index, value := range r.values {
		destination := reflect.ValueOf(dest[index])
		if destination.Kind() != reflect.Pointer || destination.IsNil() {
			return fmt.Errorf("destination %d is not a non-nil pointer", index)
		}
		target := destination.Elem()
		if value == nil {
			target.Set(reflect.Zero(target.Type()))
			continue
		}
		source := reflect.ValueOf(value)
		if source.Type().AssignableTo(target.Type()) {
			target.Set(source)
			continue
		}
		if source.Type().ConvertibleTo(target.Type()) {
			target.Set(source.Convert(target.Type()))
			continue
		}
		return fmt.Errorf("value %d has type %s, destination has type %s", index, source.Type(), target.Type())
	}
	return nil
}

func syncErrorRow(err error) pgx.Row {
	return syncStaticRow{err: err}
}

func syncOperationRow(identity auth.Identity, operationID uuid.UUID, status string, response []byte) pgx.Row {
	now := time.Date(2026, time.July, 8, 9, 10, 11, 0, time.UTC)
	return syncStaticRow{values: []any{
		syncUUIDArg(identity.DeviceID), syncUUIDArg(operationID), syncUUIDArg(identity.UserID), status,
		pgtype.Text{}, response, now, pgtype.Timestamptz{},
	}}
}

func syncProductRow(productID, userID, deviceID uuid.UUID, version int64, deletedAt *time.Time) pgx.Row {
	now := time.Date(2026, time.July, 8, 9, 10, 11, 0, time.UTC)
	deleted := pgtype.Timestamptz{}
	if deletedAt != nil {
		deleted = pgtype.Timestamptz{Time: deletedAt.UTC(), Valid: true}
	}
	return syncStaticRow{values: []any{
		syncUUIDArg(productID), syncUUIDArg(userID), pgtype.Text{}, pgtype.Text{}, "Test product",
		pgtype.Text{}, "pcs", pgtype.Text{}, pgtype.Int4{}, version, now,
		syncUUIDArg(deviceID), deleted, now,
	}}
}

func syncMovementRow(movementID, userID, productID, deviceID uuid.UUID, delta int32, kind string, occurredAt time.Time) pgx.Row {
	return syncStaticRow{values: []any{
		syncUUIDArg(movementID), syncUUIDArg(userID), syncUUIDArg(productID), delta, kind,
		pgtype.Text{}, occurredAt, occurredAt, int64(0), pgtype.Int4{}, pgtype.UUID{},
		syncUUIDArg(deviceID), occurredAt.Add(time.Minute),
	}}
}

func syncBalanceRow(productID uuid.UUID, qty int64, occurredAt time.Time) pgx.Row {
	return syncStaticRow{values: []any{
		syncUUIDArg(productID), qty, pgtype.Timestamptz{Time: occurredAt, Valid: true}, occurredAt.Add(time.Minute),
	}}
}

func syncSequenceRow(sequence int64) pgx.Row {
	return syncStaticRow{values: []any{sequence}}
}

func syncChangeRow(sequence int64, userID uuid.UUID, entity string, entityID uuid.UUID, op string, payload []byte, deviceID uuid.UUID, createdAt time.Time) pgx.Row {
	return syncStaticRow{values: []any{
		sequence, syncUUIDArg(userID), entity, syncUUIDArg(entityID), op, payload, syncUUIDArg(deviceID), createdAt,
	}}
}

func syncUUIDArg(value uuid.UUID) pgtype.UUID {
	return pgtype.UUID{Bytes: value, Valid: true}
}

func syncTimePointer(value time.Time) *time.Time {
	return &value
}

func TestServiceRejectsPayloadDeviceMismatchBeforeDomainWrite(t *testing.T) {
	t.Parallel()

	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}
	payloadDeviceID := uuid.New()
	operation := Operation{
		OpID: uuid.New(), Op: OperationAddMovement,
		Payload: mustJSON(t, AddMovementPayload{
			ID: uuid.New(), ProductID: uuid.New(), Delta: 1, Kind: "receive",
			OccurredAt: time.Now().UTC(), DeviceID: &payloadDeviceID,
		}),
	}
	tx := &syncScriptedTx{rows: []pgx.Row{
		syncOperationRow(identity, uuid.New(), "processing", []byte(`{}`)),
		syncOperationRow(identity, uuid.New(), ResultStatusRejected, []byte(`{"status":"rejected"}`)),
	}}
	service := newScriptedSyncService(t, tx)

	result, err := service.ProcessOperation(context.Background(), identity, operation)
	if err != nil {
		t.Fatalf("ProcessOperation() error = %v", err)
	}
	if result.Status != ResultStatusRejected || result.Reason != ReasonDeviceMismatch {
		t.Fatalf("result = %#v, want device mismatch rejection", result)
	}
	if len(tx.queries) != 2 || tx.commitCalls != 1 || tx.rollbackCalls != 0 {
		t.Fatalf("queries/lifecycle = (%d, %d, %d), want reservation/finalization and commit", len(tx.queries), tx.commitCalls, tx.rollbackCalls)
	}
	assertStoredOperationResult(t, tx, result)
}
