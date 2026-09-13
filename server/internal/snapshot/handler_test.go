package snapshot

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

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
)

func TestHandlerReturnsVersionedAuthenticatedSnapshotWithTombstones(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	productID := uuid.New()
	deletedProductID := uuid.New()
	movementID := uuid.New()
	updatedAt := time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC)
	deletedAt := updatedAt.Add(time.Hour)
	serverTime := updatedAt.Add(2 * time.Hour)
	barcode := "089686010947"
	minStock := int32(24)
	service := &fakeService{snapshot: Snapshot{
		Products: []db.Product{
			{
				ID: productID, UserID: userID, Barcode: &barcode, Name: "Active product", Unit: "pcs",
				MinStock: &minStock, Version: 3, UpdatedAt: updatedAt, UpdatedByDeviceID: deviceID, CreatedAt: updatedAt,
			},
			{
				ID: deletedProductID, UserID: userID, Name: "Deleted product", Unit: "pcs", Version: 4,
				UpdatedAt: updatedAt, UpdatedByDeviceID: deviceID, DeletedAt: &deletedAt, CreatedAt: updatedAt,
			},
		},
		Movements: []db.StockMovement{{
			ID: movementID, UserID: userID, ProductID: productID, Delta: -3, Kind: "issue",
			OccurredAt: updatedAt, RawOccurredAt: updatedAt, DeviceID: deviceID, ServerCreatedAt: updatedAt,
		}},
		Balances:   []db.LedgerBalance{{ProductID: productID, Qty: -3, LastMovementAt: &updatedAt}},
		Cursor:     1482,
		ServerTime: serverTime,
	}}
	manager := testSnapshotTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}

	handler := NewHandler(service, auth.RequireAccessToken(manager)).Routes()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("snapshot status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want JSON", got)
	}
	rawBody := append([]byte(nil), recorder.Body.Bytes()...)
	var response SnapshotResponse
	if err := json.Unmarshal(rawBody, &response); err != nil {
		t.Fatalf("decode snapshot response: %v", err)
	}
	if response.SchemaVersion != SchemaVersion || response.Cursor != 1482 || !response.ServerTime.Equal(serverTime) {
		t.Errorf("response metadata = (schema %d, cursor %d, server time %s), want version/cursor/time", response.SchemaVersion, response.Cursor, response.ServerTime)
	}
	if len(response.Products) != 2 || len(response.Tombstones) != 1 || len(response.Movements) != 1 || len(response.Balances) != 1 {
		t.Fatalf("response counts = products %d, tombstones %d, movements %d, balances %d; want 2/1/1/1", len(response.Products), len(response.Tombstones), len(response.Movements), len(response.Balances))
	}
	if response.Products[0].ID != productID.String() || response.Products[0].Barcode == nil || *response.Products[0].Barcode != barcode {
		t.Errorf("active product DTO = %#v, want UUID and barcode strings", response.Products[0])
	}
	if response.Tombstones[0].ID != deletedProductID.String() || !response.Tombstones[0].DeletedAt.Equal(deletedAt) {
		t.Errorf("tombstone DTO = %#v, want deleted product metadata", response.Tombstones[0])
	}
	if service.calls != 1 || service.userID != userID {
		t.Errorf("service call identity = (%d, %s), want one call for authenticated user %s", service.calls, service.userID, userID)
	}
	if !bytes.Contains(rawBody, []byte(`"server_time":"2026-01-02T05:04:05Z"`)) {
		t.Errorf("snapshot timestamps are not encoded as RFC3339 UTC JSON: %s", string(rawBody))
	}
}

func TestHandlerRejectsUnauthenticatedAndMalformedSnapshotRequests(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	service := &fakeService{}
	manager := testSnapshotTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	handler := NewHandler(service, auth.RequireAccessToken(manager)).Routes()

	unauthenticated := httptest.NewRequest(http.MethodGet, "/", nil)
	unauthenticatedRecorder := httptest.NewRecorder()
	handler.ServeHTTP(unauthenticatedRecorder, unauthenticated)
	if unauthenticatedRecorder.Code != http.StatusUnauthorized || service.calls != 0 {
		t.Fatalf("unauthenticated response = (%d, calls %d), want 401 and no service call", unauthenticatedRecorder.Code, service.calls)
	}

	for _, request := range []*http.Request{
		httptest.NewRequest(http.MethodGet, "/?unexpected=value", nil),
		httptest.NewRequest(http.MethodGet, "/", bytes.NewBufferString(`{"body":"not allowed"}`)),
	} {
		request.Header.Set("Authorization", "Bearer "+token)
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusBadRequest {
			t.Errorf("malformed request %s status = %d, want 400", request.URL, recorder.Code)
		}
	}
	if service.calls != 0 {
		t.Errorf("service calls after malformed requests = %d, want 0", service.calls)
	}

	post := httptest.NewRequest(http.MethodPost, "/", nil)
	post.Header.Set("Authorization", "Bearer "+token)
	postRecorder := httptest.NewRecorder()
	handler.ServeHTTP(postRecorder, post)
	if postRecorder.Code != http.StatusMethodNotAllowed || service.calls != 0 {
		t.Errorf("POST snapshot response = (status %d, calls %d), want 405 and no service call", postRecorder.Code, service.calls)
	}
}

func TestHandlerRejectsOversizedEncodedSnapshotWithoutPartialBody(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	manager := testSnapshotTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	service := &fakeService{snapshot: Snapshot{
		Cursor:     1,
		ServerTime: time.Now().UTC(),
	}}
	handler := NewHandler(service, auth.RequireAccessToken(manager), Limits{MaxResponseBytes: 1}).Routes()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized snapshot status = %d, want 413", recorder.Code)
	}
	if bytes.Contains(recorder.Body.Bytes(), []byte(`"schema_version"`)) {
		t.Error("oversized snapshot response included a partial success body")
	}
}

func TestHandlerMapsServiceFailureToGenericInternalError(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	manager := testSnapshotTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	service := &fakeService{err: errors.New("database password=secret unavailable")}
	handler := NewHandler(service, auth.RequireAccessToken(manager)).Routes()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusInternalServerError || bytes.Contains(recorder.Body.Bytes(), []byte("secret")) {
		t.Fatalf("service failure response = (%d, %s), want generic 500", recorder.Code, recorder.Body.String())
	}
}

type fakeService struct {
	snapshot Snapshot
	err      error
	calls    int
	userID   uuid.UUID
}

func (f *fakeService) GetSnapshot(_ context.Context, userID uuid.UUID) (Snapshot, error) {
	f.calls++
	f.userID = userID
	return f.snapshot, f.err
}

func testSnapshotTokenManager(t *testing.T) *auth.TokenManager {
	t.Helper()
	manager, err := auth.NewTokenManager(
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
