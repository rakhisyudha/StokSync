package sync

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestDecodeRequestAcceptsVersionedStrictEnvelope(t *testing.T) {
	t.Parallel()

	deviceID := uuid.New()
	operationID := uuid.New()
	movementID := uuid.New()
	productID := uuid.New()
	body := fmt.Sprintf(`{
		"schema_version":1,
		"device_id":"%s",
		"cursor":1482,
		"max_changes":500,
		"client_time":"2026-09-13T10:02:14Z",
		"ops":[{
			"op_id":"%s",
			"op":"add_movement",
			"payload":{
				"id":"%s",
				"product_id":"%s",
				"delta":-3,
				"kind":"issue",
				"note":"sold",
				"occurred_at":"2026-09-13T09:41:02Z"
			}
		}]
	}`, deviceID, operationID, movementID, productID)

	request, err := DecodeRequest(strings.NewReader(body))
	if err != nil {
		t.Fatalf("DecodeRequest() error = %v", err)
	}
	if request.SchemaVersion != SchemaVersion || request.DeviceID != deviceID || request.Cursor != 1482 || request.MaxChanges != 500 {
		t.Fatalf("request metadata = %#v, want version/device/cursor/max_changes", request)
	}
	if len(request.Ops) != 1 || request.Ops[0].OpID != operationID || request.Ops[0].Op != OperationAddMovement {
		t.Fatalf("request operations = %#v, want one add_movement operation", request.Ops)
	}
	decoded, err := request.Ops[0].DecodePayload()
	if err != nil || !okPayloadType(decoded, AddMovementPayload{}) {
		t.Fatalf("decoded payload type = %T, want AddMovementPayload", decoded)
	}
}

func TestDecodeRequestRejectsUnknownMissingAndTrailingJSON(t *testing.T) {
	t.Parallel()

	valid := validRequestBody(t)
	cases := []struct {
		name string
		body string
	}{
		{
			name: "unknown top-level field",
			body: strings.Replace(valid, `"ops":[]`, `"ops":[],"unexpected":true`, 1),
		},
		{
			name: "missing operations",
			body: strings.Replace(valid, `,"ops":[]`, "", 1),
		},
		{
			name: "trailing value",
			body: valid + ` {}`,
		},
		{
			name: "unknown operation field",
			body: strings.Replace(valid, `"ops":[]`, `"ops":[{"op_id":"`+uuid.New().String()+`","op":"delete_product","payload":{"id":"`+uuid.New().String()+`"},"extra":true}]`, 1),
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			_, err := DecodeRequest(strings.NewReader(testCase.body))
			if err == nil || !errors.Is(err, ErrInvalidRequest) {
				t.Fatalf("DecodeRequest() error = %v, want invalid request", err)
			}
		})
	}
}

func TestSchemaVersionHandlingReturnsMinimumSupportedVersion(t *testing.T) {
	t.Parallel()

	request := validRequest(t)
	request.SchemaVersion = SchemaVersion + 1
	err := request.Validate()
	var schemaErr *UnsupportedSchemaVersionError
	if !errors.As(err, &schemaErr) {
		t.Fatalf("Validate() error = %v, want UnsupportedSchemaVersionError", err)
	}
	if schemaErr.Received != SchemaVersion+1 || schemaErr.MinSupportedVersion != MinSupportedSchemaVersion {
		t.Fatalf("schema error = %#v, want received/minimum versions", schemaErr)
	}
	if !errors.Is(err, ErrUnsupportedSchemaVersion) {
		t.Errorf("schema error = %v, want ErrUnsupportedSchemaVersion", err)
	}
	response := ErrorResponseFor(err)
	if response.Error != ErrorUnsupportedSchemaVersion || response.MinSupportedVersion != MinSupportedSchemaVersion || response.SchemaVersion != SchemaVersion {
		t.Errorf("ErrorResponseFor() = %#v, want version negotiation response", response)
	}

	request.SchemaVersion = SchemaVersion - 1
	if err := request.Validate(); !errors.Is(err, ErrUnsupportedSchemaVersion) {
		t.Errorf("older schema error = %v, want ErrUnsupportedSchemaVersion", err)
	}
}

