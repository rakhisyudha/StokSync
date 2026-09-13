// Package sync contains the versioned JSON boundary for push/pull
// synchronization. It deliberately does not apply operations or access a
// database; those responsibilities belong to later synchronization tasks.
package sync

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/google/uuid"
)

const (
	// SchemaVersion is the only sync wire schema understood by this server.
	SchemaVersion = 1
	// MinSupportedSchemaVersion is returned when a client sends an unsupported
	// schema version. Version negotiation is intentionally explicit rather than
	// silently accepting fields from an unknown schema.
	MinSupportedSchemaVersion = SchemaVersion

	OperationAddMovement   = "add_movement"
	OperationUpsertProduct = "upsert_product"
	OperationDeleteProduct = "delete_product"

	ResultStatusApplied  = "applied"
	ResultStatusRejected = "rejected"

	ErrorInvalidRequest           = "invalid_request"
	ErrorUnsupportedSchemaVersion = "unsupported_schema_version"

	// The defaults bound one sync exchange to a size appropriate for the v1
	// catalog while leaving room for a bounded batch of operations and changes.
	DefaultMaxRequestBytes          int64 = 1 << 20
	DefaultMaxOperations                  = 100
	DefaultMaxChanges                     = 500
	DefaultMaxOperationPayloadBytes int64 = 256 << 10
)

var (
	ErrInvalidRequest           = errors.New("invalid sync request")
	ErrInvalidOperation         = errors.New("invalid sync operation")
	ErrInvalidResponse          = errors.New("invalid sync response")
	ErrRequestTooLarge          = errors.New("sync request exceeds size limit")
	ErrTooManyOperations        = errors.New("sync request contains too many operations")
	ErrTooManyChanges           = errors.New("sync response contains too many changes")
	ErrMaxChangesExceeded       = errors.New("requested max_changes exceeds the server limit")
	ErrUnsupportedSchemaVersion = errors.New("unsupported sync schema version")
	ErrInvalidLimits            = errors.New("sync limits are invalid")
)

// Limits bounds decoding and validation of one sync exchange. MaxChanges also
// bounds a response because the request controls the maximum returned page.
type Limits struct {
	MaxRequestBytes          int64
	MaxOperations            int
	MaxChanges               int
	MaxOperationPayloadBytes int64
}

// DefaultLimits returns the safe v1 request/response bounds.
func DefaultLimits() Limits {
	return Limits{
		MaxRequestBytes:          DefaultMaxRequestBytes,
		MaxOperations:            DefaultMaxOperations,
		MaxChanges:               DefaultMaxChanges,
		MaxOperationPayloadBytes: DefaultMaxOperationPayloadBytes,
	}
}

// WithDefaults fills omitted configuration values. A smaller configured body
// limit also lowers the implicit per-operation payload limit so a valid small
// deployment configuration does not become invalid merely by omission.
func (l Limits) WithDefaults() Limits {
	defaults := DefaultLimits()
	if l.MaxRequestBytes == 0 {
		l.MaxRequestBytes = defaults.MaxRequestBytes
	}
	if l.MaxOperations == 0 {
		l.MaxOperations = defaults.MaxOperations
	}
	if l.MaxChanges == 0 {
		l.MaxChanges = defaults.MaxChanges
	}
	if l.MaxOperationPayloadBytes == 0 {
		l.MaxOperationPayloadBytes = defaults.MaxOperationPayloadBytes
		if l.MaxRequestBytes > 0 && l.MaxOperationPayloadBytes > l.MaxRequestBytes {
			l.MaxOperationPayloadBytes = l.MaxRequestBytes
		}
	}
	return l
}

// Validate checks that configured bounds are positive and internally
// consistent. Callers should call WithDefaults before Validate when accepting
// partial configuration.
func (l Limits) Validate() error {
	if l.MaxRequestBytes <= 0 || l.MaxOperations <= 0 || l.MaxChanges <= 0 || l.MaxOperationPayloadBytes <= 0 {
		return ErrInvalidLimits
	}
	if l.MaxOperationPayloadBytes > l.MaxRequestBytes {
		return ErrInvalidLimits
	}
	return nil
}

