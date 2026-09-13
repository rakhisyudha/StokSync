package db

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

func TestListSnapshotProductsIncludesTombstonesAndDetectsBounds(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	activeID := uuid.New()
	deletedID := uuid.New()
	deviceID := uuid.New()
	now := time.Date(2026, time.July, 1, 2, 3, 4, 0, time.UTC)
	deletedAt := now.Add(time.Hour)
	fake := &snapshotQueryDB{rows: &snapshotRows{rows: []pgx.Row{
		snapshotProductRow(activeID, userID, deviceID, now, nil),
		snapshotProductRow(deletedID, userID, deviceID, now, &deletedAt),
	}}}

	products, truncated, err := NewQueries(fake).ListSnapshotProducts(context.Background(), userID, 1)
	if err != nil {
		t.Fatalf("ListSnapshotProducts() error = %v", err)
	}
	if !truncated || len(products) != 1 {
		t.Fatalf("products = %d, truncated = %t; want one returned row and truncation", len(products), truncated)
	}
	if products[0].ID != activeID {
		t.Errorf("first product id = %s, want %s", products[0].ID, activeID)
	}
	if !strings.Contains(fake.query, "WHERE user_id = $1") || !strings.Contains(fake.query, "LIMIT $2") {
		t.Fatalf("snapshot product query = %q, want account predicate and limit", fake.query)
	}
	assertUUIDArg(t, fake.args[0], userID)
	if got, ok := fake.args[1].(int32); !ok || got != 2 {
		t.Errorf("snapshot product limit argument = %#v, want int32(2)", fake.args[1])
	}
}

func TestListSnapshotMovementsMapsImmutableRowsAndUsesAccountLimit(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	productID := uuid.New()
	movementID := uuid.New()
	deviceID := uuid.New()
	occurredAt := time.Date(2026, time.August, 2, 3, 4, 5, 0, time.UTC)
	fake := &snapshotQueryDB{rows: &snapshotRows{rows: []pgx.Row{
		snapshotMovementRow(movementID, userID, productID, deviceID, occurredAt),
	}}}

	movements, truncated, err := NewQueries(fake).ListSnapshotMovements(context.Background(), userID, 10)
	if err != nil {
		t.Fatalf("ListSnapshotMovements() error = %v", err)
	}
	if truncated || len(movements) != 1 {
		t.Fatalf("movements = %d, truncated = %t, want one complete row", len(movements), truncated)
	}
	if movements[0].ID != movementID || movements[0].ProductID != productID || movements[0].Delta != -3 {
		t.Errorf("movement = %#v, want immutable movement fields", movements[0])
	}
	if !strings.Contains(fake.query, "WHERE user_id = $1") || !strings.Contains(fake.query, "ORDER BY product_id") {
		t.Errorf("snapshot movement query = %q, want account predicate and deterministic order", fake.query)
	}
}

func TestListSnapshotBalancesDerivesZeroAndNonZeroRows(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	firstProductID := uuid.New()
	secondProductID := uuid.New()
	lastMovementAt := time.Date(2026, time.September, 3, 4, 5, 6, 0, time.UTC)
	fake := &snapshotQueryDB{rows: &snapshotRows{rows: []pgx.Row{
		staticRow{values: []any{uuidArg(firstProductID), int64(7), pgtype.Timestamptz{Time: lastMovementAt, Valid: true}}},
		staticRow{values: []any{uuidArg(secondProductID), int64(0), pgtype.Timestamptz{}}},
	}}}

	balances, truncated, err := NewQueries(fake).ListSnapshotBalances(context.Background(), userID, 10)
	if err != nil {
		t.Fatalf("ListSnapshotBalances() error = %v", err)
	}
	if truncated || len(balances) != 2 {
		t.Fatalf("balances = %d, truncated = %t, want two product balances", len(balances), truncated)
	}
	if balances[0].ProductID != firstProductID || balances[0].Qty != 7 || balances[0].LastMovementAt == nil {
		t.Errorf("first balance = %#v, want ledger-derived quantity and timestamp", balances[0])
	}
	if balances[1].ProductID != secondProductID || balances[1].Qty != 0 || balances[1].LastMovementAt != nil {
		t.Errorf("second balance = %#v, want zero balance without movement timestamp", balances[1])
	}
	if !strings.Contains(fake.query, "LEFT JOIN stock_movements") || !strings.Contains(fake.query, "WHERE p.user_id = $1") {
		t.Errorf("snapshot balance query = %q, want ledger join and account predicate", fake.query)
	}
}

