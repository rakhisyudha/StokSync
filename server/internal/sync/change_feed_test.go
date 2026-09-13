package sync

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
)

func TestServiceListChangesReturnsEmptyPageAndPreservesCursor(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	transaction := &changeFeedTestTx{rows: &changeFeedRows{}}
	service := newChangeFeedTestService(t, transaction)

	feed, err := service.ListChanges(context.Background(), userID, 37, 2)
	if err != nil {
		t.Fatalf("ListChanges() error = %v", err)
	}
	if feed.Changes == nil || len(feed.Changes) != 0 {
		t.Fatalf("changes = %#v, want non-nil empty page", feed.Changes)
	}
	if feed.NextCursor != 37 || feed.HasMore {
		t.Fatalf("feed metadata = (next %d, has_more %t), want (37, false)", feed.NextCursor, feed.HasMore)
	}
	assertChangeFeedQuery(t, transaction, userID, 37, 3)
	if transaction.commitCalls != 1 || transaction.rollbackCalls != 0 {
		t.Fatalf("transaction lifecycle = (commit %d, rollback %d), want committed read", transaction.commitCalls, transaction.rollbackCalls)
	}
	if len(transaction.execQueries) != 1 || !strings.Contains(transaction.execQueries[0], "REPEATABLE READ") {
		t.Fatalf("transaction setup = %#v, want repeatable-read read-only transaction", transaction.execQueries)
	}
}

func TestServiceListChangesReturnsExactBoundaryWithoutMore(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	firstID := uuid.New()
	secondID := uuid.New()
	createdAt := time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC)
	transaction := &changeFeedTestTx{rows: &changeFeedRows{rows: []pgx.Row{
		syncChangeRow(41, userID, "product", firstID, "upsert", []byte(`{"id":"first"}`), uuid.New(), createdAt),
		syncChangeRow(42, userID, "stock_movement", secondID, "upsert", []byte(`{"id":"second"}`), uuid.New(), createdAt.Add(time.Second)),
	}}}
	service := newChangeFeedTestService(t, transaction)

	feed, err := service.ListChanges(context.Background(), userID, 40, 2)
	if err != nil {
		t.Fatalf("ListChanges() error = %v", err)
	}
	if len(feed.Changes) != 2 || feed.Changes[0].Seq != 41 || feed.Changes[1].Seq != 42 {
		t.Fatalf("changes = %#v, want exactly sequences [41 42]", feed.Changes)
	}
	if feed.NextCursor != 42 || feed.HasMore {
		t.Fatalf("feed metadata = (next %d, has_more %t), want (42, false)", feed.NextCursor, feed.HasMore)
	}
	if string(feed.Changes[0].Data) != `{"id":"first"}` || feed.Changes[1].Entity != "stock_movement" {
		t.Fatalf("mapped change data = %#v, want canonical payloads/entities", feed.Changes)
	}
	assertChangeFeedQuery(t, transaction, userID, 40, 3)
}

func TestServiceListChangesUsesLookaheadForMultiplePages(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	createdAt := time.Date(2026, time.February, 3, 4, 5, 6, 0, time.UTC)
	firstPage := &changeFeedTestTx{rows: &changeFeedRows{rows: []pgx.Row{
		syncChangeRow(11, userID, "product", uuid.New(), "upsert", []byte(`{"id":"11"}`), deviceID, createdAt),
		syncChangeRow(12, userID, "product", uuid.New(), "upsert", []byte(`{"id":"12"}`), deviceID, createdAt.Add(time.Second)),
		syncChangeRow(13, userID, "product", uuid.New(), "upsert", []byte(`{"id":"13"}`), deviceID, createdAt.Add(2*time.Second)),
	}}}
	secondPage := &changeFeedTestTx{rows: &changeFeedRows{rows: []pgx.Row{
		syncChangeRow(13, userID, "product", uuid.New(), "upsert", []byte(`{"id":"13"}`), deviceID, createdAt.Add(2*time.Second)),
	}}}
	service := newChangeFeedTestService(t, firstPage, secondPage)

	first, err := service.ListChanges(context.Background(), userID, 10, 2)
	if err != nil {
		t.Fatalf("first ListChanges() error = %v", err)
	}
	if len(first.Changes) != 2 || first.NextCursor != 12 || !first.HasMore {
		t.Fatalf("first page = %#v, want two rows through 12 with has_more", first)
	}

	second, err := service.ListChanges(context.Background(), userID, first.NextCursor, 2)
	if err != nil {
		t.Fatalf("second ListChanges() error = %v", err)
	}
	if len(second.Changes) != 1 || second.Changes[0].Seq != 13 || second.NextCursor != 13 || second.HasMore {
		t.Fatalf("second page = %#v, want final row 13 without more", second)
	}
	assertChangeFeedQuery(t, firstPage, userID, 10, 3)
	assertChangeFeedQuery(t, secondPage, userID, 12, 3)
}

