package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
	"github.com/stoksync/stoksync/server/internal/movements"
	"github.com/stoksync/stoksync/server/internal/products"
)

const (
	ReasonInvalidOperation    = "invalid_operation"
	ReasonInvalidProduct      = "invalid_product"
	ReasonInvalidMovement     = "invalid_movement"
	ReasonInvalidDelta        = "invalid_delta"
	ReasonInvalidMovementKind = "invalid_movement_kind"
	ReasonInvalidReversal     = "invalid_reversal"
	ReasonInvalidStocktake    = "invalid_stocktake"
	ReasonMovementNotFound    = "movement_not_found"
	ReasonInvalidBaseVersion  = "invalid_base_version"
	ReasonProductNotFound     = "product_not_found"
	ReasonProductDeleted      = "product_deleted"
	ReasonVersionConflict     = "version_conflict"
	ReasonBarcodeConflict     = "barcode_conflict"
	ReasonProductConflict     = "product_conflict"
	ReasonMovementConflict    = "movement_conflict"
	ReasonOwnershipViolation  = "ownership_violation"
	ReasonDeviceMismatch      = "device_mismatch"

	syncOperationStatusProcessing = "processing"

	changeEntityProduct  = "product"
	changeEntityMovement = "stock_movement"
	changeOpUpsert       = "upsert"
	changeOpDelete       = "delete"

	productMutationSavepoint = "stoksync_product_mutation"
)

var ErrInvalidStoredOperationResponse = errors.New("stored sync operation response is invalid")

type operationChange struct {
	Entity   string
	Op       string
	EntityID uuid.UUID
	Payload  []byte
}

// processOperation reserves the idempotency key before applying domain logic,
// then finalizes the same row only after the canonical mutation and change-log
// entry succeed. Because the caller wraps this callback in db.WithTxResult,
// every intermediate write rolls back together on any error.
func (s *Service) processOperation(ctx context.Context, queries *db.Queries, identity auth.Identity, operation Operation) (OperationResult, error) {
	if queries == nil {
		return OperationResult{}, ErrInvalidService
	}
	if operation.OpID == uuid.Nil {
		return OperationResult{}, ErrInvalidOperation
	}

	if _, inserted, err := queries.TryInsertSyncOperation(ctx, db.InsertSyncOperationParams{
		UserID:   identity.UserID,
		DeviceID: identity.DeviceID,
		OpID:     operation.OpID,
		Status:   syncOperationStatusProcessing,
		Response: []byte(`{}`),
	}); err != nil {
		return OperationResult{}, err
	} else if !inserted {
		stored, err := queries.GetSyncOperation(ctx, identity.UserID, identity.DeviceID, operation.OpID)
		if err != nil {
			return OperationResult{}, fmt.Errorf("%w: lookup failed: %v", ErrInvalidStoredOperationResponse, err)
		}
		return replayStoredOperation(identity, operation.OpID, stored)
	}

	result, change, err := s.applyOperation(ctx, queries, identity, operation)
	if err != nil {
		return OperationResult{}, err
	}
	if change != nil {
		entry, err := queries.AppendChangeLog(ctx, db.AppendChangeLogParams{
			UserID:         identity.UserID,
			Entity:         change.Entity,
			EntityID:       change.EntityID,
			Op:             change.Op,
			Payload:        change.Payload,
			OriginDeviceID: &identity.DeviceID,
		})
		if err != nil {
			return OperationResult{}, err
		}
		seq := entry.Seq
		result.Seq = &seq
	}
	if err := s.finalizeOperation(ctx, queries, identity, operation.OpID, result); err != nil {
		return OperationResult{}, err
	}
	return result, nil
}

func replayStoredOperation(identity auth.Identity, operationID uuid.UUID, stored db.SyncOperation) (OperationResult, error) {
	if stored.UserID != identity.UserID || stored.DeviceID != identity.DeviceID || stored.OpID != operationID {
		return OperationResult{}, fmt.Errorf("%w: stored operation scope does not match request", ErrInvalidStoredOperationResponse)
	}
	if len(bytes.TrimSpace(stored.Response)) == 0 {
		return OperationResult{}, fmt.Errorf("%w: response is empty", ErrInvalidStoredOperationResponse)
	}

	decoder := json.NewDecoder(bytes.NewReader(stored.Response))
	decoder.DisallowUnknownFields()
	var result OperationResult
	if err := decoder.Decode(&result); err != nil {
		return OperationResult{}, fmt.Errorf("%w: decode response: %v", ErrInvalidStoredOperationResponse, err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return OperationResult{}, fmt.Errorf("%w: response contains trailing JSON", ErrInvalidStoredOperationResponse)
		}
		return OperationResult{}, fmt.Errorf("%w: response contains trailing data: %v", ErrInvalidStoredOperationResponse, err)
	}
	if result.OpID != operationID {
		return OperationResult{}, fmt.Errorf("%w: response operation id does not match request", ErrInvalidStoredOperationResponse)
	}

	validation := NewSyncResponse(
		[]OperationResult{result},
		[]ChangeEntry{},
		0,
		false,
		time.Unix(0, 0).UTC(),
	).Validate()
	if validation != nil {
		return OperationResult{}, fmt.Errorf("%w: invalid operation result: %v", ErrInvalidStoredOperationResponse, validation)
	}
	return result, nil
}

