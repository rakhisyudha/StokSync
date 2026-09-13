package db

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

func TestGetProductMapsCanonicalAndNullableFields(t *testing.T) {
	t.Parallel()

	productID := uuid.MustParse("00000000-0000-4000-8000-000000000001")
	userID := uuid.MustParse("00000000-0000-4000-8000-000000000002")
	deviceID := uuid.MustParse("00000000-0000-4000-8000-000000000003")
	updatedAt := time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC)
	createdAt := updatedAt.Add(-time.Hour)
	deletedAt := updatedAt.Add(time.Hour)

	fake := &fakeQueryDB{row: staticRow{values: []any{
		uuidArg(productID),
		uuidArg(userID),
		pgtype.Text{String: "089686010947", Valid: true},
		pgtype.Text{},
		"Indomie Goreng",
		pgtype.Text{String: "fried noodles", Valid: true},
		"pcs",
		pgtype.Text{String: "food", Valid: true},
		pgtype.Int4{Int32: 24, Valid: true},
		int64(7),
		updatedAt,
		uuidArg(deviceID),
		pgtype.Timestamptz{Time: deletedAt, Valid: true},
		createdAt,
	}}}

	product, err := NewQueries(fake).GetProduct(context.Background(), userID, productID)
	if err != nil {
		t.Fatalf("GetProduct() error = %v", err)
	}
	if product.ID != productID || product.UserID != userID || product.UpdatedByDeviceID != deviceID {
		t.Errorf("mapped IDs = (%s, %s, %s), want product/user/device IDs", product.ID, product.UserID, product.UpdatedByDeviceID)
	}
	if product.Name != "Indomie Goreng" || product.Unit != "pcs" || product.Version != 7 {
		t.Errorf("mapped required fields = (%q, %q, %d), want product values", product.Name, product.Unit, product.Version)
	}
	if product.Barcode == nil || *product.Barcode != "089686010947" {
		t.Errorf("Barcode = %v, want scanned barcode", product.Barcode)
	}
	if product.SKU != nil {
		t.Errorf("SKU = %v, want nil", product.SKU)
	}
	if product.MinStock == nil || *product.MinStock != 24 {
		t.Errorf("MinStock = %v, want 24", product.MinStock)
	}
	if product.DeletedAt == nil || !product.DeletedAt.Equal(deletedAt) {
		t.Errorf("DeletedAt = %v, want %s", product.DeletedAt, deletedAt)
	}
	if !strings.Contains(fake.lastQuery, "WHERE user_id = $1 AND id = $2") {
		t.Error("GetProduct query does not contain the ownership predicate")
	}
	assertUUIDArg(t, fake.lastArgs[0], userID)
	assertUUIDArg(t, fake.lastArgs[1], productID)
}

func TestGetStockMovementMapsImmutableLedgerFields(t *testing.T) {
	t.Parallel()

	movementID := uuid.MustParse("00000000-0000-4000-8000-000000000011")
	userID := uuid.MustParse("00000000-0000-4000-8000-000000000012")
	productID := uuid.MustParse("00000000-0000-4000-8000-000000000013")
	deviceID := uuid.MustParse("00000000-0000-4000-8000-000000000014")
	reversesID := uuid.MustParse("00000000-0000-4000-8000-000000000015")
	occurredAt := time.Date(2026, time.March, 4, 5, 6, 7, 0, time.UTC)
	serverCreatedAt := occurredAt.Add(time.Minute)

	fake := &fakeQueryDB{row: staticRow{values: []any{
		uuidArg(movementID),
		uuidArg(userID),
		uuidArg(productID),
		int32(-3),
		"issue",
		pgtype.Text{String: "sold", Valid: true},
		occurredAt,
		occurredAt.Add(-time.Second),
		int64(125),
		pgtype.Int4{Int32: 0, Valid: true},
		uuidArg(reversesID),
		uuidArg(deviceID),
		serverCreatedAt,
	}}}

	movement, err := NewQueries(fake).GetStockMovement(context.Background(), userID, movementID)
	if err != nil {
		t.Fatalf("GetStockMovement() error = %v", err)
	}
	if movement.ID != movementID || movement.UserID != userID || movement.ProductID != productID || movement.DeviceID != deviceID {
		t.Error("movement ID ownership mapping is incorrect")
	}
	if movement.Delta != -3 || movement.Kind != "issue" || movement.ClockOffsetMs != 125 {
		t.Errorf("movement scalar mapping = (%d, %q, %d), want (-3, issue, 125)", movement.Delta, movement.Kind, movement.ClockOffsetMs)
	}
	if movement.Note == nil || *movement.Note != "sold" {
		t.Errorf("Note = %v, want sold", movement.Note)
	}
	if movement.CountedQty == nil || *movement.CountedQty != 0 {
		t.Errorf("CountedQty = %v, want 0", movement.CountedQty)
	}
	if movement.ReversesID == nil || *movement.ReversesID != reversesID {
		t.Errorf("ReversesID = %v, want %s", movement.ReversesID, reversesID)
	}
	if !strings.Contains(fake.lastQuery, "WHERE user_id = $1 AND id = $2") {
		t.Error("GetStockMovement query does not contain the ownership predicate")
	}
}

