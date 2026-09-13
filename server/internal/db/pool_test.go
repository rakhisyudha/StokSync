package db

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestOpenAppliesPoolSettingsAndCloseIsIdempotent(t *testing.T) {
	t.Parallel()

	pool, err := Open(context.Background(), PoolConfig{
		URL:               "postgres://user:password@127.0.0.1:1/stoksync?sslmode=disable",
		MaxConns:          4,
		MinConns:          0,
		MaxConnLifetime:   2 * time.Hour,
		MaxConnIdleTime:   17 * time.Minute,
		HealthCheckPeriod: 23 * time.Second,
	})
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}

	config := pool.Pool.Config()
	if config.MaxConns != 4 {
		t.Errorf("MaxConns = %d, want 4", config.MaxConns)
	}
	if config.MinConns != 0 {
		t.Errorf("MinConns = %d, want 0", config.MinConns)
	}
	if config.MaxConnLifetime != 2*time.Hour {
		t.Errorf("MaxConnLifetime = %s, want 2h", config.MaxConnLifetime)
	}
	if config.MaxConnIdleTime != 17*time.Minute {
		t.Errorf("MaxConnIdleTime = %s, want 17m", config.MaxConnIdleTime)
	}
	if config.HealthCheckPeriod != 23*time.Second {
		t.Errorf("HealthCheckPeriod = %s, want 23s", config.HealthCheckPeriod)
	}

	pool.Close()
	pool.Close()
}

func TestOpenRejectsInvalidConfigurationWithoutLoggingURL(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		config PoolConfig
		want   string
	}{
		{
			name:   "empty URL",
			config: PoolConfig{},
			want:   "database URL must not be empty",
		},
		{
			name: "min exceeds max",
			config: PoolConfig{
				URL:      "postgres://user:secret@localhost/stoksync",
				MaxConns: 2,
				MinConns: 3,
			},
			want: "database min connections must not exceed max connections",
		},
		{
			name: "malformed URL",
			config: PoolConfig{
				URL: "postgres://user:secret%zz@localhost/stoksync",
			},
			want: "parse database URL: invalid database configuration",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := Open(context.Background(), test.config)
			if err == nil {
				t.Fatal("Open() error = nil, want validation error")
			}
			if err.Error() != test.want {
				t.Errorf("Open() error = %q, want %q", err, test.want)
			}
			if test.name == "malformed URL" && contains(err.Error(), "secret") {
				t.Error("Open() error leaked the database URL secret")
			}
		})
	}
}

func TestWithTxCommitsSuccessfulCallback(t *testing.T) {
	t.Parallel()

	transaction := &fakeTx{}
	beginner := &fakeBeginner{tx: transaction}
	called := false

	if err := WithTx(context.Background(), beginner, func(queries *Queries) error {
		called = true
		if queries.DB() != transaction {
			t.Fatal("callback queries are not bound to the transaction")
		}
		return nil
	}); err != nil {
		t.Fatalf("WithTx() error = %v", err)
	}
	if !called {
		t.Fatal("transaction callback was not called")
	}
	if !transaction.committed {
		t.Error("transaction was not committed")
	}
	if transaction.rolledBack {
		t.Error("successful transaction was rolled back")
	}
}

func TestWithTxRollsBackCallbackError(t *testing.T) {
	t.Parallel()

	transaction := &fakeTx{}
	callbackErr := errors.New("domain write failed")
	err := WithTx(context.Background(), &fakeBeginner{tx: transaction}, func(*Queries) error {
		return callbackErr
	})
	if !errors.Is(err, callbackErr) {
		t.Fatalf("WithTx() error = %v, want callback error", err)
	}
	if !transaction.rolledBack {
		t.Error("callback failure did not roll back transaction")
	}
	if transaction.committed {
		t.Error("callback failure committed transaction")
	}
}

func TestWithTxRollsBackCommitError(t *testing.T) {
	t.Parallel()

	transaction := &fakeTx{commitErr: errors.New("commit failed")}
	err := WithTx(context.Background(), &fakeBeginner{tx: transaction}, func(*Queries) error {
		return nil
	})
	if !errors.Is(err, transaction.commitErr) {
		t.Fatalf("WithTx() error = %v, want commit error", err)
	}
	if !transaction.rolledBack {
		t.Error("commit failure did not attempt rollback")
	}
}

func TestWithTxResultReturnsCommittedValue(t *testing.T) {
	t.Parallel()

	transaction := &fakeTx{}
	value, err := WithTxResult(context.Background(), &fakeBeginner{tx: transaction}, func(*Queries) (string, error) {
		return "committed value", nil
	})
	if err != nil {
		t.Fatalf("WithTxResult() error = %v", err)
	}
	if value != "committed value" {
		t.Errorf("value = %q, want committed value", value)
	}
	if !transaction.committed {
		t.Error("transaction was not committed")
	}
}

func TestWithSnapshotResultConfiguresRepeatableReadBeforeCallback(t *testing.T) {
	t.Parallel()

	transaction := &fakeTx{}
	value, err := WithSnapshotResult(context.Background(), &fakeBeginner{tx: transaction}, func(*Queries) (string, error) {
		return "consistent value", nil
	})
	if err != nil {
		t.Fatalf("WithSnapshotResult() error = %v", err)
	}
	if value != "consistent value" {
		t.Errorf("value = %q, want consistent value", value)
	}
	if !transaction.committed || transaction.rolledBack {
		t.Errorf("transaction completion = (committed %t, rolled back %t), want commit only", transaction.committed, transaction.rolledBack)
	}
	if len(transaction.execQueries) != 1 || transaction.execQueries[0] != "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY" {
		t.Errorf("transaction setup queries = %#v, want repeatable-read read-only setup", transaction.execQueries)
	}
}

type fakeBeginner struct {
	tx       Tx
	beginErr error
}

func (f *fakeBeginner) BeginTx(context.Context) (Tx, error) {
	if f.beginErr != nil {
		return nil, f.beginErr
	}
	return f.tx, nil
}

type fakeTx struct {
	commitErr   error
	rollbackErr error
	committed   bool
	rolledBack  bool
	execQueries []string
}

func (f *fakeTx) Exec(_ context.Context, query string, _ ...any) (pgconn.CommandTag, error) {
	f.execQueries = append(f.execQueries, query)
	return pgconn.CommandTag{}, nil
}

func (f *fakeTx) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, nil
}

func (f *fakeTx) QueryRow(context.Context, string, ...any) pgx.Row {
	return nil
}

func (f *fakeTx) Commit(context.Context) error {
	f.committed = true
	return f.commitErr
}

func (f *fakeTx) Rollback(context.Context) error {
	f.rolledBack = true
	return f.rollbackErr
}

func contains(value, substring string) bool {
	for i := 0; i+len(substring) <= len(value); i++ {
		if value[i:i+len(substring)] == substring {
			return true
		}
	}
	return false
}
