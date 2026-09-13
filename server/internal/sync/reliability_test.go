package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/stoksync/stoksync/server/internal/auth"
	"github.com/stoksync/stoksync/server/internal/db"
)

func TestServiceReplaysExactOutcomeAfterCommittedResponseIsLost(t *testing.T) {
	t.Parallel()

	identity := auth.Identity{UserID: uuid.New(), DeviceID: uuid.New()}
	operationID := uuid.New()
	productID := uuid.New()
	movementID := uuid.New()
	occurredAt := time.Date(2026, time.September, 13, 9, 41, 2, 0, time.UTC)
	operation := Operation{
		OpID: operationID,
		Op:   OperationAddMovement,
		Payload: mustJSON(t, AddMovementPayload{
			ID:            movementID,
			ProductID:     productID,
			Delta:         5,
			Kind:          "receive",
			OccurredAt:    occurredAt,
			RawOccurredAt: &occurredAt,
			DeviceID:      &identity.DeviceID,
		}),
	}

	firstTransaction := &syncScriptedTx{rows: []pgx.Row{
		syncOperationRow(identity, operationID, syncOperationStatusProcessing, []byte(`{}`)),
		syncProductRow(productID, identity.UserID, identity.DeviceID, 1, nil),
		syncMovementRow(movementID, identity.UserID, productID, identity.DeviceID, 5, "receive", occurredAt),
		syncBalanceRow(productID, 5, occurredAt),
		syncSequenceRow(101),
		syncChangeRow(101, identity.UserID, "stock_movement", movementID, "upsert", []byte(`{"id":"movement"}`), identity.DeviceID, occurredAt),
		syncOperationRow(identity, operationID, ResultStatusApplied, []byte(`{}`)),
	}}
	beginner := &replaySyncBeginner{transactions: []*syncScriptedTx{firstTransaction}}
	service, err := NewService(beginner)
	if err != nil {
		t.Fatalf("NewService() error = %v", err)
	}

	firstResult, err := service.ProcessOperation(context.Background(), identity, operation)
	if err != nil {
		t.Fatalf("first ProcessOperation() error = %v", err)
	}
	if firstResult.Status != ResultStatusApplied || firstResult.Seq == nil || *firstResult.Seq != 101 {
		t.Fatalf("first result = %#v, want applied result at sequence 101", firstResult)
	}
	assertSyncOperationStatementOrder(t, firstTransaction)
	assertStoredOperationResult(t, firstTransaction, firstResult)
	assertChangeStatement(t, firstTransaction, "stock_movement", "upsert", movementID)
	if firstTransaction.commitCalls != 1 || firstTransaction.rollbackCalls != 0 {
		t.Fatalf("first transaction lifecycle = (commit %d, rollback %d), want committed", firstTransaction.commitCalls, firstTransaction.rollbackCalls)
	}

	// The first result is deliberately discarded before the retry, modelling a
	// response lost after the server transaction committed successfully.
	storedResponse, err := json.Marshal(firstResult)
	if err != nil {
		t.Fatalf("marshal first result: %v", err)
	}
	secondTransaction := &syncScriptedTx{rows: []pgx.Row{
		syncErrorRow(pgx.ErrNoRows),
		syncOperationRow(identity, operationID, ResultStatusApplied, storedResponse),
	}}
	beginner.transactions = append(beginner.transactions, secondTransaction)

	secondResult, err := service.ProcessOperation(context.Background(), identity, operation)
	if err != nil {
		t.Fatalf("retry ProcessOperation() error = %v", err)
	}
	if !reflect.DeepEqual(secondResult, firstResult) {
		t.Fatalf("retry result = %#v, want exact original result %#v", secondResult, firstResult)
	}
	assertDuplicateReplayTransaction(t, secondTransaction)
}

func TestHandlerReturnsIndependentAppliedAndRejectedResultsInOneBatch(t *testing.T) {
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
	seq := int64(144)
	service := &fakeSyncService{
		processErrors: map[uuid.UUID]error{},
		processResults: map[uuid.UUID]OperationResult{
			first.OpID: {
				OpID:   first.OpID,
				Status: ResultStatusApplied,
				Seq:    &seq,
			},
			second.OpID: {
				OpID:   second.OpID,
				Status: ResultStatusRejected,
				Reason: "invalid_delta",
			},
		},
	}
	h := NewHandler(service, auth.RequireAccessToken(manager))
	h.now = func() time.Time {
		return time.Date(2026, time.September, 13, 10, 2, 15, 0, time.UTC)
	}

	request := httptest.NewRequest(http.MethodPost, "/", bytes.NewBufferString(marshalSyncRequest(t, SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      deviceID,
		Cursor:        143,
		MaxChanges:    10,
		ClientTime:    time.Date(2026, time.September, 13, 10, 2, 14, 0, time.UTC),
		Ops:           []Operation{first, second},
	})))
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	h.Routes().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("partial batch status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var response SyncResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode partial batch response: %v", err)
	}
	if len(response.Results) != 2 {
		t.Fatalf("results = %#v, want one result per operation", response.Results)
	}
	if response.Results[0].OpID != first.OpID || response.Results[0].Status != ResultStatusApplied || response.Results[0].Seq == nil || *response.Results[0].Seq != seq {
		t.Errorf("first result = %#v, want applied sequence %d", response.Results[0], seq)
	}
	if response.Results[1].OpID != second.OpID || response.Results[1].Status != ResultStatusRejected || response.Results[1].Reason != "invalid_delta" {
		t.Errorf("second result = %#v, want independent invalid_delta rejection", response.Results[1])
	}
	if len(service.processCalls) != 2 || service.processCalls[0].OpID != first.OpID || service.processCalls[1].OpID != second.OpID {
		t.Fatalf("processed operations = %#v, want both operations in request order", service.processCalls)
	}
}

type replaySyncBeginner struct {
	transactions []*syncScriptedTx
}

func (b *replaySyncBeginner) BeginTx(context.Context) (db.Tx, error) {
	if len(b.transactions) == 0 {
		return nil, errors.New("no scripted transaction remains")
	}
	transaction := b.transactions[0]
	b.transactions = b.transactions[1:]
	return transaction, nil
}
