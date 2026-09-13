package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/stoksync/stoksync/server/internal/auth"
)

type fakeSyncService struct {
	validateErr       error
	validateCalls     int
	validatedUserID   uuid.UUID
	validatedDeviceID uuid.UUID
	processCalls      []Operation
	processErrors     map[uuid.UUID]error
	processResults    map[uuid.UUID]OperationResult
	changeErr         error
	changeCalls       int
	changeUserID      uuid.UUID
	changeCursor      int64
	changeMaxChanges  int
	changeFeed        ChangeFeed
}

func (f *fakeSyncService) ValidateDevice(_ context.Context, userID, deviceID uuid.UUID) error {
	f.validateCalls++
	f.validatedUserID = userID
	f.validatedDeviceID = deviceID
	return f.validateErr
}

func (f *fakeSyncService) ProcessOperation(_ context.Context, _ auth.Identity, operation Operation) (OperationResult, error) {
	f.processCalls = append(f.processCalls, operation)
	if err := f.processErrors[operation.OpID]; err != nil {
		return OperationResult{}, err
	}
	if result, ok := f.processResults[operation.OpID]; ok {
		return result, nil
	}
	return OperationResult{OpID: operation.OpID, Status: ResultStatusRejected, Reason: "test_rejected"}, nil
}

func (f *fakeSyncService) ListChanges(_ context.Context, userID uuid.UUID, afterSeq int64, maxChanges int) (ChangeFeed, error) {
	f.changeCalls++
	f.changeUserID = userID
	f.changeCursor = afterSeq
	f.changeMaxChanges = maxChanges
	if f.changeErr != nil {
		return ChangeFeed{}, f.changeErr
	}
	feed := f.changeFeed
	if len(feed.Changes) == 0 && feed.NextCursor == 0 && !feed.HasMore {
		feed.NextCursor = afterSeq
	}
	return feed, nil
}

func TestHandlerRequiresAuthenticationAndMatchesRequestDevice(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	authenticatedDeviceID := uuid.New()
	otherDeviceID := uuid.New()
	manager := testSyncTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, authenticatedDeviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	service := &fakeSyncService{processErrors: map[uuid.UUID]error{}, processResults: map[uuid.UUID]OperationResult{}}
	handler := NewHandler(service, auth.RequireAccessToken(manager)).Routes()

	unauthenticated := httptest.NewRequest(http.MethodPost, "/", bytes.NewBufferString("{}"))
	unauthenticatedRecorder := httptest.NewRecorder()
	handler.ServeHTTP(unauthenticatedRecorder, unauthenticated)
	if unauthenticatedRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d, want 401", unauthenticatedRecorder.Code)
	}
	if service.validateCalls != 0 {
		t.Fatalf("validation calls for unauthenticated request = %d, want 0", service.validateCalls)
	}

	body := marshalSyncRequest(t, SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      otherDeviceID,
		Cursor:        7,
		MaxChanges:    10,
		ClientTime:    time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC),
		Ops:           []Operation{},
	})
	request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusForbidden {
		t.Fatalf("device mismatch status = %d, want 403: %s", recorder.Code, recorder.Body.String())
	}
	assertSyncError(t, recorder, ErrorDeviceMismatch)
	if service.validateCalls != 0 {
		t.Fatalf("validation calls after device mismatch = %d, want 0", service.validateCalls)
	}
}

func TestHandlerRejectsMalformedOversizedAndUnsupportedRequests(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	manager := testSyncTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	service := &fakeSyncService{processErrors: map[uuid.UUID]error{}, processResults: map[uuid.UUID]OperationResult{}}
	base := SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      deviceID,
		Cursor:        0,
		MaxChanges:    10,
		ClientTime:    time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC),
		Ops:           []Operation{},
	}

	testCases := []struct {
		name       string
		body       string
		limits     []Limits
		wantStatus int
		wantError  string
	}{
		{name: "malformed json", body: "{", wantStatus: http.StatusBadRequest, wantError: ErrorInvalidRequest},
		{name: "unknown field", body: marshalSyncRequest(t, base)[:len(marshalSyncRequest(t, base))-1] + `,"extra":true}`, wantStatus: http.StatusBadRequest, wantError: ErrorInvalidRequest},
		{name: "unsupported schema", body: marshalSyncRequest(t, func() SyncRequest {
			request := base
			request.SchemaVersion = SchemaVersion + 1
			return request
		}()), wantStatus: http.StatusBadRequest, wantError: ErrorUnsupportedSchemaVersion},
		{name: "oversized body", body: marshalSyncRequest(t, base), limits: []Limits{{MaxRequestBytes: 8}}, wantStatus: http.StatusRequestEntityTooLarge, wantError: ErrorInvalidRequest},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			var handler http.Handler
			if len(testCase.limits) == 0 {
				handler = NewHandler(service, auth.RequireAccessToken(manager)).Routes()
			} else {
				handler = NewHandler(service, auth.RequireAccessToken(manager), testCase.limits[0]).Routes()
			}
			request := httptest.NewRequest(http.MethodPost, "/", bytes.NewBufferString(testCase.body))
			request.Header.Set("Authorization", "Bearer "+token)
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)
			if recorder.Code != testCase.wantStatus {
				t.Fatalf("status = %d, want %d: %s", recorder.Code, testCase.wantStatus, recorder.Body.String())
			}
			assertSyncError(t, recorder, testCase.wantError)
		})
	}
	if service.validateCalls != 0 || len(service.processCalls) != 0 {
		t.Fatalf("service calls after invalid requests = (validate %d, process %d), want none", service.validateCalls, len(service.processCalls))
	}
}

