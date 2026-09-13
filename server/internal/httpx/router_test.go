package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthEndpointReturnsOK(t *testing.T) {
	t.Parallel()

	router := NewRouter(testLogger(), nil)
	request := httptest.NewRequest(http.MethodGet, "/v1/health", nil)
	recorder := httptest.NewRecorder()

	router.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want JSON", got)
	}
	if got := recorder.Header().Get("X-Request-Id"); got == "" {
		t.Error("X-Request-Id is empty")
	}

	var response statusResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Status != "ok" {
		t.Errorf("status body = %q, want ok", response.Status)
	}
}

func TestReadinessEndpointReportsDependencyFailure(t *testing.T) {
	t.Parallel()

	readinessErr := errors.New("database unavailable")
	router := NewRouter(testLogger(), func(context.Context) error {
		return readinessErr
	})
	request := httptest.NewRequest(http.MethodGet, "/v1/ready", nil)
	recorder := httptest.NewRecorder()

	router.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}

	var response statusResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Status != "not_ready" {
		t.Errorf("status body = %q, want not_ready", response.Status)
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(io.Discard, nil))
}