// ValidationError identifies a malformed field without exposing raw request
// data. It supports errors.Is for the broad request/operation/response class
// and the more specific sentinel carried in Kind.
type ValidationError struct {
	Kind   error
	Field  string
	Reason string
}

func (e *ValidationError) Error() string {
	if e == nil {
		return "invalid sync value"
	}
	if e.Field == "" {
		return "invalid sync value: " + e.Reason
	}
	return fmt.Sprintf("invalid sync field %q: %s", e.Field, e.Reason)
}

func (e *ValidationError) Is(target error) bool {
	if e == nil {
		return target == ErrInvalidRequest
	}
	return target == e.Kind || target == ErrInvalidRequest
}

func invalid(kind error, field, reason string) error {
	if kind == nil {
		kind = ErrInvalidRequest
	}
	return &ValidationError{Kind: kind, Field: field, Reason: reason}
}

// RequestLimitError reports a bounded request failure without retaining the
// request body. Kind is one of ErrRequestTooLarge, ErrTooManyOperations, or
// ErrMaxChangesExceeded.
type RequestLimitError struct {
	Kind   error
	Limit  int64
	Actual int64
}

func (e *RequestLimitError) Error() string {
	if e == nil || e.Kind == nil {
		return ErrInvalidRequest.Error()
	}
	return e.Kind.Error()
}

func (e *RequestLimitError) Is(target error) bool {
	if e == nil {
		return target == ErrInvalidRequest
	}
	return target == e.Kind || target == ErrInvalidRequest
}

// UnsupportedSchemaVersionError is returned for both older and newer schema
// versions. The minimum supported version is safe to expose to clients.
type UnsupportedSchemaVersionError struct {
	Received            int
	MinSupportedVersion int
}

func (e *UnsupportedSchemaVersionError) Error() string {
	if e == nil {
		return ErrUnsupportedSchemaVersion.Error()
	}
	return fmt.Sprintf("schema version %d is not supported; minimum supported version is %d", e.Received, e.MinSupportedVersion)
}

func (e *UnsupportedSchemaVersionError) Is(target error) bool {
	return target == ErrUnsupportedSchemaVersion || target == ErrInvalidRequest
}

// SyncRequest is the versioned push/pull request body for POST /v1/sync.
// Ops is intentionally a raw operation envelope collection: operation payloads
// are preserved exactly for idempotency storage and decoded by operation kind.
type SyncRequest struct {
	SchemaVersion int         `json:"schema_version"`
	DeviceID      uuid.UUID   `json:"device_id"`
	Cursor        int64       `json:"cursor"`
	MaxChanges    int         `json:"max_changes"`
	ClientTime    time.Time   `json:"client_time"`
	Ops           []Operation `json:"ops"`
}

// Validate applies the default protocol limits to a request.
func (r SyncRequest) Validate() error {
	return r.ValidateWithLimits(DefaultLimits())
}