func TestServiceListChangesValidatesCursorAndLimitBeforeStartingTransaction(t *testing.T) {
	t.Parallel()

	beginner := &changeFeedTestBeginner{}
	service := newChangeFeedTestServiceWithBeginner(t, beginner)
	userID := uuid.New()

	cases := []struct {
		name      string
		cursor    int64
		max       int
		wantError error
	}{
		{name: "negative cursor", cursor: -1, max: 2, wantError: ErrInvalidChangeFeedCursor},
		{name: "zero limit", cursor: 0, max: 0, wantError: ErrInvalidChangeFeedLimit},
		{name: "negative limit", cursor: 0, max: -1, wantError: ErrInvalidChangeFeedLimit},
		{name: "int32 lookahead overflow", cursor: 0, max: int(1<<31 - 1), wantError: ErrInvalidChangeFeedLimit},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			_, err := service.ListChanges(context.Background(), userID, testCase.cursor, testCase.max)
			if !errors.Is(err, testCase.wantError) {
				t.Fatalf("ListChanges() error = %v, want %v", err, testCase.wantError)
			}
		})
	}
	if beginner.beginCalls != 0 {
		t.Fatalf("BeginTx calls = %d, want zero for invalid feed requests", beginner.beginCalls)
	}
}

func TestHandlerReturnsBoundedChangeFeedMetadataAndUserScope(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	manager := testSyncTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	service := &fakeSyncService{
		processErrors:  map[uuid.UUID]error{},
		processResults: map[uuid.UUID]OperationResult{},
		changeFeed: ChangeFeed{
			Changes: []ChangeEntry{
				{Seq: 6, Entity: "product", Op: "upsert", Data: json.RawMessage(`{"id":"six"}`)},
				{Seq: 7, Entity: "stock_movement", Op: "upsert", Data: json.RawMessage(`{"id":"seven"}`)},
			},
			NextCursor: 7,
			HasMore:    true,
		},
	}
	handler := NewHandler(service, auth.RequireAccessToken(manager)).Routes()
	request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(marshalSyncRequest(t, SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      deviceID,
		Cursor:        5,
		MaxChanges:    2,
		ClientTime:    time.Date(2026, time.March, 4, 5, 6, 7, 0, time.UTC),
		Ops:           []Operation{},
	})))
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("sync status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var response SyncResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode sync response: %v", err)
	}
	if len(response.Changes) != 2 || response.Changes[0].Seq != 6 || response.Changes[1].Seq != 7 {
		t.Fatalf("response changes = %#v, want sequences [6 7]", response.Changes)
	}
	if response.NextCursor != 7 || !response.HasMore {
		t.Fatalf("response metadata = (next %d, has_more %t), want (7, true)", response.NextCursor, response.HasMore)
	}
	if service.changeCalls != 1 || service.changeUserID != userID || service.changeCursor != 5 || service.changeMaxChanges != 2 {
		t.Fatalf("change feed call = (calls %d, user %s, cursor %d, max %d), want authenticated user/cursor/limit", service.changeCalls, service.changeUserID, service.changeCursor, service.changeMaxChanges)
	}
}

