// Package snapshot contains the authenticated full-replica bootstrap endpoint.
package snapshot

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/stoksync/stoksync/server/internal/db"
)

const (
	// SchemaVersion is the wire version for GET /v1/snapshot responses.
	SchemaVersion = 1

	defaultMaxProducts      int32 = 10_000
	defaultMaxMovements     int32 = 100_000
	defaultMaxResponseBytes       = 32 << 20
	maxSnapshotRequestBytes       = 4 << 10
	maxInt32Rows            int32 = 1<<31 - 1
)

var (
	// ErrInvalidUser means a snapshot was requested without a valid account
	// identity. The HTTP layer maps it to a generic unauthorized response.
	ErrInvalidUser = errors.New("snapshot user identity is invalid")
	// ErrSnapshotTooLarge means the account exceeds a configured snapshot row
	// or encoded response bound. The caller can retry after incremental sync is
	// available or adjust deployment limits; no partial snapshot is returned.
	ErrSnapshotTooLarge = errors.New("snapshot exceeds configured limits")
	// ErrInvalidLimits means a service was configured with an unsafe bound.
	ErrInvalidLimits = errors.New("snapshot limits are invalid")
)

// Limits bound database work and the encoded HTTP response. The defaults are
// intentionally above the intended v1 scale of hundreds to low thousands of
// products while preventing an unbounded bootstrap allocation.
type Limits struct {
	MaxProducts      int32
	MaxMovements     int32
	MaxResponseBytes int
	MaxRequestBytes  int
}

func DefaultLimits() Limits {
	return Limits{
		MaxProducts:      defaultMaxProducts,
		MaxMovements:     defaultMaxMovements,
		MaxResponseBytes: defaultMaxResponseBytes,
		MaxRequestBytes:  maxSnapshotRequestBytes,
	}
}

func (l Limits) withDefaults() Limits {
	defaults := DefaultLimits()
	if l.MaxProducts == 0 {
		l.MaxProducts = defaults.MaxProducts
	}
	if l.MaxMovements == 0 {
		l.MaxMovements = defaults.MaxMovements
	}
	if l.MaxResponseBytes == 0 {
		l.MaxResponseBytes = defaults.MaxResponseBytes
	}
	if l.MaxRequestBytes == 0 {
		l.MaxRequestBytes = defaults.MaxRequestBytes
	}
	return l
}

func (l Limits) validate() error {
	if l.MaxProducts <= 0 || l.MaxProducts >= maxInt32Rows {
		return fmt.Errorf("max products must be between 1 and %d: %w", maxInt32Rows-1, ErrInvalidLimits)
	}
	if l.MaxMovements <= 0 || l.MaxMovements >= maxInt32Rows {
		return fmt.Errorf("max movements must be between 1 and %d: %w", maxInt32Rows-1, ErrInvalidLimits)
	}
	if l.MaxResponseBytes <= 0 || l.MaxRequestBytes <= 0 {
		return ErrInvalidLimits
	}
	return nil
}

// Snapshot is the account-scoped canonical bootstrap data returned by the
// service. Product rows include deleted products; Tombstones is derived by the
// HTTP layer as a compact deletion index for clients that apply tombstones
// separately.
type Snapshot struct {
	Products   []db.Product
	Movements  []db.StockMovement
	Balances   []db.LedgerBalance
	Cursor     int64
	ServerTime time.Time
}

// Service reads a complete account replica using one PostgreSQL snapshot.
type Service struct {
	beginner db.TxBeginner
	limits   Limits
}

// NewService creates a snapshot service bound to a PostgreSQL transaction
// beginner. The optional limits argument is useful for deployments and tests;
// omitted values use the safe v1 defaults.
func NewService(beginner db.TxBeginner, configured ...Limits) (*Service, error) {
	if beginner == nil {
		return nil, errors.New("snapshot transaction beginner must not be nil")
	}
	limits := DefaultLimits()
	if len(configured) > 0 {
		limits = configured[0].withDefaults()
	}
	if len(configured) > 1 {
		return nil, fmt.Errorf("only one snapshot limits value is allowed: %w", ErrInvalidLimits)
	}
	if err := limits.validate(); err != nil {
		return nil, err
	}
	return &Service{beginner: beginner, limits: limits}, nil
}

// GetSnapshot reads products, retained movements, ledger-derived balances, the
// cursor high-water mark, and PostgreSQL's transaction timestamp from one
// repeatable-read, read-only transaction.
func (s *Service) GetSnapshot(ctx context.Context, userID uuid.UUID) (Snapshot, error) {
	if s == nil || userID == uuid.Nil {
		return Snapshot{}, ErrInvalidUser
	}
	return db.WithSnapshotResult(ctx, s.beginner, func(queries *db.Queries) (Snapshot, error) {
		products, truncated, err := queries.ListSnapshotProducts(ctx, userID, s.limits.MaxProducts)
		if err != nil {
			return Snapshot{}, err
		}
		if truncated {
			return Snapshot{}, ErrSnapshotTooLarge
		}

		movements, truncated, err := queries.ListSnapshotMovements(ctx, userID, s.limits.MaxMovements)
		if err != nil {
			return Snapshot{}, err
		}
		if truncated {
			return Snapshot{}, ErrSnapshotTooLarge
		}

		balances, truncated, err := queries.ListSnapshotBalances(ctx, userID, s.limits.MaxProducts)
		if err != nil {
			return Snapshot{}, err
		}
		if truncated {
			return Snapshot{}, ErrSnapshotTooLarge
		}

		cursor, err := queries.CurrentChangeSequence(ctx)
		if err != nil {
			return Snapshot{}, err
		}
		serverTime, err := queries.CurrentDatabaseTime(ctx)
		if err != nil {
			return Snapshot{}, err
		}
		return Snapshot{
			Products:   products,
			Movements:  movements,
			Balances:   balances,
			Cursor:     cursor,
			ServerTime: serverTime,
		}, nil
	})
}

// Snapshot is intentionally read-only; this alias keeps callers that use the
// shorter method name aligned with the other domain services.
func (s *Service) Snapshot(ctx context.Context, userID uuid.UUID) (Snapshot, error) {
	return s.GetSnapshot(ctx, userID)
}
