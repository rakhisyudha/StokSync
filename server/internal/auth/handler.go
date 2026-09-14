package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"
	"github.com/stoksync/stoksync/server/internal/platform/logging"
)

const maxAuthRequestBytes = 16 << 10

// ServiceAPI keeps HTTP behavior testable without replacing the real database
// service in production.
type ServiceAPI interface {
	Register(context.Context, LoginInput) (Session, error)
	Login(context.Context, LoginInput) (Session, error)
	Refresh(context.Context, string) (Session, error)
	RevokeDeviceSessions(context.Context, uuid.UUID, uuid.UUID) error
}

// Middleware is the small Chi-compatible function required by Handler.
type Middleware func(http.Handler) http.Handler

// Handler exposes only authentication routes. Domain and synchronization
// handlers are intentionally left for later milestones.
type Handler struct {
	service     ServiceAPI
	requireAuth Middleware
	logger      *slog.Logger
}

// NewHandler constructs authentication routes from a service and its access
// token middleware. The optional logger receives only safe authentication
// outcome events; credentials and token values are never passed to it.
func NewHandler(service ServiceAPI, requireAuth Middleware, logger ...*slog.Logger) *Handler {
	var eventLogger *slog.Logger
	if len(logger) > 0 {
		eventLogger = logger[0]
	}
	return &Handler{service: service, requireAuth: requireAuth, logger: eventLogger}
}

// Routes returns a Chi router mounted by the process-level API router.
func (h *Handler) Routes() http.Handler {
	router := chi.NewRouter()
	router.Post("/register", h.register)
	router.Post("/login", h.login)
	router.Post("/refresh", h.refresh)
	if h.requireAuth != nil {
		router.With(h.requireAuth).Post("/logout", h.logout)
	}
	return router
}

