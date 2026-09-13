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
	ErrInvalidService          = errors.New("sync service is invalid")
	ErrInvalidIdentity         = errors.New("sync identity is invalid")
	ErrDeviceNotRegistered     = errors.New("sync device is not registered")
	ErrInvalidChangeFeedCursor = errors.New("change feed cursor must not be negative")
	ErrInvalidChangeFeedLimit  = errors.New("change feed max_changes is invalid")
)

// ChangeFeed is one bounded, account-scoped page from the canonical change log.
// NextCursor is unchanged when the page is empty and otherwise identifies the
// last returned row, allowing the next request to continue with seq > cursor.
type ChangeFeed struct {
	Changes    []ChangeEntry
	NextCursor int64
	HasMore    bool
}

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

	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (OperationResult, error) {
		return s.operationHandler(ctx, queries, identity, operation)
	})
}

// ListChanges reads one consistent page of canonical changes for an account.
// The query requests one row beyond the response bound so has_more can be
// determined without a second, race-prone count query. The read is performed
// in a repeatable-read transaction so the returned page is a stable view even
// while other accounts or devices append changes.
func (s *Service) ListChanges(ctx context.Context, userID uuid.UUID, afterSeq int64, maxChanges int) (ChangeFeed, error) {
	if s == nil || s.beginner == nil {
		return ChangeFeed{}, ErrInvalidService
	}
	if userID == uuid.Nil {
		return ChangeFeed{}, ErrInvalidIdentity
	}
	if afterSeq < 0 {
		return ChangeFeed{}, ErrInvalidChangeFeedCursor
	}
	// ListChangeLog uses int32 for PostgreSQL's LIMIT argument. Reserve one
	// value for the look-ahead row used to calculate has_more.
	const maxInt32 = int64(1<<31 - 1)
	if maxChanges <= 0 || int64(maxChanges) >= maxInt32 {
		return ChangeFeed{}, ErrInvalidChangeFeedLimit
	}

	return db.WithSnapshotResult(ctx, s.beginner, func(queries *db.Queries) (ChangeFeed, error) {
		changes, err := queries.ListChangeLog(ctx, db.ListChangeLogParams{
			UserID:     userID,
			AfterSeq:   afterSeq,
			MaxChanges: int32(maxChanges + 1),
		})
		if err != nil {
			return ChangeFeed{}, err
		}

		hasMore := len(changes) > maxChanges
		if hasMore {
			changes = changes[:maxChanges]
		}

		feed := ChangeFeed{
			Changes:    make([]ChangeEntry, 0, len(changes)),
			NextCursor: afterSeq,
			HasMore:    hasMore,
		}
		for _, change := range changes {
			var originDeviceID *uuid.UUID
			if change.OriginDeviceID != nil {
				origin := *change.OriginDeviceID
				originDeviceID = &origin
			}
			createdAt := change.CreatedAt.UTC()
			feed.Changes = append(feed.Changes, ChangeEntry{
				Seq:            change.Seq,
				Entity:         change.Entity,
				Op:             change.Op,
				Data:           append([]byte(nil), change.Payload...),
				OriginDeviceID: originDeviceID,
				CreatedAt:      &createdAt,
			})
			feed.NextCursor = change.Seq
		}
		return feed, nil
	})
}

func rejectOperation(_ context.Context, _ *db.Queries, _ auth.Identity, operation Operation) (OperationResult, error) {
	return OperationResult{
		OpID:   operation.OpID,
		Status: ResultStatusRejected,
		Reason: ReasonOperationNotImplemented,
	}, nil
}
