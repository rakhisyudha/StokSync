package db

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// DBTX is the common subset implemented by *pgxpool.Pool and pgx.Tx. Keeping
// queries on this interface makes the generated-style data-access layer usable
// with either a pool or a transaction and straightforward to unit test.
type DBTX interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	Query(context.Context, string, ...any) (pgx.Rows, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

// Tx is the transaction subset required by WithTx. pgx.Tx satisfies it.
type Tx interface {
	DBTX
	Commit(context.Context) error
	Rollback(context.Context) error
}

// TxBeginner is implemented by Pool and allows transaction orchestration to
// be tested with a small fake rather than a live PostgreSQL server.
type TxBeginner interface {
	BeginTx(context.Context) (Tx, error)
}

// WithTx begins a transaction, runs fn with transaction-bound queries, and
// commits only after fn succeeds. A failed callback or commit leaves the
// transaction rolled back when the driver permits it.
func WithTx(ctx context.Context, beginner TxBeginner, fn func(*Queries) error) error {
	if ctx == nil {
		return errNilContext
	}
	if beginner == nil {
		return errNilTxBeginner
	}
	if fn == nil {
		return errNilTransactionFunc
	}

	tx, err := beginner.BeginTx(ctx)
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	if err := fn(NewQueries(tx)); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	committed = true
	return nil
}

// WithTxResult is WithTx for callbacks that return a value.
func WithTxResult[T any](ctx context.Context, beginner TxBeginner, fn func(*Queries) (T, error)) (T, error) {
	var zero T
	if ctx == nil {
		return zero, errNilContext
	}
	if beginner == nil {
		return zero, errNilTxBeginner
	}
	if fn == nil {
		return zero, errNilTransactionFunc
	}

	tx, err := beginner.BeginTx(ctx)
	if err != nil {
		return zero, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()

	result, err := fn(NewQueries(tx))
	if err != nil {
		return zero, err
	}
	if err := tx.Commit(ctx); err != nil {
		return zero, err
	}
	committed = true
	return result, nil
}

var (
	errNilContext         = errorString("database context must not be nil")
	errNilTxBeginner      = errorString("transaction beginner must not be nil")
	errNilTransactionFunc = errorString("transaction function must not be nil")
)

type errorString string

func (e errorString) Error() string { return string(e) }