func TestTryInsertSyncOperationReturnsDuplicateWithoutApplyingIt(t *testing.T) {
	t.Parallel()

	userID := uuid.MustParse("00000000-0000-4000-8000-000000000021")
	deviceID := uuid.MustParse("00000000-0000-4000-8000-000000000022")
	opID := uuid.MustParse("00000000-0000-4000-8000-000000000023")
	fake := &fakeQueryDB{row: staticRow{err: pgx.ErrNoRows}}

	operation, inserted, err := NewQueries(fake).TryInsertSyncOperation(context.Background(), InsertSyncOperationParams{
		UserID:   userID,
		DeviceID: deviceID,
		OpID:     opID,
		Status:   "applied",
		Response: []byte(`{"status":"applied"}`),
	})
	if err != nil {
		t.Fatalf("TryInsertSyncOperation() error = %v", err)
	}
	if inserted {
		t.Fatal("TryInsertSyncOperation() inserted = true for duplicate")
	}
	if operation.Response != nil {
		t.Errorf("duplicate operation = %#v, want zero value", operation)
	}
	if !strings.Contains(fake.lastQuery, "ON CONFLICT (device_id, op_id) DO NOTHING") {
		t.Error("sync operation query does not use composite idempotency conflict handling")
	}
	assertUUIDArg(t, fake.lastArgs[0], userID)
	assertUUIDArg(t, fake.lastArgs[1], deviceID)
	assertUUIDArg(t, fake.lastArgs[2], opID)
}

func TestTryInsertSyncOperationMapsStoredResponse(t *testing.T) {
	t.Parallel()

	userID := uuid.MustParse("00000000-0000-4000-8000-000000000031")
	deviceID := uuid.MustParse("00000000-0000-4000-8000-000000000032")
	opID := uuid.MustParse("00000000-0000-4000-8000-000000000033")
	receivedAt := time.Date(2026, time.April, 5, 6, 7, 8, 0, time.UTC)
	completedAt := receivedAt.Add(time.Second)
	response := []byte(`{"op_id":"00000000-0000-4000-8000-000000000033","status":"applied"}`)
	fake := &fakeQueryDB{row: staticRow{values: []any{
		uuidArg(deviceID),
		uuidArg(opID),
		uuidArg(userID),
		"applied",
		pgtype.Text{},
		response,
		receivedAt,
		pgtype.Timestamptz{Time: completedAt, Valid: true},
	}}}

	operation, inserted, err := NewQueries(fake).TryInsertSyncOperation(context.Background(), InsertSyncOperationParams{
		UserID:   userID,
		DeviceID: deviceID,
		OpID:     opID,
		Status:   "applied",
		Response: response,
	})
	if err != nil {
		t.Fatalf("TryInsertSyncOperation() error = %v", err)
	}
	if !inserted {
		t.Fatal("TryInsertSyncOperation() inserted = false for returned row")
	}
	if !reflect.DeepEqual(operation.Response, response) {
		t.Errorf("Response = %s, want %s", operation.Response, response)
	}
	if operation.CompletedAt == nil || !operation.CompletedAt.Equal(completedAt) {
		t.Errorf("CompletedAt = %v, want %s", operation.CompletedAt, completedAt)
	}
}

