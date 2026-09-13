package db

import (
	"time"

	"github.com/google/uuid"
)

// Product is the canonical catalog row returned by typed product queries.
type Product struct {
	ID                uuid.UUID
	UserID            uuid.UUID
	Barcode           *string
	SKU               *string
	Name              string
	Description       *string
	Unit              string
	Category          *string
	MinStock          *int32
	Version           int64
	UpdatedAt         time.Time
	UpdatedByDeviceID uuid.UUID
	DeletedAt         *time.Time
	CreatedAt         time.Time
}

// CreateProductParams contains the client-owned fields accepted when a
// product is first inserted. Server-managed timestamps and version defaults
// remain in PostgreSQL.
type CreateProductParams struct {
	ID                uuid.UUID
	UserID            uuid.UUID
	Barcode           *string
	SKU               *string
	Name              string
	Description       *string
	Unit              string
	Category          *string
	MinStock          *int32
	UpdatedByDeviceID uuid.UUID
}

// UpdateProductParams represents a full version-checked product edit. The
// query increments the canonical version only when BaseVersion still matches.
type UpdateProductParams struct {
	ID                uuid.UUID
	UserID            uuid.UUID
	Barcode           *string
	SKU               *string
	Name              string
	Description       *string
	Unit              string
	Category          *string
	MinStock          *int32
	BaseVersion       int64
	UpdatedByDeviceID uuid.UUID
}

// SoftDeleteProductParams identifies a version-checked tombstone operation.
type SoftDeleteProductParams struct {
	ID                uuid.UUID
	UserID            uuid.UUID
	BaseVersion       int64
	UpdatedByDeviceID uuid.UUID
}

// StockMovement is an immutable ledger row. There is intentionally no update
// or delete query for this type.
type StockMovement struct {
	ID              uuid.UUID
	UserID          uuid.UUID
	ProductID       uuid.UUID
	Delta           int32
	Kind            string
	Note            *string
	OccurredAt      time.Time
	RawOccurredAt   time.Time
	ClockOffsetMs   int64
	CountedQty      *int32
	ReversesID      *uuid.UUID
	DeviceID        uuid.UUID
	ServerCreatedAt time.Time
}

// CreateStockMovementParams contains the immutable movement fields supplied by
// a client. The insert query only permits active products owned by UserID.
type CreateStockMovementParams struct {
	ID            uuid.UUID
	UserID        uuid.UUID
	ProductID     uuid.UUID
	Delta         int32
	Kind          string
	Note          *string
	OccurredAt    time.Time
	RawOccurredAt time.Time
	ClockOffsetMs int64
	CountedQty    *int32
	ReversesID    *uuid.UUID
	DeviceID      uuid.UUID
}

// ProductBalance is a rebuildable read projection. StockMovement rows remain
// the source of truth.
type ProductBalance struct {
	ProductID      uuid.UUID
	Qty            int64
	LastMovementAt *time.Time
	UpdatedAt      time.Time
}

// LedgerBalance is the canonical balance computed directly from immutable
// stock_movements. It is intentionally separate from ProductBalance so callers
// cannot mistake the rebuildable projection for the source of truth.
type LedgerBalance struct {
	ProductID      uuid.UUID
	Qty            int64
	LastMovementAt *time.Time
}

// UpsertProductBalanceParams sets a projection value, normally during a
// rebuild or a transaction that has already applied a ledger movement.
type UpsertProductBalanceParams struct {
	UserID         uuid.UUID
	ProductID      uuid.UUID
	Qty            int64
	LastMovementAt *time.Time
}

// IncrementProductBalanceParams increments a projection by one immutable
// movement delta in the same transaction as the movement insert.
type IncrementProductBalanceParams struct {
	UserID     uuid.UUID
	ProductID  uuid.UUID
	Delta      int32
	OccurredAt time.Time
}

// ChangeLogEntry is one canonical incremental-replication event.
type ChangeLogEntry struct {
	Seq            int64
	UserID         uuid.UUID
	Entity         string
	EntityID       uuid.UUID
	Op             string
	Payload        []byte
	OriginDeviceID *uuid.UUID
	CreatedAt      time.Time
}

// InsertChangeLogParams describes a change event written in the same
// transaction as the domain mutation that produced it.
type InsertChangeLogParams struct {
	Seq            int64
	UserID         uuid.UUID
	Entity         string
	EntityID       uuid.UUID
	Op             string
	Payload        []byte
	OriginDeviceID *uuid.UUID
}

// SyncOperation is the durable outcome used to make duplicate delivery
// idempotent. Response contains the exact JSON result to replay.
type SyncOperation struct {
	DeviceID    uuid.UUID
	OpID        uuid.UUID
	UserID      uuid.UUID
	Status      string
	Reason      *string
	Response    []byte
	ReceivedAt  time.Time
	CompletedAt *time.Time
}

// InsertSyncOperationParams is used by the operation transaction after domain
// work has succeeded or been classified as a terminal rejection.
type InsertSyncOperationParams struct {
	DeviceID    uuid.UUID
	OpID        uuid.UUID
	UserID      uuid.UUID
	Status      string
	Reason      *string
	Response    []byte
	CompletedAt *time.Time
}

// ListChangeLogParams bounds an incremental change-feed query.
type ListChangeLogParams struct {
	UserID     uuid.UUID
	AfterSeq   int64
	MaxChanges int32
}
