package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
)

type fakeAuthService struct {
	session        Session
	loginInput     LoginInput
	refreshToken   string
	revokeUserID   uuid.UUID
	revokeDeviceID uuid.UUID
	loginErr       error
	refreshErr     error
	registerErr    error
	revokeErr      error
}

func (f *fakeAuthService) Register(_ context.Context, input LoginInput) (Session, error) {
	f.loginInput = input
	return f.session, f.registerErr
}

func (f *fakeAuthService) Login(_ context.Context, input LoginInput) (Session, error) {
	f.loginInput = input
	return f.session, f.loginErr
}

func (f *fakeAuthService) Refresh(_ context.Context, token string) (Session, error) {
	f.refreshToken = token
	return f.session, f.refreshErr
}

func (f *fakeAuthService) RevokeDeviceSessions(_ context.Context, userID, deviceID uuid.UUID) error {
	f.revokeUserID = userID
	f.revokeDeviceID = deviceID
	return f.revokeErr
}

func TestHandlerLoginReturnsBearerSessionAndDoesNotExposeServiceErrors(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	service := &fakeAuthService{session: Session{
		UserID:               userID,
		DeviceID:             deviceID,
		AccessToken:          "signed-access-token",
		AccessTokenExpiresAt: time.Now().Add(time.Minute),
		RefreshToken:         "opaque-refresh-token",
	}}
	handler := NewHandler(service, nil).Routes()
	body := `{"email":"Owner@Example.com","password":"correct horse","device_id":"` + deviceID.String() + `","device_name":"Phone","platform":"android"}`
	request := httptest.NewRequest(http.MethodPost, "/login", bytes.NewBufferString(body))
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("login status = %d, want 200", recorder.Code)
	}
	var response sessionResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode login response: %v", err)
	}
	if response.TokenType != "Bearer" || response.AccessToken != "signed-access-token" || response.RefreshToken != "opaque-refresh-token" {
		t.Errorf("session response = %#v, want bearer tokens", response)
	}
	if service.loginInput.Email != "Owner@Example.com" || service.loginInput.DeviceID != deviceID {
		t.Errorf("service input = %#v, want request values", service.loginInput)
	}
}

func TestHandlerMapsCredentialAndRefreshFailuresToSafeResponses(t *testing.T) {
	t.Parallel()

	service := &fakeAuthService{loginErr: ErrInvalidCredentials, refreshErr: ErrRefreshTokenReuse}
	handler := NewHandler(service, nil).Routes()
	login := httptest.NewRequest(http.MethodPost, "/login", bytes.NewBufferString(`{"email":"owner@example.com","password":"wrong","device_id":"00000000-0000-4000-8000-000000000001","device_name":"Phone","platform":"android"}`))
	loginRecorder := httptest.NewRecorder()
	handler.ServeHTTP(loginRecorder, login)
	if loginRecorder.Code != http.StatusUnauthorized || bytes.Contains(loginRecorder.Body.Bytes(), []byte("wrong")) {
		t.Fatalf("login failure response = (%d, %s), want generic 401", loginRecorder.Code, loginRecorder.Body.String())
	}

	refresh := httptest.NewRequest(http.MethodPost, "/refresh", bytes.NewBufferString(`{"refresh_token":"opaque"}`))
	refreshRecorder := httptest.NewRecorder()
	handler.ServeHTTP(refreshRecorder, refresh)
	if refreshRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("refresh reuse response status = %d, want 401", refreshRecorder.Code)
	}
	if bytes.Contains(refreshRecorder.Body.Bytes(), []byte("reuse")) {
		t.Error("refresh reuse response exposed token-reuse detail")
	}
}

func TestHandlerLogoutUsesMiddlewareIdentity(t *testing.T) {
	t.Parallel()

	manager := testTokenManager(t)
	userID := uuid.New()
	deviceID := uuid.New()
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	service := &fakeAuthService{}
	handler := NewHandler(service, RequireAccessToken(manager)).Routes()
	request := httptest.NewRequest(http.MethodPost, "/logout", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("logout status = %d, want 204", recorder.Code)
	}
	if service.revokeUserID != userID || service.revokeDeviceID != deviceID {
		t.Errorf("logout identity = (%s, %s), want (%s, %s)", service.revokeUserID, service.revokeDeviceID, userID, deviceID)
	}
}

func TestHandlerRejectsUnknownJSONFields(t *testing.T) {
	t.Parallel()

	service := &fakeAuthService{}
	handler := NewHandler(service, nil).Routes()
	request := httptest.NewRequest(http.MethodPost, "/login", bytes.NewBufferString(`{"email":"owner@example.com","password":"correct horse","device_id":"00000000-0000-4000-8000-000000000001","device_name":"Phone","platform":"android","password_hash":"do-not-accept"}`))
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("unknown field status = %d, want 400", recorder.Code)
	}
}

func TestHandlerReturnsInternalErrorWithoutDatabaseDetails(t *testing.T) {
	t.Parallel()

	service := &fakeAuthService{loginErr: errors.New("database password=secret unavailable")}
	handler := NewHandler(service, nil).Routes()
	request := httptest.NewRequest(http.MethodPost, "/login", bytes.NewBufferString(`{"email":"owner@example.com","password":"correct horse","device_id":"00000000-0000-4000-8000-000000000001","device_name":"Phone","platform":"android"}`))
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusInternalServerError || bytes.Contains(recorder.Body.Bytes(), []byte("secret")) {
		t.Fatalf("internal error response = (%d, %s), want generic 500", recorder.Code, recorder.Body.String())
	}
}
