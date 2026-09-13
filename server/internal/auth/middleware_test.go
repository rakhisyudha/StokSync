package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestRequireAccessTokenRejectsMissingAndTamperedCredentials(t *testing.T) {
	t.Parallel()

	manager := testTokenManager(t)
	nextCalled := false
	handler := RequireAccessToken(manager)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		nextCalled = true
	}))

	for _, authorization := range []string{"", "Basic abc", "Bearer malformed"} {
		request := httptest.NewRequest(http.MethodGet, "/v1/protected", nil)
		request.Header.Set("Authorization", authorization)
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusUnauthorized {
			t.Errorf("authorization %q status = %d, want 401", authorization, recorder.Code)
		}
		if recorder.Header().Get("WWW-Authenticate") == "" {
			t.Errorf("authorization %q did not include WWW-Authenticate", authorization)
		}
	}
	if nextCalled {
		t.Error("middleware called protected handler for rejected credentials")
	}
}

func TestRequireAccessTokenExposesValidatedIdentity(t *testing.T) {
	t.Parallel()

	manager := testTokenManager(t)
	userID := uuid.New()
	deviceID := uuid.New()
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	var got Identity
	handler := RequireAccessToken(manager)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var ok bool
		got, ok = IdentityFromContext(r.Context())
		if !ok {
			t.Error("IdentityFromContext() returned no identity")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodGet, "/v1/protected", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("accepted access token status = %d, want 204", recorder.Code)
	}
	if got.UserID != userID || got.DeviceID != deviceID || got.TokenID == uuid.Nil {
		t.Errorf("identity = %#v, want validated user/device/token IDs", got)
	}
}

func testTokenManager(t *testing.T) *TokenManager {
	t.Helper()
	manager, err := NewTokenManager(
		"01234567890123456789012345678901",
		"stoksync-api",
		"stoksync-client",
		15*time.Minute,
		time.Now,
	)
	if err != nil {
		t.Fatalf("NewTokenManager() error = %v", err)
	}
	return manager
}