func TestOperationValidationCoversKnownPayloadShapes(t *testing.T) {
	t.Parallel()

	movementID := uuid.New()
	productID := uuid.New()
	deviceID := uuid.New()
	reversalID := uuid.New()
	occurredAt := time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC)
	countedQty := int32(5)
	cases := []struct {
		name      string
		operation Operation
	}{
		{
			name: "movement with audit fields",
			operation: Operation{
				OpID: uuid.New(), Op: OperationAddMovement,
				Payload: mustJSON(t, AddMovementPayload{
					ID: movementID, ProductID: productID, Delta: -3, Kind: "adjust",
					OccurredAt: occurredAt, RawOccurredAt: &occurredAt,
					CountedQty: nil, ReversesID: &reversalID, DeviceID: &deviceID,
				}),
			},
		},
		{
			name: "stocktake movement",
			operation: Operation{
				OpID: uuid.New(), Op: OperationAddMovement,
				Payload: mustJSON(t, AddMovementPayload{
					ID: movementID, ProductID: productID, Delta: 2, Kind: "stocktake",
					OccurredAt: occurredAt, CountedQty: &countedQty,
				}),
			},
		},
		{
			name: "product upsert",
			operation: Operation{
				OpID: uuid.New(), Op: OperationUpsertProduct, BaseVersion: int64Pointer(7),
				Payload: mustJSON(t, UpsertProductPayload{ID: productID, Name: "Indomie Goreng", Unit: "pcs"}),
			},
		},
		{
			name: "product delete",
			operation: Operation{
				OpID: uuid.New(), Op: OperationDeleteProduct, BaseVersion: int64Pointer(7),
				Payload: mustJSON(t, DeleteProductPayload{ID: productID}),
			},
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if err := testCase.operation.Validate(); err != nil {
				t.Fatalf("Validate() error = %v", err)
			}
		})
	}

	invalidCases := []Operation{
		{OpID: uuid.New(), Op: "unknown_operation", Payload: json.RawMessage(`{}`)},
		{OpID: uuid.Nil, Op: OperationDeleteProduct, Payload: json.RawMessage(`{"id":"` + productID.String() + `"}`)},
		{OpID: uuid.New(), Op: OperationDeleteProduct, Payload: json.RawMessage(`{"id":"` + productID.String() + `","unknown":true}`)},
		{OpID: uuid.New(), Op: OperationAddMovement, Payload: json.RawMessage(`{"id":"` + movementID.String() + `","product_id":"` + productID.String() + `","delta":0,"kind":"issue","occurred_at":"2026-01-02T03:04:05Z"}`)},
		{OpID: uuid.New(), Op: OperationAddMovement, Payload: json.RawMessage(`{"id":"` + movementID.String() + `","product_id":"` + productID.String() + `","delta":1,"kind":"stocktake","occurred_at":"2026-01-02T03:04:05Z"}`)},
		{OpID: uuid.New(), Op: OperationDeleteProduct, Payload: json.RawMessage(`{"id":"` + productID.String() + `"}`)},
		{OpID: uuid.New(), Op: OperationAddMovement, BaseVersion: int64Pointer(1), Payload: json.RawMessage(`{"id":"` + movementID.String() + `","product_id":"` + productID.String() + `","delta":1,"kind":"issue","occurred_at":"2026-01-02T03:04:05Z"}`)},
		{OpID: uuid.New(), Op: OperationUpsertProduct, BaseVersion: int64Pointer(-1), Payload: json.RawMessage(`{"id":"` + productID.String() + `","name":"Product"}`)},
	}
	for index, operation := range invalidCases {
		if err := operation.Validate(); err == nil || !errors.Is(err, ErrInvalidOperation) {
			t.Errorf("invalid operation %d error = %v, want ErrInvalidOperation", index, err)
		}
	}
}

