package db

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

func TestListChangeLogUsesStrictAccountCursorAndBoundedAscendingRead(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	firstID := uuid.New()
	secondID := uuid.New()
	createdAt := time.Date(2026, time.March, 4, 5, 6, 7, 0, time.UTC)
	fake := &snapshotQueryDB{rows: &snapshotRows{rows: []pgx.Row{
		changeLogQueryRow(18, userID, firstID, "product", "upsert", []byte(`{"id":"first"}`), createdAt),
		changeLogQueryRow(19, userID, secondID, "stock_movement", "upsert", []byte(`{"id":"second"}`), createdAt.Add(time.Second)),
	}}}

	changes, err := NewQueries(fake).ListChangeLog(context.Background(), ListChangeLogParams{
		UserID:     userID,
		AfterSeq:   17,
		MaxChanges: 2,
	})
	if err != nil {
		t.Fatalf("ListChangeLog() error = %v", err)
	}
	if len(changes) != 2 || changes[0].Seq != 18 || changes[1].Seq != 19 {
		t.Fatalf("changes = %#v, want ascending sequences [18 19]", changes)
	}
	if changes[0].UserID != userID || changes[1].UserID != userID {
		t.Fatalf("change user IDs = (%s, %s), want account %s", changes[0].UserID, changes[1].UserID, userID)
	}
	if !strings.Contains(fake.query, "WHERE user_id = $1 AND seq > $2") {
		t.Fatalf("query = %q, want strict account and cursor predicate", fake.query)
	}
	if !strings.Contains(fake.query, "ORDER BY seq ASC") || !strings.Contains(fake.query, "LIMIT $3") {
		t.Fatalf("query = %q, want deterministic ascending bounded page", fake.query)
	}
	assertUUIDArg(t, fake.args[0], userID)
	if fake.args[1] != int64(17) || fake.args[2] != int32(2) {
		t.Fatalf("cursor/limit args = (%#v, %#v), want (17, int32(2))", fake.args[1], fake.args[2])
	}
}

func TestListChangeLogReturnsNonNilEmptyFeed(t *testing.T) {
	t.Parallel()

	fake := &snapshotQueryDB{rows: &snapshotRows{rows: []pgx.Row{}}}
	changes, err := NewQueries(fake).ListChangeLog(context.Background(), ListChangeLogParams{
		UserID:     uuid.New(),
		AfterSeq:   100,
		MaxChanges: 5,
	})
	if err != nil {
		t.Fatalf("ListChangeLog() error = %v", err)
	}
	if changes == nil || len(changes) != 0 {
		t.Fatalf("changes = %#v, want non-nil empty result", changes)
	}
}

func TestListChangeLogRejectsNegativeAndZeroLimitsBeforeQuery(t *testing.T) {
	t.Parallel()

	for _, limit := range []int32{0, -1} {
		fake := &fakeQueryDB{}
		_, err := NewQueries(fake).ListChangeLog(context.Background(), ListChangeLogParams{MaxChanges: limit})
		if err == nil {
			t.Fatalf("ListChangeLog(limit=%d) error = nil, want validation error", limit)
		}
		if fake.queryCalls != 0 {
			t.Fatalf("ListChangeLog(limit=%d) executed SQL for invalid limit", limit)
		}
	}
}

func changeLogQueryRow(seq int64, userID, entityID uuid.UUID, entity, op string, payload []byte, createdAt time.Time) pgx.Row {
	return staticRow{values: []any{
		seq,
		uuidArg(userID),
		entity,
		uuidArg(entityID),
		op,
		payload,
		pgtype.UUID{},
		createdAt,
	}}
}