func (s *Service) applyOperation(ctx context.Context, queries *db.Queries, identity auth.Identity, operation Operation) (OperationResult, *operationChange, error) {
	if err := operation.Validate(); err != nil {
		return rejectedResult(operation.OpID, ReasonInvalidOperation), nil, nil
	}

	switch operation.Op {
	case OperationAddMovement:
		return s.applyMovement(ctx, queries, identity, operation)
	case OperationUpsertProduct:
		return s.applyProductUpsert(ctx, queries, identity, operation)
	case OperationDeleteProduct:
		return s.applyProductDelete(ctx, queries, identity, operation)
	default:
		return rejectedResult(operation.OpID, ReasonInvalidOperation), nil, nil
	}
}

func (s *Service) applyMovement(ctx context.Context, queries *db.Queries, identity auth.Identity, operation Operation) (OperationResult, *operationChange, error) {
	decoded, err := operation.DecodePayload()
	if err != nil {
		return rejectedResult(operation.OpID, ReasonInvalidOperation), nil, nil
	}
	payload := decoded.(AddMovementPayload)
	if payload.DeviceID != nil && *payload.DeviceID != identity.DeviceID {
		return rejectedResult(operation.OpID, ReasonDeviceMismatch), nil, nil
	}

	movement, err := s.movementService.AppendMovementInTransaction(ctx, queries, movements.AppendInput{
		ID:            payload.ID,
		UserID:        identity.UserID,
		ProductID:     payload.ProductID,
		Delta:         payload.Delta,
		Kind:          payload.Kind,
		Note:          payload.Note,
		OccurredAt:    payload.OccurredAt,
		RawOccurredAt: valueOrZeroTime(payload.RawOccurredAt),
		ClockOffsetMs: payload.ClockOffsetMs,
		CountedQty:    payload.CountedQty,
		ReversesID:    payload.ReversesID,
		DeviceID:      identity.DeviceID,
	})
	if err != nil {
		if result, ok := rejectedForDomainError(operation.OpID, err); ok {
			return result, nil, nil
		}
		return OperationResult{}, nil, err
	}
	payloadJSON, err := marshalMovementChange(movement)
	if err != nil {
		return OperationResult{}, nil, err
	}
	return OperationResult{OpID: operation.OpID, Status: ResultStatusApplied}, &operationChange{
		Entity:   changeEntityMovement,
		Op:       changeOpUpsert,
		EntityID: movement.ID,
		Payload:  payloadJSON,
	}, nil
}