func TestHandlerReturnsEmptyPushPullResponseAndValidatesRegisteredDevice(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	serverTime := time.Date(2026, time.January, 2, 5, 4, 5, 0, time.UTC)
	manager := testSyncTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	service := &fakeSyncService{processErrors: map[uuid.UUID]error{}, processResults: map[uuid.UUID]OperationResult{}}
	h := NewHandler(service, auth.RequireAccessToken(manager))
	h.now = func() time.Time { return serverTime }
	handler := h.Routes()
	requestBody := marshalSyncRequest(t, SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      deviceID,
		Cursor:        42,
		MaxChanges:    10,
		ClientTime:    serverTime,
		Ops:           []Operation{},
	})
	request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(requestBody))
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("empty sync status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want JSON", got)
	}
	var response SyncResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode sync response: %v", err)
	}
	if response.SchemaVersion != SchemaVersion || response.NextCursor != 42 || response.HasMore || !response.ServerTime.Equal(serverTime) {
		t.Errorf("response metadata = %#v, want schema 1/cursor 42/no more/fixed time", response)
	}
	if response.Results == nil || response.Changes == nil || len(response.Results) != 0 || len(response.Changes) != 0 {
		t.Fatalf("empty response arrays = results %#v changes %#v, want non-nil empty arrays", response.Results, response.Changes)
	}
	if service.validateCalls != 1 || service.validatedUserID != userID || service.validatedDeviceID != deviceID {
		t.Errorf("validated identity = (calls %d, user %s, device %s), want (%d, %s, %s)", service.validateCalls, service.validatedUserID, service.validatedDeviceID, 1, userID, deviceID)
	}
	if len(service.processCalls) != 0 {
		t.Errorf("empty batch process calls = %d, want 0", len(service.processCalls))
	}
}

func TestHandlerKeepsOperationFailuresIndependentAndMapsRegistrationErrors(t *testing.T) {
	t.Parallel()

	userID := uuid.New()
	deviceID := uuid.New()
	manager := testSyncTokenManager(t)
	token, _, err := manager.IssueAccessToken(userID, deviceID)
	if err != nil {
		t.Fatalf("IssueAccessToken() error = %v", err)
	}
	first := validSyncOperation(t)
	second := validSyncOperation(t)
	service := &fakeSyncService{
		processErrors:  map[uuid.UUID]error{first.OpID: errors.New("transaction failed")},
		processResults: map[uuid.UUID]OperationResult{second.OpID: {OpID: second.OpID, Status: ResultStatusRejected, Reason: "semantic_rejection"}},
	}
	handler := NewHandler(service, auth.RequireAccessToken(manager)).Routes()
	request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(marshalSyncRequest(t, SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      deviceID,
		Cursor:        3,
		MaxChanges:    10,
		ClientTime:    time.Now().UTC(),
		Ops:           []Operation{first, second},
	})))
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("partial sync status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var response SyncResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode partial response: %v", err)
	}
	if len(response.Results) != 2 || response.Results[0].OpID != first.OpID || response.Results[0].Status != ResultStatusRejected || response.Results[0].Reason != ErrorInternal {
		t.Errorf("first result = %#v, want isolated internal rejection", response.Results)
	}
	if response.Results[1].OpID != second.OpID || response.Results[1].Reason != "semantic_rejection" {
		t.Errorf("second result = %#v, want processor result preserved", response.Results[1])
	}
	if len(service.processCalls) != 2 {
		t.Fatalf("process calls = %d, want both operations attempted", len(service.processCalls))
	}

	service.validateErr = ErrDeviceNotRegistered
	request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(marshalSyncRequest(t, SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      deviceID,
		Cursor:        3,
		MaxChanges:    10,
		ClientTime:    time.Now().UTC(),
		Ops:           []Operation{},
	})))
	request.Header.Set("Authorization", "Bearer "+token)
	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusForbidden {
		t.Fatalf("unregistered device status = %d, want 403", recorder.Code)
	}
	assertSyncError(t, recorder, ErrorDeviceNotRegistered)
}

func validSyncOperation(t *testing.T) Operation {
	t.Helper()
	return Operation{
		OpID:        uuid.New(),
		Op:          OperationDeleteProduct,
		BaseVersion: int64Pointer(1),
		Payload:     mustJSON(t, DeleteProductPayload{ID: uuid.New()}),
	}
}

func marshalSyncRequest(t *testing.T, request SyncRequest) string {
	t.Helper()
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal sync request: %v", err)
	}
	return string(body)
}

func assertSyncError(t *testing.T, recorder *httptest.ResponseRecorder, want string) {
	t.Helper()
	var response ErrorResponse
	if err := json.NewDecoder(bytes.NewReader(recorder.Body.Bytes())).Decode(&response); err != nil {
		t.Fatalf("decode sync error: %v; body=%s", err, recorder.Body.String())
	}
	if response.Error != want {
		t.Errorf("sync error = %q, want %q", response.Error, want)
	}
}

func testSyncTokenManager(t *testing.T) *auth.TokenManager {
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