func TestDecodeRequestEnforcesBodyOperationPayloadAndChangeLimits(t *testing.T) {
	t.Parallel()

	valid := validRequestBody(t)
	if _, err := DecodeRequest(strings.NewReader(valid), Limits{MaxRequestBytes: int64(len(valid) - 1)}); !errors.Is(err, ErrRequestTooLarge) {
		t.Errorf("oversized request error = %v, want ErrRequestTooLarge", err)
	}

	request := validRequest(t)
	request.Ops = []Operation{
		{OpID: uuid.New(), Op: OperationDeleteProduct, BaseVersion: int64Pointer(1), Payload: mustJSON(t, DeleteProductPayload{ID: uuid.New()})},
		{OpID: uuid.New(), Op: OperationDeleteProduct, BaseVersion: int64Pointer(1), Payload: mustJSON(t, DeleteProductPayload{ID: uuid.New()})},
	}
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	if _, err := DecodeRequest(bytes.NewReader(body), Limits{MaxOperations: 1}); !errors.Is(err, ErrTooManyOperations) {
		t.Errorf("too many operations error = %v, want ErrTooManyOperations", err)
	}

	request.Ops = nil
	request.MaxChanges = 2
	body, err = json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal max_changes request: %v", err)
	}
	if _, err := DecodeRequest(bytes.NewReader(body), Limits{MaxChanges: 1}); !errors.Is(err, ErrMaxChangesExceeded) {
		t.Errorf("max_changes error = %v, want ErrMaxChangesExceeded", err)
	}

	request.Ops = []Operation{{
		OpID: uuid.New(), Op: OperationDeleteProduct, BaseVersion: int64Pointer(1),
		Payload: mustJSON(t, DeleteProductPayload{ID: uuid.New()}),
	}}
	body, err = json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal payload request: %v", err)
	}
	if _, err := DecodeRequest(bytes.NewReader(body), Limits{MaxOperationPayloadBytes: 4}); !errors.Is(err, ErrRequestTooLarge) {
		t.Errorf("operation payload size error = %v, want ErrRequestTooLarge", err)
	}
}

func TestStocktakeOutcomeRoundTripsInAppliedAndRejectedResults(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.January, 2, 5, 4, 5, 0, time.UTC)
	productID := uuid.New()
	movementID := uuid.New()
	outcome := &StocktakeOutcome{
		ProductID:        productID,
		CanonicalBalance: 15,
		Canonical: StocktakeIntent{
			MovementID: movementID, ProductID: productID, Delta: 5,
			CountedQty: 15, OccurredAt: now, DeviceID: uuid.New(),
		},
		Incoming: StocktakeIntent{
			MovementID: uuid.New(), ProductID: productID, Delta: -3,
			CountedQty: 12, OccurredAt: now, DeviceID: uuid.New(),
		},
	}
	response := NewSyncResponse([]OperationResult{
		{OpID: uuid.New(), Status: ResultStatusRejected, Reason: ReasonStocktakeDisplaced, StocktakeOutcome: outcome},
	}, nil, 0, false, now)
	body, err := MarshalResponse(response)
	if err != nil {
		t.Fatalf("MarshalResponse() error = %v", err)
	}
	var decoded SyncResponse
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}
	if decoded.Results[0].StocktakeOutcome == nil || decoded.Results[0].StocktakeOutcome.CanonicalBalance != 15 {
		t.Fatalf("decoded stocktake outcome = %#v, want canonical balance 15", decoded.Results[0].StocktakeOutcome)
	}
	if decoded.Results[0].Reason != ReasonStocktakeDisplaced {
		t.Fatalf("decoded reason = %q, want %q", decoded.Results[0].Reason, ReasonStocktakeDisplaced)
	}
}