// ValidateWithLimits validates schema negotiation, required request fields,
// operation count, and each operation's envelope/payload shape.
func (r SyncRequest) ValidateWithLimits(configured Limits) error {
	limits := configured.WithDefaults()
	if err := limits.Validate(); err != nil {
		return err
	}
	if r.SchemaVersion != SchemaVersion {
		return &UnsupportedSchemaVersionError{
			Received:            r.SchemaVersion,
			MinSupportedVersion: MinSupportedSchemaVersion,
		}
	}
	if r.DeviceID == uuid.Nil {
		return invalid(ErrInvalidRequest, "device_id", "is required")
	}
	if r.Cursor < 0 {
		return invalid(ErrInvalidRequest, "cursor", "must not be negative")
	}
	if r.MaxChanges <= 0 {
		return invalid(ErrInvalidRequest, "max_changes", "must be greater than zero")
	}
	if r.MaxChanges > limits.MaxChanges {
		return &RequestLimitError{Kind: ErrMaxChangesExceeded, Limit: int64(limits.MaxChanges), Actual: int64(r.MaxChanges)}
	}
	if r.ClientTime.IsZero() {
		return invalid(ErrInvalidRequest, "client_time", "is required and must be RFC3339")
	}
	if r.Ops == nil {
		return invalid(ErrInvalidRequest, "ops", "is required; use an empty array when there is no push work")
	}
	if len(r.Ops) > limits.MaxOperations {
		return &RequestLimitError{Kind: ErrTooManyOperations, Limit: int64(limits.MaxOperations), Actual: int64(len(r.Ops))}
	}
	for index, operation := range r.Ops {
		if err := operation.ValidateWithLimits(limits); err != nil {
			return fmt.Errorf("ops[%d]: %w", index, err)
		}
	}
	return nil
}

// DecodeRequest reads one bounded, strict JSON request. It rejects unknown
// top-level fields, trailing JSON values, oversized bodies, unsupported schema
// versions, and malformed operations before a future handler can transact.
func DecodeRequest(reader io.Reader, configured ...Limits) (SyncRequest, error) {
	limits, err := configuredLimits(configured)
	if err != nil {
		return SyncRequest{}, err
	}
	if reader == nil {
		return SyncRequest{}, invalid(ErrInvalidRequest, "body", "is required")
	}

	readLimit := limits.MaxRequestBytes
	if readLimit < int64(^uint64(0)>>1) {
		readLimit++
	}
	body, err := io.ReadAll(io.LimitReader(reader, readLimit))
	if err != nil {
		return SyncRequest{}, invalid(ErrInvalidRequest, "body", "could not be read")
	}
	if int64(len(body)) > limits.MaxRequestBytes {
		return SyncRequest{}, &RequestLimitError{Kind: ErrRequestTooLarge, Limit: limits.MaxRequestBytes, Actual: int64(len(body))}
	}

	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var request SyncRequest
	if err := decoder.Decode(&request); err != nil {
		return SyncRequest{}, invalid(ErrInvalidRequest, "body", "must contain one valid JSON object")
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return SyncRequest{}, invalid(ErrInvalidRequest, "body", "must contain exactly one JSON value")
	}
	if err := request.ValidateWithLimits(limits); err != nil {
		return SyncRequest{}, err
	}
	return request, nil
}

// DecodeSyncRequest is a descriptive alias used by HTTP transport callers.
func DecodeSyncRequest(reader io.Reader, configured ...Limits) (SyncRequest, error) {
	return DecodeRequest(reader, configured...)
}

func configuredLimits(configured []Limits) (Limits, error) {
	if len(configured) > 1 {
		return Limits{}, ErrInvalidLimits
	}
	limits := DefaultLimits()
	if len(configured) == 1 {
		limits = configured[0].WithDefaults()
	}
	if err := limits.Validate(); err != nil {
		return Limits{}, err
	}
	return limits, nil
}

// Operation is one idempotent client-originated operation. Payload remains a
// raw JSON object so the exact request can be retained and replayed; use
// DecodePayload or the operation-specific DTOs for typed inspection.
type Operation struct {
	OpID        uuid.UUID       `json:"op_id"`
	Op          string          `json:"op"`
	BaseVersion *int64          `json:"base_version,omitempty"`
	Payload     json.RawMessage `json:"payload"`
}

// Validate applies default limits to an operation.
func (o Operation) Validate() error {
	return o.ValidateWithLimits(DefaultLimits())
}