func assertChangeFeedQuery(t *testing.T, transaction *changeFeedTestTx, userID uuid.UUID, afterSeq int64, maxChanges int32) {
	t.Helper()
	if len(transaction.queries) != 1 {
		t.Fatalf("queries = %#v, want one change-feed query", transaction.queries)
	}
	query := transaction.queries[0]
	if !strings.Contains(query, "WHERE user_id = $1 AND seq > $2") {
		t.Fatalf("change-feed query = %q, want strict account/cursor predicate", query)
	}
	if !strings.Contains(query, "ORDER BY seq ASC") || !strings.Contains(query, "LIMIT $3") {
		t.Fatalf("change-feed query = %q, want deterministic ascending bounded read", query)
	}
	args := transaction.args[0]
	if len(args) != 3 {
		t.Fatalf("change-feed args = %#v, want user/cursor/limit", args)
	}
	assertSyncUUIDArg(t, args[0], userID)
	if args[1] != afterSeq || args[2] != maxChanges {
		t.Fatalf("change-feed cursor/limit args = (%#v, %#v), want (%d, %d)", args[1], args[2], afterSeq, maxChanges)
	}
}

func newChangeFeedTestService(t *testing.T, transactions ...*changeFeedTestTx) *Service {
	t.Helper()
	return newChangeFeedTestServiceWithBeginner(t, &changeFeedTestBeginner{transactions: transactions})
}

func newChangeFeedTestServiceWithBeginner(t *testing.T, beginner *changeFeedTestBeginner) *Service {
	t.Helper()
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	return service
}

type changeFeedTestBeginner struct {
	transactions []*changeFeedTestTx
	beginCalls   int
}

func (b *changeFeedTestBeginner) BeginTx(context.Context) (db.Tx, error) {
	b.beginCalls++
	if len(b.transactions) == 0 {
		return nil, errors.New("no scripted transaction remains")
	}
	transaction := b.transactions[0]
	b.transactions = b.transactions[1:]
	return transaction, nil
}

type changeFeedTestTx struct {
	rows          pgx.Rows
	queries       []string
	args          [][]any
	execQueries   []string
	commitCalls   int
	rollbackCalls int
}

func (tx *changeFeedTestTx) Exec(_ context.Context, query string, _ ...any) (pgconn.CommandTag, error) {
	tx.execQueries = append(tx.execQueries, query)
	return pgconn.CommandTag{}, nil
}

func (tx *changeFeedTestTx) Query(_ context.Context, query string, args ...any) (pgx.Rows, error) {
	tx.queries = append(tx.queries, query)
	tx.args = append(tx.args, args)
	return tx.rows, nil
}

func (tx *changeFeedTestTx) QueryRow(context.Context, string, ...any) pgx.Row {
	return syncErrorRow(fmt.Errorf("unexpected change-feed query row"))
}

func (tx *changeFeedTestTx) Commit(context.Context) error {
	tx.commitCalls++
	return nil
}

func (tx *changeFeedTestTx) Rollback(context.Context) error {
	tx.rollbackCalls++
	return nil
}

type changeFeedRows struct {
	rows   []pgx.Row
	index  int
	closed bool
}

func (r *changeFeedRows) Close() {
	r.closed = true
}

func (r *changeFeedRows) Err() error {
	return nil
}

func (r *changeFeedRows) CommandTag() pgconn.CommandTag {
	return pgconn.CommandTag{}
}

func (r *changeFeedRows) FieldDescriptions() []pgconn.FieldDescription {
	return nil
}

func (r *changeFeedRows) Next() bool {
	if r.index >= len(r.rows) {
		r.Close()
		return false
	}
	r.index++
	return true
}

func (r *changeFeedRows) Scan(dest ...any) error {
	if r.index == 0 || r.index > len(r.rows) {
		return errors.New("scan called without a current change row")
	}
	return r.rows[r.index-1].Scan(dest...)
}

func (r *changeFeedRows) Values() ([]any, error) {
	return nil, nil
}

func (r *changeFeedRows) RawValues() [][]byte {
	return nil
}

func (r *changeFeedRows) Conn() *pgx.Conn {
	return nil
}