func TestResponseEncodingIsVersionedCompleteAndStrict(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, time.January, 2, 5, 4, 5, 0, time.FixedZone("UTC+2", 2*60*60))
	seq := int64(1483)
	response := NewSyncResponse(
		[]OperationResult{
			{OpID: uuid.New(), Status: ResultStatusApplied, Seq: &seq},
			{OpID: uuid.New(), Status: ResultStatusRejected, Reason: "version_conflict", ServerState: json.RawMessage(`{"id":"product","version":9}`)},
		},
		[]ChangeEntry{{
			Seq: 1483, Entity: "stock_movement", Op: "upsert",
			Data: json.RawMessage(`{"id":"movement"}`),
		}},
		1483, false, now,
	)
	body, err := MarshalResponse(response)
	if err != nil {
		t.Fatalf("MarshalResponse() error = %v", err)
	}
	var decoded map[string]json.RawMessage
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("decode encoded response: %v", err)
	}
	if string(decoded["schema_version"]) != "1" || string(decoded["next_cursor"]) != "1483" || string(decoded["has_more"]) != "false" {
		t.Fatalf("encoded metadata = %s, want version/cursor/has_more", body)
	}
	if !bytes.Contains(body, []byte(`"server_time":"2026-01-02T03:04:05Z"`)) {
		t.Errorf("server time was not normalized to UTC: %s", body)
	}
	if !bytes.Contains(body, []byte(`"results"`)) || !bytes.Contains(body, []byte(`"changes"`)) {
		t.Errorf("encoded response omitted result/change arrays: %s", body)
	}

	var encoded bytes.Buffer
	if err := EncodeResponse(&encoded, response); err != nil {
		t.Fatalf("EncodeResponse() error = %v", err)
	}
	if !bytes.HasSuffix(encoded.Bytes(), []byte("\n")) {
		t.Error("EncodeResponse() did not emit one JSON line")
	}

	invalid := response
	invalid.SchemaVersion = SchemaVersion + 1
	encoded.Reset()
	if err := EncodeResponse(&encoded, invalid); !errors.Is(err, ErrUnsupportedSchemaVersion) {
		t.Fatalf("invalid response error = %v, want ErrUnsupportedSchemaVersion", err)
	}
	if encoded.Len() != 0 {
		t.Fatalf("invalid response wrote %d bytes before validation", encoded.Len())
	}
}

func TestEmptyResponseEncodesArraysInsteadOfNull(t *testing.T) {
	t.Parallel()

	body, err := MarshalResponse(NewSyncResponse(nil, nil, 0, false, time.Now().UTC()))
	if err != nil {
		t.Fatalf("MarshalResponse() error = %v", err)
	}
	if bytes.Contains(body, []byte(`"results":null`)) || bytes.Contains(body, []byte(`"changes":null`)) {
		t.Fatalf("empty response encoded null arrays: %s", body)
	}
	if !bytes.Contains(body, []byte(`"results":[]`)) || !bytes.Contains(body, []byte(`"changes":[]`)) {
		t.Fatalf("empty response did not encode empty arrays: %s", body)
	}
}

func validRequest(t *testing.T) SyncRequest {
	t.Helper()
	return SyncRequest{
		SchemaVersion: SchemaVersion,
		DeviceID:      uuid.New(),
		Cursor:        0,
		MaxChanges:    10,
		ClientTime:    time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC),
		Ops:           []Operation{},
	}
}

func validRequestBody(t *testing.T) string {
	t.Helper()
	body, err := json.Marshal(validRequest(t))
	if err != nil {
		t.Fatalf("marshal valid request: %v", err)
	}
	return string(body)
}

func mustJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal JSON fixture: %v", err)
	}
	return body
}

func int64Pointer(value int64) *int64 {
	return &value
}

func int32Pointer(value int32) *int32 {
	return &value
}

func okPayloadType(value any, want AddMovementPayload) bool {
	_, ok := value.(AddMovementPayload)
	return ok
}