type credentialsRequest struct {
	Email      string `json:"email"`
	Password   string `json:"password"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type sessionResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int64  `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
	UserID       string `json:"user_id"`
	DeviceID     string `json:"device_id"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func (h *Handler) register(w http.ResponseWriter, r *http.Request) {
	input, ok := decodeCredentials(w, r)
	if !ok {
		h.logOutcome(r, "auth.register", "rejected", "invalid_request")
		return
	}
	session, err := h.service.Register(r.Context(), input)
	if err != nil {
		h.logOutcome(r, "auth.register", "rejected", authErrorReason(err))
		writeServiceError(w, err)
		return
	}
	h.logOutcome(r, "auth.register", "succeeded", "")
	writeSession(w, http.StatusCreated, session)
}

func (h *Handler) login(w http.ResponseWriter, r *http.Request) {
	input, ok := decodeCredentials(w, r)
	if !ok {
		h.logOutcome(r, "auth.login", "rejected", "invalid_request")
		return
	}
	session, err := h.service.Login(r.Context(), input)
	if err != nil {
		h.logOutcome(r, "auth.login", "rejected", authErrorReason(err))
		writeServiceError(w, err)
		return
	}
	h.logOutcome(r, "auth.login", "succeeded", "")
	writeSession(w, http.StatusOK, session)
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) {
	var request refreshRequest
	if !decodeJSON(w, r, &request) {
		h.logOutcome(r, "auth.refresh", "rejected", "invalid_request")
		return
	}
	if strings.TrimSpace(request.RefreshToken) == "" {
		h.logOutcome(r, "auth.refresh", "rejected", "invalid_request")
		writeAuthError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	session, err := h.service.Refresh(r.Context(), request.RefreshToken)
	if err != nil {
		h.logOutcome(r, "auth.refresh", "rejected", authErrorReason(err))
		writeServiceError(w, err)
		return
	}
	h.logOutcome(r, "auth.refresh", "succeeded", "")
	writeSession(w, http.StatusOK, session)
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	identity, ok := IdentityFromContext(r.Context())
	if !ok {
		h.logOutcome(r, "auth.logout", "rejected", "unauthorized")
		writeAuthError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err := h.service.RevokeDeviceSessions(r.Context(), identity.UserID, identity.DeviceID); err != nil {
		h.logOutcome(r, "auth.logout", "rejected", "internal_error")
		writeServiceError(w, err)
		return
	}
	h.logOutcome(r, "auth.logout", "succeeded", "")
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) logOutcome(r *http.Request, event, outcome, reason string) {
	if h == nil || h.logger == nil {
		return
	}
	attrs := []any{
		"outcome", outcome,
		"request_id", requestID(r),
	}
	if reason != "" {
		attrs = append(attrs, "reason", reason)
	}
	h.logger.Info(event, attrs...)
}

func requestID(r *http.Request) string {
	if r == nil {
		return ""
	}
	return logging.SafeRequestID(middleware.GetReqID(r.Context()))
}

func authErrorReason(err error) string {
	switch {
	case errors.Is(err, ErrInvalidInput):
		return "invalid_input"
	case errors.Is(err, ErrInvalidCredentials):
		return "invalid_credentials"
	case errors.Is(err, ErrEmailTaken):
		return "email_taken"
	case errors.Is(err, ErrDeviceOwnership):
		return "device_conflict"
	case errors.Is(err, ErrInvalidRefreshToken), errors.Is(err, ErrRefreshTokenExpired), errors.Is(err, ErrRefreshTokenReuse):
		return "invalid_refresh_token"
	default:
		return "internal_error"
	}
}

func decodeCredentials(w http.ResponseWriter, r *http.Request) (LoginInput, bool) {
	var request credentialsRequest
	if !decodeJSON(w, r, &request) {
		return LoginInput{}, false
	}
	deviceID, err := uuid.Parse(strings.TrimSpace(request.DeviceID))
	if err != nil {
		writeAuthError(w, http.StatusBadRequest, "invalid_request")
		return LoginInput{}, false
	}
	return LoginInput{
		Email:      request.Email,
		Password:   request.Password,
		DeviceID:   deviceID,
		DeviceName: request.DeviceName,
		Platform:   request.Platform,
	}, true
}

func decodeJSON(w http.ResponseWriter, r *http.Request, destination any) bool {
	if r == nil || r.Body == nil {
		writeAuthError(w, http.StatusBadRequest, "invalid_request")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthRequestBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		writeAuthError(w, http.StatusBadRequest, "invalid_request")
		return false
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		writeAuthError(w, http.StatusBadRequest, "invalid_request")
		return false
	}
	return true
}

func writeSession(w http.ResponseWriter, status int, session Session) {
	expiresIn := int64(session.AccessTokenExpiresAt.Sub(time.Now()).Seconds())
	if expiresIn < 0 {
		expiresIn = 0
	}
	writeJSON(w, status, sessionResponse{
		AccessToken:  session.AccessToken,
		TokenType:    "Bearer",
		ExpiresIn:    expiresIn,
		RefreshToken: session.RefreshToken,
		UserID:       session.UserID.String(),
		DeviceID:     session.DeviceID.String(),
	})
}

func writeServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrInvalidInput):
		writeAuthError(w, http.StatusBadRequest, "invalid_request")
	case errors.Is(err, ErrInvalidCredentials):
		writeAuthError(w, http.StatusUnauthorized, "invalid_credentials")
	case errors.Is(err, ErrEmailTaken):
		writeAuthError(w, http.StatusConflict, "email_taken")
	case errors.Is(err, ErrDeviceOwnership):
		writeAuthError(w, http.StatusConflict, "device_conflict")
	case errors.Is(err, ErrInvalidRefreshToken), errors.Is(err, ErrRefreshTokenExpired), errors.Is(err, ErrRefreshTokenReuse):
		writeAuthError(w, http.StatusUnauthorized, "invalid_refresh_token")
	default:
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
	}
}

func writeAuthError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, errorResponse{Error: code})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
