// Package products contains account-scoped canonical catalog transactions.
package products

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/stoksync/stoksync/server/internal/db"
)

var (
	// ErrInvalidInput means a product mutation cannot satisfy the domain
	// shape before it reaches PostgreSQL.
	ErrInvalidInput = errors.New("invalid product input")
	// ErrProductNotFound means no product exists for the supplied identifier.
	ErrProductNotFound = errors.New("product not found")
	// ErrProductDeleted means the product is retained as a tombstone and cannot
	// receive another active-catalog mutation.
	ErrProductDeleted = errors.New("product is deleted")
	// ErrVersionConflict means the caller edited an older product version.
	ErrVersionConflict = errors.New("product version conflict")
	// ErrBarcodeConflict means an active product already owns the barcode.
	ErrBarcodeConflict = errors.New("barcode already belongs to an active product")
	// ErrOwnershipViolation means the user/device relationship does not permit
	// the requested mutation.
	ErrOwnershipViolation = errors.New("product ownership violation")
	// ErrProductConflict is used for a duplicate product identifier.
	ErrProductConflict = errors.New("product already exists")

	// Compatibility aliases make the domain distinction explicit at call sites
	// that prefer the longer names.
	ErrProductVersionConflict = ErrVersionConflict
	ErrStaleVersion           = ErrVersionConflict
	ErrDeletedProduct         = ErrProductDeleted
)

const (
	// ActiveBarcodeUniqueIndex is the PostgreSQL partial unique index that
	// rejects duplicate barcodes among non-deleted products.
	ActiveBarcodeUniqueIndex = "products_active_barcode_uq"

	defaultUnit = "pcs"
)

// Service owns canonical product mutations. It accepts the transaction
// beginner interface rather than a concrete pool so transaction behavior can
// be tested without a live database; *db.Pool satisfies the interface.
type Service struct {
	beginner db.TxBeginner
}

// NewService creates a product service bound to a PostgreSQL transaction
// beginner.
func NewService(beginner db.TxBeginner) (*Service, error) {
	if beginner == nil {
		return nil, errors.New("product transaction beginner must not be nil")
	}
	return &Service{beginner: beginner}, nil
}

// CreateProductInput is the client-owned canonical product shape. It aliases
// the typed database parameters so service and synchronization layers can
// share a stable wire-to-domain mapping without copying fields.
type CreateProductInput = db.CreateProductParams

// UpdateProductInput is a complete version-checked product edit.
type UpdateProductInput = db.UpdateProductParams

// SoftDeleteProductInput identifies a delete-wins tombstone operation. The
// base version must be positive; an older active version is intentionally
// accepted so a concurrent edit cannot outrank a deletion.
type SoftDeleteProductInput = db.SoftDeleteProductParams

// CreateInput, UpdateInput, and DeleteInput are concise service-facing names.
type CreateInput = CreateProductInput
type UpdateInput = UpdateProductInput
type DeleteInput = SoftDeleteProductInput

// CreateProduct inserts a product and initializes its zero balance projection
// in the same transaction. The ledger remains empty until a movement is
// appended.
func (s *Service) CreateProduct(ctx context.Context, input CreateProductInput) (db.Product, error) {
	normalized, err := normalizeCreateInput(input)
	if err != nil {
		return db.Product{}, err
	}
	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (db.Product, error) {
		return s.createProductInTransaction(ctx, queries, normalized)
	})
}

// CreateProductInTransaction applies a product create using the supplied
// transaction-bound queries. Callers such as synchronization must use this
// method rather than CreateProduct so domain and sync writes share one tx.
func (s *Service) CreateProductInTransaction(ctx context.Context, queries *db.Queries, input CreateProductInput) (db.Product, error) {
	if s == nil || queries == nil {
		return db.Product{}, ErrInvalidInput
	}
	normalized, err := normalizeCreateInput(input)
	if err != nil {
		return db.Product{}, err
	}
	return s.createProductInTransaction(ctx, queries, normalized)
}

func (s *Service) createProductInTransaction(ctx context.Context, queries *db.Queries, input CreateProductInput) (db.Product, error) {
	product, err := queries.InsertProduct(ctx, input)
	if err != nil {
		return db.Product{}, mapMutationError(err)
	}
	if _, err := queries.UpsertProductBalance(ctx, db.UpsertProductBalanceParams{
		UserID:    input.UserID,
		ProductID: input.ID,
		Qty:       0,
	}); err != nil {
		return db.Product{}, mapMutationError(err)
	}
	return product, nil
}

// Create is a concise alias for CreateProduct.
func (s *Service) Create(ctx context.Context, input CreateInput) (db.Product, error) {
	return s.CreateProduct(ctx, input)
}

// UpdateProduct performs a full optimistic-concurrency edit. A stale base
// version is classified separately from a missing, deleted, or cross-owner
// product so the future sync layer can make an explicit conflict decision.
func (s *Service) UpdateProduct(ctx context.Context, input UpdateProductInput) (db.Product, error) {
	normalized, err := normalizeUpdateInput(input)
	if err != nil {
		return db.Product{}, err
	}
	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (db.Product, error) {
		return s.updateProductInTransaction(ctx, queries, normalized)
	})
}

// UpdateProductInTransaction applies a version-checked product edit using
// transaction-bound queries supplied by an outer synchronization transaction.
func (s *Service) UpdateProductInTransaction(ctx context.Context, queries *db.Queries, input UpdateProductInput) (db.Product, error) {
	if s == nil || queries == nil {
		return db.Product{}, ErrInvalidInput
	}
	normalized, err := normalizeUpdateInput(input)
	if err != nil {
		return db.Product{}, err
	}
	return s.updateProductInTransaction(ctx, queries, normalized)
}

