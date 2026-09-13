package sync

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
)

const (
	// ReasonOperationNotImplemented is returned until the operation domain
	// services are wired by Task 3.3. A request is never reported as applied by
	// this boundary-only implementation.
	ReasonOperationNotImplemented = "operation_not_implemented"
)

var (
	ErrInvalidService      = errors.New("sync service is invalid")
	ErrInvalidIdentity     = errors.New("sync identity is invalid")
	ErrDeviceNotRegistered = errors.New("sync device is not registered")
)

// OperationTransactionHandler is the seam for the later domain operation
// implementation. The callback receives a transaction-bound query object;
// ProcessOperation commits or rolls back that transaction independently for
// each received operation.
type OperationTransactionHandler func(context.Context, *db.Queries, auth.Identity, Operation) (OperationResult, error)

// Service owns the synchronization transaction boundary. It deliberately
// does not apply add_movement, upsert_product, or delete_product semantics;
// those are introduced by Task 3.3.
type Service struct {
	beginner         db.TxBeginner
	operationHandler OperationTransactionHandler
}

// NewService constructs the Task 3.2 synchronization boundary. Operations are
// safely rejected until a domain handler is supplied by the next task.
func NewService(beginner db.TxBeginner) (*Service, error) {
	if beginner == nil {
		return nil, ErrInvalidService
	}
	return &Service{
		beginner:         beginner,
		operationHandler: rejectOperation,
	}, nil
}

// ValidateDevice confirms that the authenticated account owns the device named
// by the sync request. The lookup is transaction-scoped so the handler never
// processes a request for an unregistered or cross-account installation.
func (s *Service) ValidateDevice(ctx context.Context, userID, deviceID uuid.UUID) error {
	if s == nil || s.beginner == nil {
		return ErrInvalidService
	}
	if userID == uuid.Nil || deviceID == uuid.Nil {
		return ErrInvalidIdentity
	}

	_, err := db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (db.Device, error) {
		device, err := queries.GetDevice(ctx, userID, deviceID)
		if errors.Is(err, pgx.ErrNoRows) {
			return db.Device{}, ErrDeviceNotRegistered
		}
		if err != nil {
			return db.Device{}, err
		}
		if device.ID != deviceID || device.UserID != userID {
			return db.Device{}, ErrDeviceNotRegistered
		}
		return device, nil
	})
	return err
}

// ProcessOperation runs exactly one operation callback in exactly one
// transaction. A transaction error is returned to the handler, which turns it
// into an independent rejected result and continues with later operations.
func (s *Service) ProcessOperation(ctx context.Context, identity auth.Identity, operation Operation) (OperationResult, error) {
	if s == nil || s.beginner == nil || s.operationHandler == nil {
		return OperationResult{}, ErrInvalidService
	}
	if identity.UserID == uuid.Nil || identity.DeviceID == uuid.Nil {
		return OperationResult{}, ErrInvalidIdentity
	}

	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (OperationResult, error) {
		return s.operationHandler(ctx, queries, identity, operation)
	})
}

func rejectOperation(_ context.Context, _ *db.Queries, _ auth.Identity, operation Operation) (OperationResult, error) {
	return OperationResult{
		OpID:   operation.OpID,
		Status: ResultStatusRejected,
		Reason: ReasonOperationNotImplemented,
	}, nil
}