func (s *Service) applyProductUpsert(ctx context.Context, queries *db.Queries, identity auth.Identity, operation Operation) (OperationResult, *operationChange, error) {
	decoded, err := operation.DecodePayload()
	if err != nil {
		return rejectedResult(operation.OpID, ReasonInvalidOperation), nil, nil
	}
	payload := decoded.(UpsertProductPayload)

	current, lookupErr := queries.GetProductByID(ctx, payload.ID)
	if lookupErr != nil && !errors.Is(lookupErr, pgx.ErrNoRows) {
		return OperationResult{}, nil, lookupErr
	}

	var product db.Product
	var mutate func() (db.Product, error)
	if errors.Is(lookupErr, pgx.ErrNoRows) {
		// A create has no canonical version to compare against. Permit an
		// omitted or zero base_version, but reject a positive version because
		// it would claim an existing canonical revision that was never present.
		if operation.BaseVersion != nil && *operation.BaseVersion != 0 {
			return rejectedResult(operation.OpID, ReasonInvalidBaseVersion), nil, nil
		}
		mutate = func() (db.Product, error) {
			return s.productService.CreateProductInTransaction(ctx, queries, products.CreateProductInput{
				ID:                payload.ID,
				UserID:            identity.UserID,
				Barcode:           payload.Barcode,
				SKU:               payload.SKU,
				Name:              payload.Name,
				Description:       payload.Description,
				Unit:              payload.Unit,
				Category:          payload.Category,
				MinStock:          payload.MinStock,
				UpdatedByDeviceID: identity.DeviceID,
			})
		}
	} else {
		if current.UserID != identity.UserID {
			return rejectedResult(operation.OpID, ReasonOwnershipViolation), nil, nil
		}
		if current.DeletedAt != nil {
			result := rejectedResult(operation.OpID, ReasonProductDeleted)
			result.ServerState = productState(current)
			return result, nil, nil
		}
		if operation.BaseVersion == nil || *operation.BaseVersion <= 0 {
			return rejectedResult(operation.OpID, ReasonInvalidBaseVersion), nil, nil
		}
		mutate = func() (db.Product, error) {
			return s.productService.UpdateProductInTransaction(ctx, queries, products.UpdateProductInput{
				ID:                payload.ID,
				UserID:            identity.UserID,
				Barcode:           payload.Barcode,
				SKU:               payload.SKU,
				Name:              payload.Name,
				Description:       payload.Description,
				Unit:              payload.Unit,
				Category:          payload.Category,
				MinStock:          payload.MinStock,
				BaseVersion:       *operation.BaseVersion,
				UpdatedByDeviceID: identity.DeviceID,
			})
		}
	}
	product, err = runProductMutationWithBarcodeRecovery(ctx, queries, mutate)
	if err != nil {
		result, ok := rejectedForDomainError(operation.OpID, err)
		if !ok {
			return OperationResult{}, nil, err
		}
		if errors.Is(err, products.ErrBarcodeConflict) {
			if err := attachCanonicalBarcodeProductState(
				ctx,
				queries,
				identity.UserID,
				normalizeBarcode(payload.Barcode),
				&result,
			); err != nil {
				return OperationResult{}, nil, err
			}
		}
		if errors.Is(err, products.ErrVersionConflict) || errors.Is(err, products.ErrProductDeleted) {
			if err := attachCanonicalProductState(ctx, queries, identity.UserID, payload.ID, &result); err != nil {
				return OperationResult{}, nil, err
			}
		}
		return result, nil, nil
	}

	payloadJSON, err := marshalProductChange(product)
	if err != nil {
		return OperationResult{}, nil, err
	}
	return OperationResult{OpID: operation.OpID, Status: ResultStatusApplied}, &operationChange{
		Entity:   changeEntityProduct,
		Op:       changeOpUpsert,
		EntityID: product.ID,
		Payload:  payloadJSON,
	}, nil
}

func (s *Service) applyProductDelete(ctx context.Context, queries *db.Queries, identity auth.Identity, operation Operation) (OperationResult, *operationChange, error) {
	decoded, err := operation.DecodePayload()
	if err != nil {
		return rejectedResult(operation.OpID, ReasonInvalidOperation), nil, nil
	}
	payload := decoded.(DeleteProductPayload)
	if operation.BaseVersion == nil || *operation.BaseVersion <= 0 {
		return rejectedResult(operation.OpID, ReasonInvalidBaseVersion), nil, nil
	}

	product, err := s.productService.SoftDeleteProductInTransaction(ctx, queries, products.SoftDeleteProductInput{
		ID:                payload.ID,
		UserID:            identity.UserID,
		BaseVersion:       *operation.BaseVersion,
		UpdatedByDeviceID: identity.DeviceID,
	})
	if err != nil {
		if result, ok := rejectedForDomainError(operation.OpID, err); ok {
			if errors.Is(err, products.ErrVersionConflict) || errors.Is(err, products.ErrProductDeleted) {
				if err := attachCanonicalProductState(ctx, queries, identity.UserID, payload.ID, &result); err != nil {
					return OperationResult{}, nil, err
				}
			}
			return result, nil, nil
		}
		return OperationResult{}, nil, err
	}
	payloadJSON, err := marshalProductChange(product)
	if err != nil {
		return OperationResult{}, nil, err
	}
	return OperationResult{OpID: operation.OpID, Status: ResultStatusApplied}, &operationChange{
		Entity:   changeEntityProduct,
		Op:       changeOpDelete,
		EntityID: product.ID,
		Payload:  payloadJSON,
	}, nil
}