func (s *Service) updateProductInTransaction(ctx context.Context, queries *db.Queries, input UpdateProductInput) (db.Product, error) {
	product, err := queries.UpdateProduct(ctx, input)
	if err == nil {
		return product, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return db.Product{}, mapMutationError(err)
	}
	return db.Product{}, classifyProductMutationMiss(ctx, queries, input.UserID, input.ID)
}

// Update is a concise alias for UpdateProduct.
func (s *Service) Update(ctx context.Context, input UpdateInput) (db.Product, error) {
	return s.UpdateProduct(ctx, input)
}

// SoftDeleteProduct records a tombstone without removing the product or any
// of its immutable stock movements. The product balance is intentionally left
// intact for audit and historical reporting.
func (s *Service) SoftDeleteProduct(ctx context.Context, input SoftDeleteProductInput) (db.Product, error) {
	normalized, err := normalizeDeleteInput(input)
	if err != nil {
		return db.Product{}, err
	}
	return db.WithTxResult(ctx, s.beginner, func(queries *db.Queries) (db.Product, error) {
		return s.softDeleteProductInTransaction(ctx, queries, normalized)
	})
}

// SoftDeleteProductInTransaction applies a version-checked tombstone using
// transaction-bound queries supplied by an outer synchronization transaction.
func (s *Service) SoftDeleteProductInTransaction(ctx context.Context, queries *db.Queries, input SoftDeleteProductInput) (db.Product, error) {
	if s == nil || queries == nil {
		return db.Product{}, ErrInvalidInput
	}
	normalized, err := normalizeDeleteInput(input)
	if err != nil {
		return db.Product{}, err
	}
	return s.softDeleteProductInTransaction(ctx, queries, normalized)
}

func (s *Service) softDeleteProductInTransaction(ctx context.Context, queries *db.Queries, input SoftDeleteProductInput) (db.Product, error) {
	product, err := queries.SoftDeleteProduct(ctx, input)
	if err == nil {
		return product, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return db.Product{}, mapMutationError(err)
	}
	return db.Product{}, classifyProductMutationMiss(ctx, queries, input.UserID, input.ID)
}

// DeleteProduct is an explicit alias for the soft-delete operation.
func (s *Service) DeleteProduct(ctx context.Context, input DeleteInput) (db.Product, error) {
	return s.SoftDeleteProduct(ctx, input)
}

func normalizeCreateInput(input CreateProductInput) (CreateProductInput, error) {
	if input.ID == uuid.Nil || input.UserID == uuid.Nil || input.UpdatedByDeviceID == uuid.Nil {
		return CreateProductInput{}, ErrInvalidInput
	}
	input.Name = strings.TrimSpace(input.Name)
	if input.Name == "" {
		return CreateProductInput{}, ErrInvalidInput
	}
	input.Unit = strings.TrimSpace(input.Unit)
	if input.Unit == "" {
		input.Unit = defaultUnit
	}
	input.Barcode = normalizeOptionalString(input.Barcode)
	input.SKU = normalizeOptionalString(input.SKU)
	input.Description = normalizeOptionalString(input.Description)
	input.Category = normalizeOptionalString(input.Category)
	if input.MinStock != nil && *input.MinStock < 0 {
		return CreateProductInput{}, ErrInvalidInput
	}
	return input, nil
}

func normalizeUpdateInput(input UpdateProductInput) (UpdateProductInput, error) {
	if input.ID == uuid.Nil || input.UserID == uuid.Nil || input.UpdatedByDeviceID == uuid.Nil || input.BaseVersion <= 0 {
		return UpdateProductInput{}, ErrInvalidInput
	}
	input.Name = strings.TrimSpace(input.Name)
	if input.Name == "" {
		return UpdateProductInput{}, ErrInvalidInput
	}
	input.Unit = strings.TrimSpace(input.Unit)
	if input.Unit == "" {
		input.Unit = defaultUnit
	}
	input.Barcode = normalizeOptionalString(input.Barcode)
	input.SKU = normalizeOptionalString(input.SKU)
	input.Description = normalizeOptionalString(input.Description)
	input.Category = normalizeOptionalString(input.Category)
	if input.MinStock != nil && *input.MinStock < 0 {
		return UpdateProductInput{}, ErrInvalidInput
	}
	return input, nil
}

func normalizeDeleteInput(input SoftDeleteProductInput) (SoftDeleteProductInput, error) {
	if input.ID == uuid.Nil || input.UserID == uuid.Nil || input.UpdatedByDeviceID == uuid.Nil || input.BaseVersion <= 0 {
		return SoftDeleteProductInput{}, ErrInvalidInput
	}
	return input, nil
}

func normalizeOptionalString(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func classifyProductMutationMiss(ctx context.Context, queries *db.Queries, userID, productID uuid.UUID) error {
	product, err := queries.GetProductByID(ctx, productID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrProductNotFound
	}
	if err != nil {
		return err
	}
	if product.UserID != userID {
		return ErrOwnershipViolation
	}
	if product.DeletedAt != nil {
		return ErrProductDeleted
	}
	return ErrVersionConflict
}

func mapMutationError(err error) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return err
	}
	switch pgErr.ConstraintName {
	case ActiveBarcodeUniqueIndex:
		return ErrBarcodeConflict
	case "products_updated_by_device_id_fkey", "products_updated_by_device_owner_fkey", "products_user_id_fkey":
		return ErrOwnershipViolation
	case "products_pkey":
		return ErrProductConflict
	case "products_version_positive_check":
		return ErrInvalidInput
	default:
		return err
	}
}
