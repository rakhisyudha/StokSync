package sync

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

const (
	ErrorDeviceMismatch      = "device_mismatch"
	ErrorDeviceNotRegistered = "device_not_registered"
	ErrorInternal            = "internal_error"
)

var ErrRequestDeviceMismatch = errors.New("sync request device does not match authenticated device")

// ServiceAPI keeps HTTP behavior independent from the PostgreSQL-backed
// synchronization service and makes request/error handling directly testable.
type ServiceAPI interface {
	ValidateDevice(context.Context, uuid.UUID, uuid.UUID) error
	ProcessOperation(context.Context, auth.Identity, Operation) (OperationResult, error)
	ListChanges(context.Context, uuid.UUID, int64, int) (ChangeFeed, error)
}

// Handler exposes the authenticated push/pull synchronization boundary. Push
// operations are processed independently first, then the response contains a
// bounded account-scoped change-feed page beginning strictly after the
// request cursor.
type Handler struct {
	service     ServiceAPI
	requireAuth auth.Middleware
	limits      Limits
	now         func() time.Time
}

// NewHandler constructs a sync handler using the protocol's default limits.
// An invalid custom limit is ignored in the same manner as the existing
// snapshot handler; callers can only configure a validated bounded exchange.
func NewHandler(service ServiceAPI, requireAuth auth.Middleware, configured ...Limits) *Handler {
	limits := DefaultLimits()
	if len(configured) > 0 {
		candidate := configured[0].WithDefaults()
		if candidate.Validate() == nil {
			limits = candidate
		}
	}
	return &Handler{
		service:     service,
		requireAuth: requireAuth,
		limits:      limits,
		now:         time.Now,
	}
}

// Routes returns a Chi-compatible authenticated POST mount. The handler also
// checks context identity itself so a nil or incorrectly composed middleware
// cannot expose the sync boundary.
func (h *Handler) Routes() http.Handler {
	router := chi.NewRouter()
	protected := http.Handler(http.HandlerFunc(h.post))
	if h.requireAuth != nil {
		protected = h.requireAuth(protected)
	}
	router.Post("/", protected.ServeHTTP)
	return router
}

func (h *Handler) post(w http.ResponseWriter, r *http.Request) {
	identity, ok := auth.IdentityFromContext(r.Context())
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="stoksync"`)
		writeSyncError(w, http.StatusUnauthorized, ErrInvalidIdentity)
		return
	}
	if h == nil || h.service == nil {
		writeSyncError(w, http.StatusInternalServerError, ErrInvalidService)
		return
	}

	request, err := DecodeRequest(requestBody(r), h.limits)
	if err != nil {
		writeSyncRequestError(w, err)
		return
	}
	if request.DeviceID != identity.DeviceID {
		writeSyncError(w, http.StatusForbidden, ErrRequestDeviceMismatch)
		return
	}
	if err := h.service.ValidateDevice(r.Context(), identity.UserID, request.DeviceID); err != nil {
		writeDeviceValidationError(w, err)
		return
	}

	results := make([]OperationResult, 0, len(request.Ops))
	for _, operation := range request.Ops {
		result, operationErr := h.service.ProcessOperation(r.Context(), identity, operation)
		if operationErr != nil {
			result = OperationResult{
				OpID:   operation.OpID,
				Status: ResultStatusRejected,
				Reason: ErrorInternal,
			}
		} else if result.OpID != operation.OpID || result.OpID == uuid.Nil {
			// A processor must not return an outcome for another operation. Treat
			// a malformed processor result as an isolated rejection rather than
			// producing a response that cannot be reconciled by the client.
			result = OperationResult{
				OpID:   operation.OpID,
				Status: ResultStatusRejected,
				Reason: ErrorInternal,
			}
		}
		results = append(results, result)
	}

	feed, err := h.service.ListChanges(r.Context(), identity.UserID, request.Cursor, request.MaxChanges)
	if err != nil {
		writeSyncError(w, http.StatusInternalServerError, err)
		return
	}

	clock := h.now
	if clock == nil {
		clock = time.Now
	}
	response := NewSyncResponse(results, feed.Changes, feed.NextCursor, feed.HasMore, clock().UTC())
	var body bytes.Buffer
	if err := EncodeResponse(&body, response, h.limits); err != nil {
		writeSyncError(w, http.StatusInternalServerError, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body.Bytes())
}

func requestBody(r *http.Request) io.Reader {
	if r == nil {
		return nil
	}
	return r.Body
}

func writeSyncRequestError(w http.ResponseWriter, err error) {
	status := http.StatusBadRequest
	if errors.Is(err, ErrRequestTooLarge) {
		status = http.StatusRequestEntityTooLarge
	}
	writeSyncError(w, status, err)
}

func writeDeviceValidationError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrDeviceNotRegistered):
		writeSyncError(w, http.StatusForbidden, err)
	case errors.Is(err, ErrInvalidIdentity), errors.Is(err, ErrRequestDeviceMismatch):
		writeSyncError(w, http.StatusForbidden, err)
	default:
		writeSyncError(w, http.StatusInternalServerError, err)
	}
}

func writeSyncError(w http.ResponseWriter, status int, err error) {
	response := ErrorResponseFor(err)
	switch {
	case status == http.StatusUnauthorized:
		response.Error = "unauthorized"
	case errors.Is(err, ErrRequestDeviceMismatch), errors.Is(err, ErrInvalidIdentity):
		response.Error = ErrorDeviceMismatch
	case errors.Is(err, ErrDeviceNotRegistered):
		response.Error = ErrorDeviceNotRegistered
	case status >= http.StatusInternalServerError:
		response.Error = ErrorInternal
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(response)
}
