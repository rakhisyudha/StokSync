package sync

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
)

func TestServiceUsesAnIndependentTransactionForEachOperation(t *testing.T) {
	t.Parallel()

	beginner := &recordingTxBeginner{}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	// Keep this test focused on the independent transaction boundary rather
	// than the Task 3.3 domain handler; the default handler now executes real
	// transaction-bound operations.
	service.operationHandler = rejectOperation
	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}
	for i := 0; i < 2; i++ {
		result, err := service.ProcessOperation(context.Background(), identity, Operation{OpID: uuid.New()})
		if err != nil {
			t.Fatalf("ProcessOperation(%d) error = %v", i, err)
		}
		if result.Status != ResultStatusRejected || result.Reason != ReasonOperationNotImplemented {
			t.Fatalf("ProcessOperation(%d) result = %#v, want explicit unimplemented rejection", i, result)
		}
	}
	if len(beginner.transactions) != 2 {
		t.Fatalf("transactions = %d, want one transaction per operation", len(beginner.transactions))
	}
	for i, transaction := range beginner.transactions {
		if transaction.commitCalls != 1 || transaction.rollbackCalls != 0 {
			t.Errorf("transaction %d lifecycle = (commit %d, rollback %d), want (1, 0)", i, transaction.commitCalls, transaction.rollbackCalls)
		}
	}
}

func TestServiceRollsBackOnlyTheFailedOperationTransaction(t *testing.T) {
	t.Parallel()

	beginner := &recordingTxBeginner{}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}
	calls := 0
	service.operationHandler = func(_ context.Context, _ *db.Queries, _ auth.Identity, operation Operation) (OperationResult, error) {
		calls++
		if calls == 1 {
			return OperationResult{}, errors.New("operation transaction failure")
		}
		return OperationResult{OpID: operation.OpID, Status: ResultStatusRejected, Reason: "test_rejected"}, nil
	}
	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}

	if _, err := service.ProcessOperation(context.Background(), identity, Operation{OpID: uuid.New()}); err == nil {
		t.Fatal("first ProcessOperation() error = nil, want callback failure")
	}
	result, err := service.ProcessOperation(context.Background(), identity, Operation{OpID: uuid.New()})
	if err != nil {
		t.Fatalf("second ProcessOperation() error = %v, want independent success", err)
	}
	if result.Status != ResultStatusRejected {
		t.Fatalf("second result = %#v, want rejected test result", result)
	}
	if len(beginner.transactions) != 2 {
		t.Fatalf("transactions = %d, want two independent boundaries", len(beginner.transactions))
	}
	if beginner.transactions[0].commitCalls != 0 || beginner.transactions[0].rollbackCalls != 1 {
		t.Errorf("failed transaction lifecycle = (commit %d, rollback %d), want (0, 1)", beginner.transactions[0].commitCalls, beginner.transactions[0].rollbackCalls)
	}
	if beginner.transactions[1].commitCalls != 1 || beginner.transactions[1].rollbackCalls != 0 {
		t.Errorf("successful transaction lifecycle = (commit %d, rollback %d), want (1, 0)", beginner.transactions[1].commitCalls, beginner.transactions[1].rollbackCalls)
	}
}

type recordingTxBeginner struct {
	transactions []*recordingTx
}

func (b *recordingTxBeginner) BeginTx(context.Context) (db.Tx, error) {
	transaction := &recordingTx{}
	b.transactions = append(b.transactions, transaction)
	return transaction, nil
}

type recordingTx struct {
	commitCalls   int
	rollbackCalls int
}

func (t *recordingTx) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}

func (t *recordingTx) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, nil
}

func (t *recordingTx) QueryRow(context.Context, string, ...any) pgx.Row {
	return nil
}

func (t *recordingTx) Commit(context.Context) error {
	t.commitCalls++
	return nil
}

func (t *recordingTx) Rollback(context.Context) error {
	t.rollbackCalls++
	return nil
}
