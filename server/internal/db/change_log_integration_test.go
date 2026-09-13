package db

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

// TestPostgresCommittedChangeLogCursors is opt-in. It exercises the real
// transaction-scoped cursor allocator with concurrent transactions, including
// a writer that is forced to wait on the allocator row and a transaction that
// rolls back after allocating and inserting a change event.
func TestPostgresCommittedChangeLogCursors(t *testing.T) {
	databaseURL := strings.TrimSpace(os.Getenv("STOKSYNC_TEST_DATABASE_URL"))
	if databaseURL == "" {
		t.Skip("set STOKSYNC_TEST_DATABASE_URL to run PostgreSQL cursor integration tests")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	pool, err := Open(ctx, PoolConfig{
		URL:               databaseURL,
		MaxConns:          8,
		MinConns:          0,
		MaxConnLifetime:   time.Hour,
		MaxConnIdleTime:   30 * time.Minute,
		HealthCheckPeriod: time.Minute,
	})
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("database Ping() error = %v", err)
	}

	var counterRows int
	if err := pool.QueryRow(ctx, `
SELECT count(*)
FROM sync_seq_counter
WHERE id = 1`).Scan(&counterRows); err != nil {
		t.Fatalf("check sync_seq_counter seed row: %v", err)
	}
	if counterRows != 1 {
		t.Fatalf("sync_seq_counter seed rows = %d, want 1", counterRows)
	}

	userID := uuid.New()
	deviceID := uuid.New()
	if err := pool.WithTx(ctx, func(q *Queries) error {
		if _, err := q.DB().Exec(ctx, `
INSERT INTO users (id, email, password_hash)
VALUES ($1, $2, $3)`, uuidArg(userID), "cursor-"+userID.String()+"@example.test", "test-hash"); err != nil {
			return err
		}
		_, err := q.DB().Exec(ctx, `
INSERT INTO devices (id, user_id, name, platform)
VALUES ($1, $2, $3, $4)`, uuidArg(deviceID), uuidArg(userID), "cursor-test-device", "test")
		return err
	}); err != nil {
		t.Fatalf("insert cursor test account/device: %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cleanupCancel()
		_ = pool.WithTx(cleanupCtx, func(q *Queries) error {
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM change_log WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `
DELETE FROM product_balances
WHERE product_id IN (SELECT id FROM products WHERE user_id = $1)`, uuidArg(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM products WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			if _, err := q.DB().Exec(cleanupCtx, `DELETE FROM devices WHERE user_id = $1`, uuidArg(userID)); err != nil {
				return err
			}
			_, err := q.DB().Exec(cleanupCtx, `DELETE FROM users WHERE id = $1`, uuidArg(userID))
			return err
		})
	})

	startSeq, err := readChangeSequence(ctx, pool)
	if err != nil {
		t.Fatalf("read starting change sequence: %v", err)
	}

	slowTx, err := pool.BeginTx(ctx)
	if err != nil {
		t.Fatalf("begin slow transaction: %v", err)
	}
	defer func() { _ = slowTx.Rollback(ctx) }()
	slowQueries := NewQueries(slowTx)
	slowProductID := uuid.New()
	slowEntry, err := appendCursorEvent(ctx, slowQueries, userID, deviceID, slowProductID)
	if err != nil {
		t.Fatalf("append slow transaction event: %v", err)
	}
	if slowEntry.Seq != startSeq+1 {
		t.Fatalf("slow transaction sequence = %d, want %d", slowEntry.Seq, startSeq+1)
	}

	fastReady := make(chan struct{})
	fastResult := make(chan cursorTransactionResult, 1)
	fastProductID := uuid.New()
	go func() {
		fastTx, err := pool.BeginTx(ctx)
		if err != nil {
			close(fastReady)
			fastResult <- cursorTransactionResult{err: err}
			return
		}
		fastQueries := NewQueries(fastTx)
		close(fastReady)
		entry, err := appendCursorEvent(ctx, fastQueries, userID, deviceID, fastProductID)
		if err == nil {
			err = fastTx.Commit(ctx)
		} else {
			_ = fastTx.Rollback(ctx)
		}
		fastResult <- cursorTransactionResult{entry: entry, err: err}
	}()
	<-fastReady

	select {
	case result := <-fastResult:
		t.Fatalf("concurrent writer completed before allocator transaction committed: %#v", result)
	case <-time.After(100 * time.Millisecond):
		// The first transaction holds the sync_seq_counter row lock until its
		// commit, so the second writer must still be waiting here.
	}

	if err := slowTx.Commit(ctx); err != nil {
		t.Fatalf("commit slow transaction: %v", err)
	}
	fast := <-fastResult
	if fast.err != nil {
		t.Fatalf("commit fast transaction: %v", fast.err)
	}
	if fast.entry.Seq != slowEntry.Seq+1 {
		t.Fatalf("fast transaction sequence = %d, want %d after slow commit", fast.entry.Seq, slowEntry.Seq+1)
	}

	beforeRollback, err := readChangeSequence(ctx, pool)
	if err != nil {
		t.Fatalf("read sequence before rollback: %v", err)
	}
	rollbackTx, err := pool.BeginTx(ctx)
	if err != nil {
		t.Fatalf("begin rollback transaction: %v", err)
	}
	rollbackQueries := NewQueries(rollbackTx)
	rollbackProductID := uuid.New()
	rollbackEntry, err := appendCursorEvent(ctx, rollbackQueries, userID, deviceID, rollbackProductID)
	if err != nil {
		_ = rollbackTx.Rollback(ctx)
		t.Fatalf("append rollback transaction event: %v", err)
	}
	if rollbackEntry.Seq != beforeRollback+1 {
		_ = rollbackTx.Rollback(ctx)
		t.Fatalf("rollback transaction sequence = %d, want %d", rollbackEntry.Seq, beforeRollback+1)
	}
	if err := rollbackTx.Rollback(ctx); err != nil {
		t.Fatalf("rollback cursor transaction: %v", err)
	}

	afterRollback, err := readChangeSequence(ctx, pool)
	if err != nil {
		t.Fatalf("read sequence after rollback: %v", err)
	}
	if afterRollback != beforeRollback {
		t.Fatalf("sequence after rollback = %d, want %d; allocator was not transactional", afterRollback, beforeRollback)
	}
	var rolledBackEvents int
	if err := pool.QueryRow(ctx, `
SELECT count(*)
FROM change_log
WHERE user_id = $1 AND entity_id = $2`, uuidArg(userID), uuidArg(rollbackProductID)).Scan(&rolledBackEvents); err != nil {
		t.Fatalf("check rolled-back change event: %v", err)
	}
	if rolledBackEvents != 0 {
		t.Fatalf("rolled-back change events = %d, want 0", rolledBackEvents)
	}
	var rolledBackProducts int
	if err := pool.QueryRow(ctx, `
SELECT count(*)
FROM products
WHERE user_id = $1 AND id = $2`, uuidArg(userID), uuidArg(rollbackProductID)).Scan(&rolledBackProducts); err != nil {
		t.Fatalf("check rolled-back domain row: %v", err)
	}
	if rolledBackProducts != 0 {
		t.Fatalf("rolled-back domain rows = %d, want 0", rolledBackProducts)
	}

	replacementTx, err := pool.BeginTx(ctx)
	if err != nil {
		t.Fatalf("begin replacement transaction: %v", err)
	}
	replacementEntry, err := appendCursorEvent(ctx, NewQueries(replacementTx), userID, deviceID, uuid.New())
	if err != nil {
		_ = replacementTx.Rollback(ctx)
		t.Fatalf("append replacement transaction event: %v", err)
	}
	if replacementEntry.Seq != rollbackEntry.Seq {
		_ = replacementTx.Rollback(ctx)
		t.Fatalf("replacement sequence = %d, want rolled-back sequence %d", replacementEntry.Seq, rollbackEntry.Seq)
	}
	if err := replacementTx.Commit(ctx); err != nil {
		t.Fatalf("commit replacement transaction: %v", err)
	}

	finalSeq, err := readChangeSequence(ctx, pool)
	if err != nil {
		t.Fatalf("read final change sequence: %v", err)
	}
	var committedCount int64
	if err := pool.QueryRow(ctx, `
SELECT count(*)
FROM change_log
WHERE seq > $1 AND seq <= $2`, startSeq, finalSeq).Scan(&committedCount); err != nil {
		t.Fatalf("count committed change-log entries: %v", err)
	}
	if committedCount != finalSeq-startSeq {
		t.Fatalf("committed entries in [%d,%d] = %d, want %d; committed cursor range has a gap", startSeq+1, finalSeq, committedCount, finalSeq-startSeq)
	}
	var missingCount int64
	if err := pool.QueryRow(ctx, `
SELECT count(*)
FROM generate_series($1::bigint + 1, $2::bigint) AS expected(seq)
LEFT JOIN change_log AS actual ON actual.seq = expected.seq
WHERE actual.seq IS NULL`, startSeq, finalSeq).Scan(&missingCount); err != nil {
		t.Fatalf("check committed cursor gaps: %v", err)
	}
	if missingCount != 0 {
		t.Fatalf("missing committed cursor entries = %d in [%d,%d]", missingCount, startSeq+1, finalSeq)
	}
}

type cursorTransactionResult struct {
	entry ChangeLogEntry
	err   error
}

func appendCursorEvent(ctx context.Context, q *Queries, userID, deviceID, productID uuid.UUID) (ChangeLogEntry, error) {
	if _, err := q.DB().Exec(ctx, `
INSERT INTO products (id, user_id, name, updated_by_device_id)
VALUES ($1, $2, $3, $4)`, uuidArg(productID), uuidArg(userID), "Cursor test product", uuidArg(deviceID)); err != nil {
		return ChangeLogEntry{}, err
	}
	return q.AppendChangeLog(ctx, AppendChangeLogParams{
		UserID:         userID,
		Entity:         "product",
		EntityID:       productID,
		Op:             "upsert",
		Payload:        []byte(fmt.Sprintf(`{"id":%q}`, productID.String())),
		OriginDeviceID: &deviceID,
	})
}

func readChangeSequence(ctx context.Context, pool *Pool) (int64, error) {
	var sequence int64
	if err := pool.QueryRow(ctx, `
SELECT last_seq
FROM sync_seq_counter
WHERE id = 1`).Scan(&sequence); err != nil {
		return 0, err
	}
	return sequence, nil
}