// ValidateWithLimits validates the operation name, identifier, optional base
// version, bounded object payload, and the known payload shape for that name.
func (o Operation) ValidateWithLimits(configured Limits) error {
	limits := configured.WithDefaults()
	if err := limits.Validate(); err != nil {
		return err
	}
	if o.OpID == uuid.Nil {
		return invalid(ErrInvalidOperation, "op_id", "is required")
	}
	if !isSupportedOperation(o.Op) {
		return invalid(ErrInvalidOperation, "op", "is not a supported operation")
	}
	if o.BaseVersion != nil && *o.BaseVersion < 0 {
		return invalid(ErrInvalidOperation, "base_version", "must not be negative")
	}
	trimmedPayload := bytes.TrimSpace(o.Payload)
	if len(trimmedPayload) == 0 {
		return invalid(ErrInvalidOperation, "payload", "is required")
	}
	if int64(len(trimmedPayload)) > limits.MaxOperationPayloadBytes {
		return &RequestLimitError{Kind: ErrRequestTooLarge, Limit: limits.MaxOperationPayloadBytes, Actual: int64(len(trimmedPayload))}
	}
	if !isJSONObject(trimmedPayload) {
		return invalid(ErrInvalidOperation, "payload", "must be a JSON object")
	}

	decoded, err := o.DecodePayload()
	if err != nil {
		return invalid(ErrInvalidOperation, "payload", "contains an unknown field or invalid value")
	}
	switch payload := decoded.(type) {
	case AddMovementPayload:
		if o.BaseVersion != nil {
			return invalid(ErrInvalidOperation, "base_version", "is only valid for product mutations")
		}
		if payload.ID == uuid.Nil {
			return invalid(ErrInvalidOperation, "payload.id", "is required")
		}
		if payload.ProductID == uuid.Nil {
			return invalid(ErrInvalidOperation, "payload.product_id", "is required")
		}
		if payload.Delta == 0 {
			return invalid(ErrInvalidOperation, "payload.delta", "must not be zero")
		}
		if !isMovementKind(payload.Kind) {
			return invalid(ErrInvalidOperation, "payload.kind", "is not a supported movement kind")
		}
		if payload.OccurredAt.IsZero() {
			return invalid(ErrInvalidOperation, "payload.occurred_at", "is required and must be RFC3339")
		}
		if payload.RawOccurredAt != nil && payload.RawOccurredAt.IsZero() {
			return invalid(ErrInvalidOperation, "payload.raw_occurred_at", "must be RFC3339 when provided")
		}
		if payload.DeviceID != nil && *payload.DeviceID == uuid.Nil {
			return invalid(ErrInvalidOperation, "payload.device_id", "must be a UUID when provided")
		}
		if payload.ReversesID != nil {
			if *payload.ReversesID == uuid.Nil {
				return invalid(ErrInvalidOperation, "payload.reverses_id", "must be a UUID when provided")
			}
			if payload.Kind != "adjust" {
				return invalid(ErrInvalidOperation, "payload.reverses_id", "is only valid for adjust movements")
			}
		}
		if payload.Kind == "stocktake" {
			if payload.CountedQty == nil || *payload.CountedQty < 0 {
				return invalid(ErrInvalidOperation, "payload.counted_qty", "is required and must not be negative for stocktake")
			}
		} else if payload.CountedQty != nil {
			return invalid(ErrInvalidOperation, "payload.counted_qty", "is only valid for stocktake")
		}
	case UpsertProductPayload:
		if payload.ID == uuid.Nil {
			return invalid(ErrInvalidOperation, "payload.id", "is required")
		}
		if strings.TrimSpace(payload.Name) == "" {
			return invalid(ErrInvalidOperation, "payload.name", "is required")
		}
		if payload.MinStock != nil && *payload.MinStock < 0 {
			return invalid(ErrInvalidOperation, "payload.min_stock", "must not be negative")
		}
	case DeleteProductPayload:
		if o.BaseVersion == nil || *o.BaseVersion <= 0 {
			return invalid(ErrInvalidOperation, "base_version", "is required and must be positive for product deletion")
		}
		if payload.ID == uuid.Nil {
			return invalid(ErrInvalidOperation, "payload.id", "is required")
		}
		if payload.DeletedAt != nil && payload.DeletedAt.IsZero() {
			return invalid(ErrInvalidOperation, "payload.deleted_at", "must be RFC3339 when provided")
		}
	}
	return nil
}

