package products

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/stoksync/stoksync/server/internal/db"
)

func TestProductServiceRejectsInvalidInputBeforeStartingTransaction(t *testing.T) {
	beginner := &countingBeginner{}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}

	_, err = service.CreateProduct(context.Background(), CreateProductInput{
		UserID:            uuid.New(),
		Name:              "missing product id",
		UpdatedByDeviceID: uuid.New(),
	})
	if !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("CreateProduct() error = %v, want ErrInvalidInput", err)
	}
	if beginner.beginCalls != 0 {
		t.Fatalf("transaction begin calls = %d, want 0 for invalid input", beginner.beginCalls)
	}
}

func TestNormalizeProductInputAppliesDefaultsWithoutMutatingCallerPointers(t *testing.T) {
	barcode := "  089686010947  "
	minStock := int32(24)
	input := CreateProductInput{
		ID:                uuid.New(),
		UserID:            uuid.New(),
		Barcode:           &barcode,
		Name:              "  Noodles  ",
		MinStock:          &minStock,
		UpdatedByDeviceID: uuid.New(),
	}

	normalized, err := normalizeCreateInput(input)
	if err != nil {
		t.Fatalf("normalizeCreateInput() error = %v", err)
	}
	if normalized.Name != "Noodles" || normalized.Unit != defaultUnit {
		t.Errorf("normalized name/unit = (%q, %q), want trimmed name and %q", normalized.Name, normalized.Unit, defaultUnit)
	}
	if normalized.Barcode == nil || *normalized.Barcode != "089686010947" {
		t.Errorf("normalized barcode = %v, want trimmed barcode", normalized.Barcode)
	}
	if input.Barcode == nil || *input.Barcode != barcode {
		t.Errorf("caller barcode = %v, want unchanged %q", input.Barcode, barcode)
	}
}

func TestProductServiceMapsPostgresDomainConstraints(t *testing.T) {
	tests := []struct {
		name       string
		constraint string
		want       error
	}{
		{name: "barcode", constraint: "products_active_barcode_uq", want: ErrBarcodeConflict},
		{name: "device ownership", constraint: "products_updated_by_device_owner_fkey", want: ErrOwnershipViolation},
		{name: "duplicate id", constraint: "products_pkey", want: ErrProductConflict},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := mapMutationError(&pgconn.PgError{ConstraintName: tt.constraint})
			if !errors.Is(err, tt.want) {
				t.Fatalf("mapped error = %v, want %v", err, tt.want)
			}
		})
	}
}

type countingBeginner struct {
	beginCalls int
}

func (b *countingBeginner) BeginTx(context.Context) (db.Tx, error) {
	b.beginCalls++
	return nil, errors.New("unexpected transaction")
}