func runProductMutationWithBarcodeRecovery(
	ctx context.Context,
	queries *db.Queries,
	mutate func() (db.Product, error),
) (db.Product, error) {
	if queries == nil || mutate == nil {
		return db.Product{}, ErrInvalidService
	}
	if _, err := queries.DB().Exec(ctx, "SAVEPOINT "+productMutationSavepoint); err != nil {
		return db.Product{}, err
	}

	product, err := mutate()
	if err == nil {
		if _, releaseErr := queries.DB().Exec(ctx, "RELEASE SAVEPOINT "+productMutationSavepoint); releaseErr != nil {
			return db.Product{}, releaseErr
		}
		return product, nil
	}
	if !errors.Is(err, products.ErrBarcodeConflict) {
		// Validation and optimistic-concurrency misses do not abort PostgreSQL;
		// release the savepoint so the enclosing transaction can persist their
		// stable rejected result. Unexpected database errors abort the enclosing
		// transaction and are returned unchanged.
		_, _ = queries.DB().Exec(ctx, "RELEASE SAVEPOINT "+productMutationSavepoint)
		return db.Product{}, err
	}

	// A unique-index violation aborts the current PostgreSQL statement. Roll
	// back only this mutation so the enclosing operation transaction can still
	// read the canonical owner and persist a rejected idempotency outcome.
	if _, rollbackErr := queries.DB().Exec(ctx, "ROLLBACK TO SAVEPOINT "+productMutationSavepoint); rollbackErr != nil {
		return db.Product{}, rollbackErr
	}
	if _, releaseErr := queries.DB().Exec(ctx, "RELEASE SAVEPOINT "+productMutationSavepoint); releaseErr != nil {
		return db.Product{}, releaseErr
	}
	return db.Product{}, err
}

func (s *Service) finalizeOperation(ctx context.Context, queries *db.Queries, identity auth.Identity, opID uuid.UUID, result OperationResult) error {
	response, err := json.Marshal(result)
	if err != nil {
		return err
	}
	var reason *string
	if result.Reason != "" {
		reasonValue := result.Reason
		reason = &reasonValue
	}
	completedAt := time.Now().UTC()
	if s != nil && s.now != nil {
		completedAt = s.now().UTC()
	}
	_, err = queries.UpdateSyncOperation(ctx, db.UpdateSyncOperationParams{
		UserID:      identity.UserID,
		DeviceID:    identity.DeviceID,
		OpID:        opID,
		Status:      result.Status,
		Reason:      reason,
		Response:    response,
		CompletedAt: &completedAt,
	})
	return err
}

func rejectedResult(opID uuid.UUID, reason string) OperationResult {
	return OperationResult{OpID: opID, Status: ResultStatusRejected, Reason: reason}
}

func rejectedForDomainError(opID uuid.UUID, err error) (OperationResult, bool) {
	switch {
	case errors.Is(err, products.ErrInvalidInput):
		return rejectedResult(opID, ReasonInvalidProduct), true
	case errors.Is(err, products.ErrProductNotFound):
		return rejectedResult(opID, ReasonProductNotFound), true
	case errors.Is(err, products.ErrProductDeleted):
		return rejectedResult(opID, ReasonProductDeleted), true
	case errors.Is(err, products.ErrVersionConflict):
		return rejectedResult(opID, ReasonVersionConflict), true
	case errors.Is(err, products.ErrBarcodeConflict):
		return rejectedResult(opID, ReasonBarcodeConflict), true
	case errors.Is(err, products.ErrProductConflict):
		return rejectedResult(opID, ReasonProductConflict), true
	case errors.Is(err, products.ErrOwnershipViolation):
		return rejectedResult(opID, ReasonOwnershipViolation), true
	case errors.Is(err, movements.ErrInvalidInput):
		return rejectedResult(opID, ReasonInvalidMovement), true
	case errors.Is(err, movements.ErrInvalidDelta):
		return rejectedResult(opID, ReasonInvalidDelta), true
	case errors.Is(err, movements.ErrInvalidKind):
		return rejectedResult(opID, ReasonInvalidMovementKind), true
	case errors.Is(err, movements.ErrInvalidReversal):
		return rejectedResult(opID, ReasonInvalidReversal), true
	case errors.Is(err, movements.ErrMovementNotFound):
		return rejectedResult(opID, ReasonMovementNotFound), true
	case errors.Is(err, movements.ErrInvalidStocktake):
		return rejectedResult(opID, ReasonInvalidStocktake), true
	case errors.Is(err, movements.ErrProductNotFound):
		return rejectedResult(opID, ReasonProductNotFound), true
	case errors.Is(err, movements.ErrProductDeleted):
		return rejectedResult(opID, ReasonProductDeleted), true
	case errors.Is(err, movements.ErrMovementConflict):
		return rejectedResult(opID, ReasonMovementConflict), true
	case errors.Is(err, movements.ErrOwnershipViolation):
		return rejectedResult(opID, ReasonOwnershipViolation), true
	default:
		return OperationResult{}, false
	}
}

