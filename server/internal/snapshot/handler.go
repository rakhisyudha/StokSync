package snapshot

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/stoksync/stoksync/server/internal/auth"
)

// ServiceAPI keeps HTTP behavior independent from the PostgreSQL service and
// makes response/error handling directly testable.
type ServiceAPI interface {
	GetSnapshot(context.Context, uuid.UUID) (Snapshot, error)
}

// Handler exposes the authenticated full-replica bootstrap route.
type Handler struct {
	service     ServiceAPI
	requireAuth auth.Middleware
	limits      Limits
}

// NewHandler constructs a snapshot handler. The optional limits argument
// controls request and encoded-response bounds; the service remains
// responsible for bounded database reads.
func NewHandler(service ServiceAPI, requireAuth auth.Middleware, configured ...Limits) *Handler {
	limits := DefaultLimits()
	if len(configured) > 0 {
		limits = configured[0].withDefaults()
		if limits.validate() != nil {
			limits = DefaultLimits()
		}
	}
	return &Handler{service: service, requireAuth: requireAuth, limits: limits}
}

// Routes returns a Chi-compatible route mounted by the process-level router.
// The handler checks the identity itself as a defense in depth measure, so a
// nil middleware cannot accidentally expose account data.
func (h *Handler) Routes() http.Handler {
	router := chi.NewRouter()
	protected := http.Handler(http.HandlerFunc(h.get))
	if h.requireAuth != nil {
		protected = h.requireAuth(protected)
	}
	router.Get("/", protected.ServeHTTP)
	return router
}

// SnapshotResponse is the versioned wire representation of a complete
// account bootstrap. Products includes active rows and deleted rows; the
// compact tombstones array makes deletion handling explicit for clients that
// apply tombstones independently from product upserts.
type SnapshotResponse struct {
	SchemaVersion int                 `json:"schema_version"`
	Products      []SnapshotProduct   `json:"products"`
	Movements     []SnapshotMovement  `json:"movements"`
	Balances      []SnapshotBalance   `json:"balances"`
	Tombstones    []SnapshotTombstone `json:"tombstones"`
	Cursor        int64               `json:"cursor"`
	ServerTime    time.Time           `json:"server_time"`
}

type SnapshotProduct struct {
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

type SnapshotMovement struct {
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

type SnapshotBalance struct {
	ProductID      string     `json:"product_id"`
	Qty            int64      `json:"qty"`
	LastMovementAt *time.Time `json:"last_movement_at"`
}

type SnapshotTombstone struct {
	ID                string    `json:"id"`
	Version           int64     `json:"version"`
	DeletedAt         time.Time `json:"deleted_at"`
	UpdatedAt         time.Time `json:"updated_at"`
	UpdatedByDeviceID string    `json:"updated_by_device_id"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	identity, ok := auth.IdentityFromContext(r.Context())
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="stoksync"`)
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if malformedRequest(r, h.limits.MaxRequestBytes) {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if h.service == nil {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}

	data, err := h.service.GetSnapshot(r.Context(), identity.UserID)
	if err != nil {
		writeSnapshotError(w, err)
		return
	}
	response := responseFromSnapshot(data)
	var body boundedResponseBuffer
	body.max = h.limits.MaxResponseBytes
	if err := json.NewEncoder(&body).Encode(response); err != nil && !body.exceeded {
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if body.exceeded || body.Len() > h.limits.MaxResponseBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "snapshot_too_large")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body.Bytes())
}

type boundedResponseBuffer struct {
	bytes.Buffer
	max      int
	exceeded bool
}

func (b *boundedResponseBuffer) Write(value []byte) (int, error) {
	remaining := b.max - b.Len()
	if remaining <= 0 {
		b.exceeded = true
		return 0, ErrSnapshotTooLarge
	}
	if len(value) > remaining {
		_, _ = b.Buffer.Write(value[:remaining])
		b.exceeded = true
		return remaining, ErrSnapshotTooLarge
	}
	return b.Buffer.Write(value)
}

func malformedRequest(r *http.Request, maxBytes int) bool {
	if r == nil || r.URL == nil || r.URL.RawQuery != "" {
		return true
	}
	if r.Body == nil || r.Body == http.NoBody {
		return false
	}
	if maxBytes <= 0 {
		return true
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, int64(maxBytes)+1))
	return err != nil || len(body) != 0
}

func responseFromSnapshot(data Snapshot) SnapshotResponse {
	response := SnapshotResponse{
		SchemaVersion: SchemaVersion,
		Products:      make([]SnapshotProduct, 0, len(data.Products)),
		Movements:     make([]SnapshotMovement, 0, len(data.Movements)),
		Balances:      make([]SnapshotBalance, 0, len(data.Balances)),
		Tombstones:    make([]SnapshotTombstone, 0),
		Cursor:        data.Cursor,
		ServerTime:    data.ServerTime.UTC(),
	}
	for _, product := range data.Products {
		responseProduct := SnapshotProduct{
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
		}
		response.Products = append(response.Products, responseProduct)
		if product.DeletedAt != nil {
			response.Tombstones = append(response.Tombstones, SnapshotTombstone{
				ID:                product.ID.String(),
				Version:           product.Version,
				DeletedAt:         product.DeletedAt.UTC(),
				UpdatedAt:         product.UpdatedAt.UTC(),
				UpdatedByDeviceID: product.UpdatedByDeviceID.String(),
			})
		}
	}
	for _, movement := range data.Movements {
		var reversesID *string
		if movement.ReversesID != nil {
			value := movement.ReversesID.String()
			reversesID = &value
		}
		response.Movements = append(response.Movements, SnapshotMovement{
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
	for _, balance := range data.Balances {
		response.Balances = append(response.Balances, SnapshotBalance{
			ProductID:      balance.ProductID.String(),
			Qty:            balance.Qty,
			LastMovementAt: cloneTime(balance.LastMovementAt),
		})
	}
	return response
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

func writeSnapshotError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrSnapshotTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, "snapshot_too_large")
	case errors.Is(err, ErrInvalidUser):
		writeError(w, http.StatusUnauthorized, "unauthorized")
	default:
		writeError(w, http.StatusInternalServerError, "internal_error")
	}
}

func writeError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(errorResponse{Error: code})
}