func isSupportedOperation(value string) bool {
	switch value {
	case OperationAddMovement, OperationUpsertProduct, OperationDeleteProduct:
		return true
	default:
		return false
	}
}

func isMovementKind(value string) bool {
	switch value {
	case "receive", "issue", "adjust", "stocktake":
		return true
	default:
		return false
	}
}

// AddMovementPayload is the client-owned immutable movement payload. Timing
// and device fields are optional for compatibility with the minimal wire
// example; the server may fill safe defaults from authenticated context.
type AddMovementPayload struct {
	ID            uuid.UUID  `json:"id"`
	ProductID     uuid.UUID  `json:"product_id"`
	Delta         int32      `json:"delta"`
	Kind          string     `json:"kind"`
	Note          *string    `json:"note,omitempty"`
	OccurredAt    time.Time  `json:"occurred_at"`
	RawOccurredAt *time.Time `json:"raw_occurred_at,omitempty"`
	ClockOffsetMs int64      `json:"clock_offset_ms,omitempty"`
	CountedQty    *int32     `json:"counted_qty,omitempty"`
	ReversesID    *uuid.UUID `json:"reverses_id,omitempty"`
	DeviceID      *uuid.UUID `json:"device_id,omitempty"`
}

// UpsertProductPayload is the complete client-owned product representation.
type UpsertProductPayload struct {
	ID          uuid.UUID `json:"id"`
	Barcode     *string   `json:"barcode,omitempty"`
	SKU         *string   `json:"sku,omitempty"`
	Name        string    `json:"name"`
	Description *string   `json:"description,omitempty"`
	Unit        string    `json:"unit,omitempty"`
	Category    *string   `json:"category,omitempty"`
	MinStock    *int32    `json:"min_stock,omitempty"`
}

// DeleteProductPayload identifies a version-checked product tombstone.
type DeleteProductPayload struct {
	ID        uuid.UUID  `json:"id"`
	DeletedAt *time.Time `json:"deleted_at,omitempty"`
}

// DecodePayload strictly decodes the payload according to its operation name.
func (o Operation) DecodePayload() (any, error) {
	switch o.Op {
	case OperationAddMovement:
		var payload AddMovementPayload
		if err := decodeStrictObject(o.Payload, &payload); err != nil {
			return nil, err
		}
		return payload, nil
	case OperationUpsertProduct:
		var payload UpsertProductPayload
		if err := decodeStrictObject(o.Payload, &payload); err != nil {
			return nil, err
		}
		return payload, nil
	case OperationDeleteProduct:
		var payload DeleteProductPayload
		if err := decodeStrictObject(o.Payload, &payload); err != nil {
			return nil, err
		}
		return payload, nil
	default:
		return nil, invalid(ErrInvalidOperation, "op", "is not a supported operation")
	}
}

func decodeStrictObject(raw json.RawMessage, destination any) error {
	trimmed := bytes.TrimSpace(raw)
	if !isJSONObject(trimmed) {
		return errors.New("payload must be a JSON object")
	}
	decoder := json.NewDecoder(bytes.NewReader(trimmed))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("payload must contain exactly one JSON object")
	}
	return nil
}

func isJSONObject(raw []byte) bool {
	if len(raw) < 2 || raw[0] != '{' || raw[len(raw)-1] != '}' {
		return false
	}
	var fields map[string]json.RawMessage
	return json.Unmarshal(raw, &fields) == nil && fields != nil
}

