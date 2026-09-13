package sync

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
	"github.com/stoksync/stoksync/server/internal/movements"
	"github.com/stoksync/stoksync/server/internal/products"
)

const (
	// ReasonOperationNotImplemented remains available for tests or custom
	// transaction handlers that intentionally use the pre-Task-3.3 seam.
	ReasonOperationNotImplemented = "operation_not_implemented"
)

var (
	ErrInvalidService      = errors.New("sync service is invalid")
	ErrInvalidIdentity     = errors.New("sync identity is invalid")
	ErrDeviceNotRegistered = errors.New("sync device is not registered")
)

// OperationTransactionHandler is the seam for transaction-bound operation
// application. The callback receives a transaction-bound query object;
// ProcessOperation commits or rolls back that transaction independently for
// each received operation.
type OperationTransactionHandler func(context.Context, *db.Queries, auth.Identity, Operation) (OperationResult, error)

// Service owns the synchronization transaction boundary and the canonical
// transaction-bound domain services used by its default operation handler.
type Service struct {
	beginner         db.TxBeginner
	operationHandler OperationTransactionHandler
	productService   *products.Service
	movementService  *movements.Service
	now              func() time.Time
}

// NewService constructs the synchronization service with the Task 3.3
// operation handler. The domain services are retained only as transaction
// bound helpers; they never begin nested transactions during sync processing.
func NewService(beginner db.TxBeginner) (*Service, error) {
	if beginner == nil {
		return nil, ErrInvalidService
	}
	productService, err := products.NewService(beginner)
	if err != nil {
		return nil, ErrInvalidService
	}
	movementService, err := movements.NewService(beginner)
	if err != nil {
		return nil, ErrInvalidService
	}
	service := &Service{
		beginner:        beginner,
		productService:  productService,
		movementService: movementService,
		now:             time.Now,
	}
	service.operationHandler = service.processOperation
	return service, nil
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

	result, err := db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (OperationResult, error) {
		return s.operationHandler(ctx, queries, identity, operation)
	})
	if errors.Is(err, ErrDuplicateOperation) {
		// The duplicate transaction was rolled back after the atomic conflict
		// check. Replaying the stored response belongs to Task 3.4; this seam
		// deliberately reports a stable result without applying domain logic.
		return OperationResult{
			OpID:   operation.OpID,
			Status: ResultStatusRejected,
			Reason: ReasonDuplicateOperation,
		}, nil
	}
	return result, err
}

func rejectOperation(_ context.Context, _ *db.Queries, _ auth.Identity, operation Operation) (OperationResult, error) {
	return OperationResult{
		OpID:   operation.OpID,
		Status: ResultStatusRejected,
		Reason: ReasonOperationNotImplemented,
	}, nil
}