func TestCurrentDatabaseTimeUsesTheBoundQueryExecutor(t *testing.T) {
	t.Parallel()

	want := time.Date(2026, time.October, 4, 5, 6, 7, 0, time.FixedZone("test", 2*60*60))
	fake := &snapshotQueryDB{row: staticRow{values: []any{want}}}
	got, err := NewQueries(fake).CurrentDatabaseTime(context.Background())
	if err != nil {
		t.Fatalf("CurrentDatabaseTime() error = %v", err)
	}
	if !got.Equal(want.UTC()) || got.Location() != time.UTC {
		t.Errorf("database time = %s (%s), want UTC %s", got, got.Location(), want.UTC())
	}
	if strings.TrimSpace(fake.query) != "SELECT CURRENT_TIMESTAMP" {
		t.Errorf("database time query = %q, want CURRENT_TIMESTAMP", fake.query)
	}
}

type snapshotQueryDB struct {
	rows  pgx.Rows
	row   pgx.Row
	query string
	args  []any
}

func (f *snapshotQueryDB) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}

func (f *snapshotQueryDB) Query(_ context.Context, query string, args ...any) (pgx.Rows, error) {
	f.query = query
	f.args = args
	return f.rows, nil
}

func (f *snapshotQueryDB) QueryRow(_ context.Context, query string, args ...any) pgx.Row {
	f.query = query
	f.args = args
	return f.row
}

type snapshotRows struct {
	rows   []pgx.Row
	index  int
	closed bool
}

func (r *snapshotRows) Close() {
	r.closed = true
}

func (r *snapshotRows) Err() error {
	return nil
}

func (r *snapshotRows) CommandTag() pgconn.CommandTag {
	return pgconn.CommandTag{}
}

func (r *snapshotRows) FieldDescriptions() []pgconn.FieldDescription {
	return nil
}

func (r *snapshotRows) Next() bool {
	if r.index >= len(r.rows) {
		r.Close()
		return false
	}
	r.index++
	return true
}

func (r *snapshotRows) Scan(dest ...any) error {
	if r.index == 0 || r.index > len(r.rows) {
		return fmt.Errorf("scan called without a current row")
	}
	return r.rows[r.index-1].Scan(dest...)
}

func (r *snapshotRows) Values() ([]any, error) {
	return nil, nil
}

func (r *snapshotRows) RawValues() [][]byte {
	return nil
}

func (r *snapshotRows) Conn() *pgx.Conn {
	return nil
}

func snapshotProductRow(productID, userID, deviceID uuid.UUID, updatedAt time.Time, deletedAt *time.Time) pgx.Row {
	var deleted pgtype.Timestamptz
	if deletedAt != nil {
		deleted = pgtype.Timestamptz{Time: *deletedAt, Valid: true}
	}
	return staticRow{values: []any{
		uuidArg(productID), uuidArg(userID), pgtype.Text{}, pgtype.Text{}, "Snapshot product",
		pgtype.Text{}, "pcs", pgtype.Text{}, pgtype.Int4{}, int64(1), updatedAt,
		uuidArg(deviceID), deleted, updatedAt,
	}}
}

func snapshotMovementRow(movementID, userID, productID, deviceID uuid.UUID, occurredAt time.Time) pgx.Row {
	return staticRow{values: []any{
		uuidArg(movementID), uuidArg(userID), uuidArg(productID), int32(-3), "issue",
		pgtype.Text{}, occurredAt, occurredAt, int64(0), pgtype.Int4{}, pgtype.UUID{},
		uuidArg(deviceID), occurredAt.Add(time.Minute),
	}}
}