// OperationResult records one independent operation outcome. Applied results
// carry the canonical change sequence; rejected results carry a stable reason
// and may include the canonical server state for conflict inspection.
type OperationResult struct {
	OpID        uuid.UUID       `json:"op_id"`
	Status      string          `json:"status"`
	Seq         *int64          `json:"seq,omitempty"`
	Reason      string          `json:"reason,omitempty"`
	ServerState json.RawMessage `json:"server_state,omitempty"`
}

// ChangeEntry is one ordered canonical change-feed entry returned after push.
type ChangeEntry struct {
	Seq            int64           `json:"seq"`
	Entity         string          `json:"entity"`
	Op             string          `json:"op"`
	Data           json.RawMessage `json:"data"`
	OriginDeviceID *uuid.UUID      `json:"origin_device_id,omitempty"`
	CreatedAt      *time.Time      `json:"created_at,omitempty"`
}

// SyncResponse is the versioned push/pull response body.
type SyncResponse struct {
	SchemaVersion int               `json:"schema_version"`
	Results       []OperationResult `json:"results"`
	Changes       []ChangeEntry     `json:"changes"`
	NextCursor    int64             `json:"next_cursor"`
	HasMore       bool              `json:"has_more"`
	ServerTime    time.Time         `json:"server_time"`
}

// NewSyncResponse constructs a response with the current schema version and
// non-nil arrays, making an empty successful exchange encode as [] rather than
// null.
func NewSyncResponse(results []OperationResult, changes []ChangeEntry, nextCursor int64, hasMore bool, serverTime time.Time) SyncResponse {
	if results == nil {
		results = []OperationResult{}
	}
	if changes == nil {
		changes = []ChangeEntry{}
	}
	return SyncResponse{
		SchemaVersion: SchemaVersion,
		Results:       results,
		Changes:       changes,
		NextCursor:    nextCursor,
		HasMore:       hasMore,
		ServerTime:    serverTime.UTC(),
	}
}

// Validate applies the default response bounds.
func (r SyncResponse) Validate() error {
	return r.ValidateWithLimits(DefaultLimits())
}

// ValidateWithLimits validates response metadata, independently classified
// results, and ascending bounded change entries before encoding.
func (r SyncResponse) ValidateWithLimits(configured Limits) error {
	limits := configured.WithDefaults()
	if err := limits.Validate(); err != nil {
		return err
	}
	if r.SchemaVersion != SchemaVersion {
		return &UnsupportedSchemaVersionError{Received: r.SchemaVersion, MinSupportedVersion: MinSupportedSchemaVersion}
	}
	if r.NextCursor < 0 {
		return invalid(ErrInvalidResponse, "next_cursor", "must not be negative")
	}
	if r.ServerTime.IsZero() {
		return invalid(ErrInvalidResponse, "server_time", "is required and must be RFC3339")
	}
	if len(r.Results) > limits.MaxOperations {
		return &RequestLimitError{Kind: ErrTooManyOperations, Limit: int64(limits.MaxOperations), Actual: int64(len(r.Results))}
	}
	if len(r.Changes) > limits.MaxChanges {
		return &RequestLimitError{Kind: ErrTooManyChanges, Limit: int64(limits.MaxChanges), Actual: int64(len(r.Changes))}
	}
	for index, result := range r.Results {
		if result.OpID == uuid.Nil {
			return invalid(ErrInvalidResponse, fmt.Sprintf("results[%d].op_id", index), "is required")
		}
		switch result.Status {
		case ResultStatusApplied:
			if result.Seq == nil || *result.Seq <= 0 {
				return invalid(ErrInvalidResponse, fmt.Sprintf("results[%d].seq", index), "is required and must be positive for applied results")
			}
			if result.Reason != "" || len(bytes.TrimSpace(result.ServerState)) != 0 {
				return invalid(ErrInvalidResponse, fmt.Sprintf("results[%d]", index), "applied results cannot contain rejection fields")
			}
		case ResultStatusRejected:
			if strings.TrimSpace(result.Reason) == "" {
				return invalid(ErrInvalidResponse, fmt.Sprintf("results[%d].reason", index), "is required for rejected results")
			}
			if result.Seq != nil {
				return invalid(ErrInvalidResponse, fmt.Sprintf("results[%d].seq", index), "must be omitted for rejected results")
			}
			if len(bytes.TrimSpace(result.ServerState)) != 0 && !isJSONObject(bytes.TrimSpace(result.ServerState)) {
				return invalid(ErrInvalidResponse, fmt.Sprintf("results[%d].server_state", index), "must be a JSON object")
			}
		default:
			return invalid(ErrInvalidResponse, fmt.Sprintf("results[%d].status", index), "must be applied or rejected")
		}
	}
	var previousSeq int64
	for index, change := range r.Changes {
		if change.Seq <= 0 {
			return invalid(ErrInvalidResponse, fmt.Sprintf("changes[%d].seq", index), "must be positive")
		}
		if index > 0 && change.Seq <= previousSeq {
			return invalid(ErrInvalidResponse, fmt.Sprintf("changes[%d].seq", index), "must be strictly ascending")
		}
		previousSeq = change.Seq
		if strings.TrimSpace(change.Entity) == "" || strings.TrimSpace(change.Op) == "" {
			return invalid(ErrInvalidResponse, fmt.Sprintf("changes[%d]", index), "entity and op are required")
		}
		if !isJSONObject(bytes.TrimSpace(change.Data)) {
			return invalid(ErrInvalidResponse, fmt.Sprintf("changes[%d].data", index), "must be a JSON object")
		}
		if change.CreatedAt != nil && change.CreatedAt.IsZero() {
			return invalid(ErrInvalidResponse, fmt.Sprintf("changes[%d].created_at", index), "must be RFC3339 when provided")
		}
	}
	if len(r.Changes) > 0 && r.NextCursor < previousSeq {
		return invalid(ErrInvalidResponse, "next_cursor", "must not precede the last returned change")
	}
	return nil
}

