package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/platform/logging"
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
	logger      *slog.Logger
}

// NewHandler constructs a sync handler using the protocol's default limits.
// An invalid custom limit is ignored in the same manner as the existing
// snapshot handler; callers can only configure a validated bounded exchange.
func NewHandler(service ServiceAPI, requireAuth auth.Middleware, configured ...Limits) *Handler {
	return newHandler(service, requireAuth, nil, configured...)
}

// NewHandlerWithLogger is the process composition-root constructor. The
// logger receives only bounded exchange summaries, never operation payloads or
// authorization metadata.
func NewHandlerWithLogger(service ServiceAPI, requireAuth auth.Middleware, logger *slog.Logger, configured ...Limits) *Handler {
	return newHandler(service, requireAuth, logger, configured...)
}

func newHandler(service ServiceAPI, requireAuth auth.Middleware, logger *slog.Logger, configured ...Limits) *Handler {
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
		logger:      logger,
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
		h.logExchange(r, "rejected", "invalid_identity")
		w.Header().Set("WWW-Authenticate", `Bearer realm="stoksync"`)
		writeSyncError(w, http.StatusUnauthorized, ErrInvalidIdentity)
		return
	}
	if h == nil || h.service == nil {
		h.logExchange(r, "failed", "internal_error")
		writeSyncError(w, http.StatusInternalServerError, ErrInvalidService)
		return
	}

	request, err := DecodeRequest(requestBody(r), h.limits)
	if err != nil {
		reason := "invalid_request"
		if errors.Is(err, ErrRequestTooLarge) {
			reason = "request_too_large"
		}
		h.logExchange(r, "rejected", reason)
		writeSyncRequestError(w, err)
		return
	}
	if request.DeviceID != identity.DeviceID {
		h.logExchange(r, "rejected", ErrorDeviceMismatch)
		writeSyncError(w, http.StatusForbidden, ErrRequestDeviceMismatch)
		return
	}
	if err := h.service.ValidateDevice(r.Context(), identity.UserID, request.DeviceID); err != nil {
		h.logExchange(r, "rejected", syncValidationReason(err))
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
		h.logExchange(r, "failed", "change_feed_error", "error_type", fmt.Sprintf("%T", err))
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
		h.logExchange(r, "failed", "response_encoding_error", "error_type", fmt.Sprintf("%T", err))
		writeSyncError(w, http.StatusInternalServerError, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body.Bytes())

	applied, rejected := 0, 0
	for _, result := range results {
		if result.Status == ResultStatusApplied {
			applied++
		} else {
			rejected++
		}
	}
	h.logExchange(
		r,
		"succeeded",
		"",
		"operation_count", len(results),
		"applied_count", applied,
		"rejected_count", rejected,
		"change_count", len(feed.Changes),
		"cursor", request.Cursor,
		"next_cursor", feed.NextCursor,
		"has_more", feed.HasMore,
	)
}

func (h *Handler) logExchange(r *http.Request, outcome, reason string, extra ...any) {
	if h == nil || h.logger == nil {
		return
	}
	attrs := []any{
		"outcome", outcome,
		"request_id", logging.SafeRequestID(middleware.GetReqID(r.Context())),
	}
	if reason != "" {
		attrs = append(attrs, "reason", reason)
	}
	attrs = append(attrs, extra...)
	h.logger.Info("sync.exchange", attrs...)
}

func syncValidationReason(err error) string {
	switch {
	case errors.Is(err, ErrDeviceNotRegistered):
		return ErrorDeviceNotRegistered
	case errors.Is(err, ErrInvalidIdentity), errors.Is(err, ErrRequestDeviceMismatch):
		return ErrorDeviceMismatch
	default:
		return "internal_error"
	}
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