func TestAppendChangeLogAllocatesBeforeInserting(t *testing.T) {
	t.Parallel()

	sequence := int64(42)
	userID := uuid.MustParse("00000000-0000-4000-8000-000000000041")
	entityID := uuid.MustParse("00000000-0000-4000-8000-000000000042")
	deviceID := uuid.MustParse("00000000-0000-4000-8000-000000000043")
	createdAt := time.Date(2026, time.May, 6, 7, 8, 9, 0, time.UTC)
	payload := []byte(`{"id":"00000000-0000-4000-8000-000000000042"}`)
	fake := &orderedQueryDB{rows: []pgx.Row{
		staticRow{values: []any{sequence}},
		staticRow{values: []any{
			sequence,
			uuidArg(userID),
			"product",
			uuidArg(entityID),
			"upsert",
			payload,
			uuidArg(deviceID),
			createdAt,
		}},
	}}

	entry, err := NewQueries(fake).AppendChangeLog(context.Background(), AppendChangeLogParams{
		UserID:         userID,
		Entity:         "product",
		EntityID:       entityID,
		Op:             "upsert",
		Payload:        payload,
		OriginDeviceID: &deviceID,
	})
	if err != nil {
		t.Fatalf("AppendChangeLog() error = %v", err)
	}
	if entry.Seq != sequence || entry.UserID != userID || entry.EntityID != entityID {
		t.Fatalf("entry = %#v, want sequence %d and event IDs", entry, sequence)
	}
	if len(fake.queries) != 2 {
		t.Fatalf("executed queries = %d, want allocator followed by insert", len(fake.queries))
	}
	if !strings.Contains(fake.queries[0], "UPDATE sync_seq_counter") {
		t.Errorf("first query = %q, want sync_seq_counter update", fake.queries[0])
	}
	if !strings.Contains(fake.queries[1], "INSERT INTO change_log") {
		t.Errorf("second query = %q, want change_log insert", fake.queries[1])
	}
}

func TestListChangeLogRejectsUnboundedRequest(t *testing.T) {
	t.Parallel()

	fake := &fakeQueryDB{}
	_, err := NewQueries(fake).ListChangeLog(context.Background(), ListChangeLogParams{MaxChanges: 0})
	if err == nil {
		t.Fatal("ListChangeLog() error = nil, want validation error")
	}
	if fake.queryCalls != 0 {
		t.Error("ListChangeLog() executed SQL for an invalid limit")
	}
}

type orderedQueryDB struct {
	rows    []pgx.Row
	queries []string
}

func (f *orderedQueryDB) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}

func (f *orderedQueryDB) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, nil
}

func (f *orderedQueryDB) QueryRow(_ context.Context, query string, _ ...any) pgx.Row {
	f.queries = append(f.queries, query)
	if len(f.rows) == 0 {
		return staticRow{err: fmt.Errorf("unexpected query row")}
	}
	row := f.rows[0]
	f.rows = f.rows[1:]
	return row
}

type fakeQueryDB struct {
	row        pgx.Row
	queryErr   error
	lastQuery  string
	lastArgs   []any
	queryCalls int
}

func (f *fakeQueryDB) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}

func (f *fakeQueryDB) Query(_ context.Context, query string, args ...any) (pgx.Rows, error) {
	f.queryCalls++
	f.lastQuery = query
	f.lastArgs = args
	return nil, f.queryErr
}

func (f *fakeQueryDB) QueryRow(_ context.Context, query string, args ...any) pgx.Row {
	f.lastQuery = query
	f.lastArgs = args
	return f.row
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

func assertUUIDArg(t *testing.T, value any, want uuid.UUID) {
	t.Helper()
	got, ok := value.(pgtype.UUID)
	if !ok {
		t.Fatalf("argument type = %T, want pgtype.UUID", value)
	}
	if !got.Valid || uuid.UUID(got.Bytes) != want {
		t.Errorf("UUID argument = %#v, want %s", got, want)
	}
}