func valueOrZeroTime(value *time.Time) time.Time {
	if value == nil {
		return time.Time{}
	}
	return *value
}

type productChangePayload struct {
	ID                string     `json:"id"`
	Barcode           *string    `json:"barcode"`
	SKU               *string    `json:"sku"`
	Name              string     `json:"name"`
	Description       *string    `json:"description"`
	Unit              string     `json:"unit"`
	Category          *string    `json:"category"`
	MinStock          *int32     `json:"min_stock"`
	Version           int64      `json:"version"`
	UpdatedAt         time.Time  `json:"updated_at"`
	UpdatedByDeviceID string     `json:"updated_by_device_id"`
	DeletedAt         *time.Time `json:"deleted_at"`
	CreatedAt         time.Time  `json:"created_at"`
}

func marshalProductChange(product db.Product) ([]byte, error) {
	return json.Marshal(productChangePayload{
		ID:                product.ID.String(),
		Barcode:           cloneString(product.Barcode),
		SKU:               cloneString(product.SKU),
		Name:              product.Name,
		Description:       cloneString(product.Description),
		Unit:              product.Unit,
		Category:          cloneString(product.Category),
		MinStock:          cloneInt32(product.MinStock),
		Version:           product.Version,
		UpdatedAt:         product.UpdatedAt.UTC(),
		UpdatedByDeviceID: product.UpdatedByDeviceID.String(),
		DeletedAt:         cloneTime(product.DeletedAt),
		CreatedAt:         product.CreatedAt.UTC(),
	})
}

func productState(product db.Product) json.RawMessage {
	payload, err := marshalProductChange(product)
	if err != nil {
		return nil
	}
	return payload
}

func normalizeBarcode(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func attachCanonicalBarcodeProductState(
	ctx context.Context,
	queries *db.Queries,
	userID uuid.UUID,
	barcode *string,
	result *OperationResult,
) error {
	if result == nil {
		return errors.New("operation result is required")
	}
	if barcode == nil {
		return nil
	}
	product, err := queries.GetActiveProductByBarcode(ctx, userID, *barcode)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	result.ServerState = productState(product)
	return nil
}

func attachCanonicalProductState(ctx context.Context, queries *db.Queries, userID, productID uuid.UUID, result *OperationResult) error {
	if result == nil {
		return errors.New("operation result is required")
	}
	product, err := queries.GetProductByID(ctx, productID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if product.UserID != userID {
		return nil
	}
	result.ServerState = productState(product)
	return nil
}

type movementChangePayload struct {
	ID              string    `json:"id"`
	ProductID       string    `json:"product_id"`
	Delta           int32     `json:"delta"`
	Kind            string    `json:"kind"`
	Note            *string   `json:"note"`
	OccurredAt      time.Time `json:"occurred_at"`
	RawOccurredAt   time.Time `json:"raw_occurred_at"`
	ClockOffsetMs   int64     `json:"clock_offset_ms"`
	CountedQty      *int32    `json:"counted_qty"`
	ReversesID      *string   `json:"reverses_id"`
	DeviceID        string    `json:"device_id"`
	ServerCreatedAt time.Time `json:"server_created_at"`
}

func marshalMovementChange(movement db.StockMovement) ([]byte, error) {
	var reversesID *string
	if movement.ReversesID != nil {
		value := movement.ReversesID.String()
		reversesID = &value
	}
	return json.Marshal(movementChangePayload{
		ID:              movement.ID.String(),
		ProductID:       movement.ProductID.String(),
		Delta:           movement.Delta,
		Kind:            movement.Kind,
		Note:            cloneString(movement.Note),
		OccurredAt:      movement.OccurredAt.UTC(),
		RawOccurredAt:   movement.RawOccurredAt.UTC(),
		ClockOffsetMs:   movement.ClockOffsetMs,
		CountedQty:      cloneInt32(movement.CountedQty),
		ReversesID:      reversesID,
		DeviceID:        movement.DeviceID.String(),
		ServerCreatedAt: movement.ServerCreatedAt.UTC(),
	})
}

func cloneString(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func cloneInt32(value *int32) *int32 {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func cloneTime(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copy := value.UTC()
	return &copy
}