// MarshalResponse validates and returns one complete JSON response body.
func MarshalResponse(response SyncResponse, configured ...Limits) ([]byte, error) {
	limits, err := configuredLimits(configured)
	if err != nil {
		return nil, err
	}
	if err := response.ValidateWithLimits(limits); err != nil {
		return nil, err
	}
	response = normalizedResponse(response)
	return json.Marshal(response)
}

// EncodeResponse validates before writing, so an invalid response cannot leave
// a caller with a partial success body.
func EncodeResponse(writer io.Writer, response SyncResponse, configured ...Limits) error {
	if writer == nil {
		return invalid(ErrInvalidResponse, "writer", "is required")
	}
	limits, err := configuredLimits(configured)
	if err != nil {
		return err
	}
	if err := response.ValidateWithLimits(limits); err != nil {
		return err
	}
	return json.NewEncoder(writer).Encode(normalizedResponse(response))
}

func normalizedResponse(response SyncResponse) SyncResponse {
	if response.Results == nil {
		response.Results = []OperationResult{}
	}
	if response.Changes == nil {
		response.Changes = []ChangeEntry{}
	}
	response.ServerTime = response.ServerTime.UTC()
	return response
}

// ErrorResponse is the stable versioned error envelope used by the future
// sync handler. MinSupportedVersion is present only for schema negotiation.
type ErrorResponse struct {
	SchemaVersion       int    `json:"schema_version"`
	Error               string `json:"error"`
	MinSupportedVersion int    `json:"min_supported_version,omitempty"`
}

// ErrorResponseFor returns a safe error DTO for a decoder/validator error.
func ErrorResponseFor(err error) ErrorResponse {
	response := ErrorResponse{SchemaVersion: SchemaVersion, Error: ErrorInvalidRequest}
	var schemaErr *UnsupportedSchemaVersionError
	if errors.As(err, &schemaErr) {
		response.Error = ErrorUnsupportedSchemaVersion
		response.MinSupportedVersion = schemaErr.MinSupportedVersion
	}
	return response
}
