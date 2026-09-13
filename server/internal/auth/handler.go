package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
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
}

// NewHandler constructs authentication routes from a service and its access
// token middleware.
func NewHandler(service ServiceAPI, requireAuth Middleware) *Handler {
	return &Handler{service: service, requireAuth: requireAuth}
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
		return
	}
	session, err := h.service.Register(r.Context(), input)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeSession(w, http.StatusCreated, session)
}

func (h *Handler) login(w http.ResponseWriter, r *http.Request) {
	input, ok := decodeCredentials(w, r)
	if !ok {
		return
	}
	session, err := h.service.Login(r.Context(), input)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeSession(w, http.StatusOK, session)
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) {
	var request refreshRequest
	if !decodeJSON(w, r, &request) {
		return
	}
	if strings.TrimSpace(request.RefreshToken) == "" {
		writeAuthError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	session, err := h.service.Refresh(r.Context(), request.RefreshToken)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	writeSession(w, http.StatusOK, session)
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	identity, ok := IdentityFromContext(r.Context())
	if !ok {
		writeAuthError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err := h.service.RevokeDeviceSessions(r.Context(), identity.UserID, identity.DeviceID); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
