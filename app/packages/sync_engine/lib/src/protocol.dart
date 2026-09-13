import 'dart:convert';

import 'errors.dart';

/// The only wire schema supported by the v1 sync endpoint.
const int syncSchemaVersion = 1;

/// Server-side default bounds mirrored by the client DTO validator.
const int syncMaxOperations = 100;
const int syncMaxChanges = 500;

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final RegExp _rfc3339UtcPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$',
);

/// Operation names accepted by `POST /v1/sync`.
enum SyncOperationKind {
  addMovement('add_movement'),
  upsertProduct('upsert_product'),
  deleteProduct('delete_product');

  const SyncOperationKind(this.wireValue);

  final String wireValue;

  static SyncOperationKind fromJson(Object? value, String field) {
    final wireValue = _requiredString(value, field);
    for (final kind in values) {
      if (kind.wireValue == wireValue) {
        return kind;
      }
    }
    throw SyncProtocolException(
      SyncProtocolErrorKind.invalidValue,
      'operation is not supported',
      field: field,
    );
  }
}

enum SyncOperationResultStatus {
  applied('applied'),
  rejected('rejected');

  const SyncOperationResultStatus(this.wireValue);

  final String wireValue;

  static SyncOperationResultStatus fromJson(Object? value, String field) {
    final wireValue = _requiredString(value, field);
    for (final status in values) {
      if (status.wireValue == wireValue) {
        return status;
      }
    }
    throw SyncProtocolException(
      SyncProtocolErrorKind.invalidValue,
      'result status is not supported',
      field: field,
    );
  }
}

/// A typed payload for one operation envelope.
sealed class SyncOperationPayload {
  const SyncOperationPayload();

  Map<String, Object?> toJson();
}

/// Immutable movement payload accepted by `add_movement`.
final class AddMovementPayload extends SyncOperationPayload {
  const AddMovementPayload({
    required this.id,
    required this.productId,
    required this.delta,
    required this.kind,
    required this.occurredAt,
    this.note,
    this.rawOccurredAt,
    this.clockOffsetMs = 0,
    this.countedQty,
    this.reversesId,
    this.deviceId,
  });

  final String id;
  final String productId;
  final int delta;
  final String kind;
  final String? note;
  final DateTime occurredAt;
  final DateTime? rawOccurredAt;
  final int clockOffsetMs;
  final int? countedQty;
  final String? reversesId;
  final String? deviceId;

  @override
  Map<String, Object?> toJson() {
    _validateUuid(id, 'payload.id');
    _validateUuid(productId, 'payload.product_id');
    _validateInt32(delta, 'payload.delta');
    if (delta == 0) {
      throw _invalid('payload.delta', 'must not be zero');
    }
    if (!_movementKinds.contains(kind)) {
      throw _invalid('payload.kind', 'is not supported');
    }
    final occurredAtValue = _timestamp(occurredAt, 'payload.occurred_at');
    final rawOccurredAtValue = rawOccurredAt == null
        ? null
        : _timestamp(rawOccurredAt!, 'payload.raw_occurred_at');
    if (countedQty != null) {
      _validateInt32(countedQty!, 'payload.counted_qty');
      if (countedQty! < 0) {
        throw _invalid('payload.counted_qty', 'must not be negative');
      }
    }
    if (kind == 'stocktake' && countedQty == null) {
      throw _invalid(
        'payload.counted_qty',
        'is required for stocktake movements',
      );
    }
    if (kind != 'stocktake' && countedQty != null) {
      throw _invalid(
        'payload.counted_qty',
        'is only valid for stocktake movements',
      );
    }
    if (reversesId != null) {
      _validateUuid(reversesId!, 'payload.reverses_id');
      if (kind != 'adjust') {
        throw _invalid(
          'payload.reverses_id',
          'is only valid for adjust movements',
        );
      }
    }
    if (deviceId != null) {
      _validateUuid(deviceId!, 'payload.device_id');
    }

    return <String, Object?>{
      'id': id,
      'product_id': productId,
      'delta': delta,
      'kind': kind,
      if (note != null) 'note': note,
      'occurred_at': occurredAtValue,
      if (rawOccurredAtValue != null) 'raw_occurred_at': rawOccurredAtValue,
      if (clockOffsetMs != 0) 'clock_offset_ms': clockOffsetMs,
      if (countedQty != null) 'counted_qty': countedQty,
      if (reversesId != null) 'reverses_id': reversesId,
      if (deviceId != null) 'device_id': deviceId,
    };
  }

  static AddMovementPayload fromJson(Object? value) {
    final map = _object(value, 'payload');
    _checkKeys(
      map,
      const {
        'id',
        'product_id',
        'delta',
        'kind',
        'note',
        'occurred_at',
        'raw_occurred_at',
        'clock_offset_ms',
        'counted_qty',
        'reverses_id',
        'device_id',
      },
      const {'id', 'product_id', 'delta', 'kind', 'occurred_at'},
      'payload',
    );
    final payload = AddMovementPayload(
      id: _uuid(map['id'], 'payload.id'),
      productId: _uuid(map['product_id'], 'payload.product_id'),
      delta: _int(map['delta'], 'payload.delta'),
      kind: _requiredString(map['kind'], 'payload.kind'),
      note: _optionalString(map['note'], 'payload.note'),
      occurredAt: _dateTime(map['occurred_at'], 'payload.occurred_at'),
      rawOccurredAt: _optionalDateTime(
        map['raw_occurred_at'],
        'payload.raw_occurred_at',
      ),
      clockOffsetMs:
          _optionalInt(map['clock_offset_ms'], 'payload.clock_offset_ms') ?? 0,
      countedQty: _optionalInt(map['counted_qty'], 'payload.counted_qty'),
      reversesId: _optionalUuid(map['reverses_id'], 'payload.reverses_id'),
      deviceId: _optionalUuid(map['device_id'], 'payload.device_id'),
    );
    payload.toJson();
    return payload;
  }
}

/// Product representation carried by `upsert_product`.
final class UpsertProductPayload extends SyncOperationPayload {
  const UpsertProductPayload({
    required this.id,
    required this.name,
    this.barcode,
    this.sku,
    this.description,
    this.unit,
    this.category,
    this.minStock,
  });

  final String id;
  final String? barcode;
  final String? sku;
  final String name;
  final String? description;
  final String? unit;
  final String? category;
  final int? minStock;

  @override
  Map<String, Object?> toJson() {
    _validateUuid(id, 'payload.id');
    if (name.trim().isEmpty) {
      throw _invalid('payload.name', 'must not be blank');
    }
    if (minStock != null) {
      _validateInt32(minStock!, 'payload.min_stock');
      if (minStock! < 0) {
        throw _invalid('payload.min_stock', 'must not be negative');
      }
    }
    return <String, Object?>{
      'id': id,
      if (barcode != null) 'barcode': barcode,
      if (sku != null) 'sku': sku,
      'name': name,
      if (description != null) 'description': description,
      if (unit != null) 'unit': unit,
      if (category != null) 'category': category,
      if (minStock != null) 'min_stock': minStock,
    };
  }

  static UpsertProductPayload fromJson(Object? value) {
    final map = _object(value, 'payload');
    _checkKeys(
      map,
      const {
        'id',
        'barcode',
        'sku',
        'name',
        'description',
        'unit',
        'category',
        'min_stock',
      },
      const {'id', 'name'},
      'payload',
    );
    final payload = UpsertProductPayload(
      id: _uuid(map['id'], 'payload.id'),
      barcode: _optionalString(map['barcode'], 'payload.barcode'),
      sku: _optionalString(map['sku'], 'payload.sku'),
      name: _requiredString(map['name'], 'payload.name'),
      description: _optionalString(map['description'], 'payload.description'),
      unit: _optionalString(map['unit'], 'payload.unit'),
      category: _optionalString(map['category'], 'payload.category'),
      minStock: _optionalInt(map['min_stock'], 'payload.min_stock'),
    );
    payload.toJson();
    return payload;
  }
}

/// Product tombstone payload carried by `delete_product`.
final class DeleteProductPayload extends SyncOperationPayload {
  const DeleteProductPayload({required this.id, this.deletedAt});

  final String id;
  final DateTime? deletedAt;

  @override
  Map<String, Object?> toJson() {
    _validateUuid(id, 'payload.id');
    return <String, Object?>{
      'id': id,
      if (deletedAt != null)
        'deleted_at': _timestamp(deletedAt!, 'payload.deleted_at'),
    };
  }

  static DeleteProductPayload fromJson(Object? value) {
    final map = _object(value, 'payload');
    _checkKeys(map, const {'id', 'deleted_at'}, const {'id'}, 'payload');
    final payload = DeleteProductPayload(
      id: _uuid(map['id'], 'payload.id'),
      deletedAt: _optionalDateTime(map['deleted_at'], 'payload.deleted_at'),
    );
    payload.toJson();
    return payload;
  }
}

/// One idempotent operation in a sync request.
final class SyncOperation {
  const SyncOperation({
    required this.opId,
    required this.kind,
    required this.payload,
    this.baseVersion,
  });

  final String opId;
  final SyncOperationKind kind;
  final SyncOperationPayload payload;
  final int? baseVersion;

  factory SyncOperation.addMovement({
    required String opId,
    required AddMovementPayload payload,
  }) => SyncOperation(
    opId: opId,
    kind: SyncOperationKind.addMovement,
    payload: payload,
  );

  factory SyncOperation.upsertProduct({
    required String opId,
    required UpsertProductPayload payload,
    int? baseVersion,
  }) => SyncOperation(
    opId: opId,
    kind: SyncOperationKind.upsertProduct,
    payload: payload,
    baseVersion: baseVersion,
  );

  factory SyncOperation.deleteProduct({
    required String opId,
    required DeleteProductPayload payload,
    required int baseVersion,
  }) => SyncOperation(
    opId: opId,
    kind: SyncOperationKind.deleteProduct,
    payload: payload,
    baseVersion: baseVersion,
  );

  Map<String, Object?> toJson() {
    _validateUuid(opId, 'op_id');
    if (baseVersion != null && baseVersion! < 0) {
      throw _invalid('base_version', 'must not be negative');
    }
    _validatePayloadType();
    return <String, Object?>{
      'op_id': opId,
      'op': kind.wireValue,
      if (baseVersion != null) 'base_version': baseVersion,
      'payload': payload.toJson(),
    };
  }

  static SyncOperation fromJson(Object? value) {
    final map = _object(value, 'operation');
    _checkKeys(
      map,
      const {'op_id', 'op', 'base_version', 'payload'},
      const {'op_id', 'op', 'payload'},
      'operation',
    );
    final kind = SyncOperationKind.fromJson(map['op'], 'op');
    final payloadValue = switch (kind) {
      SyncOperationKind.addMovement => AddMovementPayload.fromJson(
        map['payload'],
      ),
      SyncOperationKind.upsertProduct => UpsertProductPayload.fromJson(
        map['payload'],
      ),
      SyncOperationKind.deleteProduct => DeleteProductPayload.fromJson(
        map['payload'],
      ),
    };
    final operation = SyncOperation(
      opId: _uuid(map['op_id'], 'op_id'),
      kind: kind,
      payload: payloadValue,
      baseVersion: _optionalInt(map['base_version'], 'base_version'),
    );
    operation.toJson();
    return operation;
  }

  void _validatePayloadType() {
    final isValid = switch (kind) {
      SyncOperationKind.addMovement => payload is AddMovementPayload,
      SyncOperationKind.upsertProduct => payload is UpsertProductPayload,
      SyncOperationKind.deleteProduct => payload is DeleteProductPayload,
    };
    if (!isValid) {
      throw _invalid('payload', 'does not match the operation');
    }
  }
}

/// Versioned request body for `POST /v1/sync`.
final class SyncRequest {
  const SyncRequest({
    required this.deviceId,
    required this.cursor,
    required this.maxChanges,
    required this.clientTime,
    required this.operations,
  });

  final String deviceId;
  final int cursor;
  final int maxChanges;
  final DateTime clientTime;
  final List<SyncOperation> operations;

  Map<String, Object?> toJson() {
    _validateUuid(deviceId, 'device_id');
    _validateRequestBounds(cursor, maxChanges, operations.length);
    return <String, Object?>{
      'schema_version': syncSchemaVersion,
      'device_id': deviceId,
      'cursor': cursor,
      'max_changes': maxChanges,
      'client_time': _timestamp(clientTime, 'client_time'),
      'ops': operations.map((operation) => operation.toJson()).toList(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static SyncRequest fromJson(Object? value) {
    final map = _object(value, 'request');
    _checkKeys(
      map,
      const {
        'schema_version',
        'device_id',
        'cursor',
        'max_changes',
        'client_time',
        'ops',
      },
      const {
        'schema_version',
        'device_id',
        'cursor',
        'max_changes',
        'client_time',
        'ops',
      },
      'request',
    );
    _validateSchema(_int(map['schema_version'], 'schema_version'));
    final operations = _list(map['ops'], 'ops')
        .asMap()
        .entries
        .map((entry) => SyncOperation.fromJson(entry.value))
        .toList(growable: false);
    final request = SyncRequest(
      deviceId: _uuid(map['device_id'], 'device_id'),
      cursor: _int(map['cursor'], 'cursor'),
      maxChanges: _int(map['max_changes'], 'max_changes'),
      clientTime: _dateTime(map['client_time'], 'client_time'),
      operations: operations,
    );
    request.toJson();
    return request;
  }

  static SyncRequest fromJsonString(String source) {
    return SyncRequest.fromJson(_decodeJson(source, 'request'));
  }
}

/// One operation outcome returned by the server.
final class SyncOperationResult {
  const SyncOperationResult({
    required this.opId,
    required this.status,
    this.seq,
    this.reason,
    this.serverState,
  });

  final String opId;
  final SyncOperationResultStatus status;
  final int? seq;
  final String? reason;
  final Map<String, Object?>? serverState;

  Map<String, Object?> toJson() {
    _validateUuid(opId, 'results.op_id');
    switch (status) {
      case SyncOperationResultStatus.applied:
        if (seq == null || seq! <= 0) {
          throw _invalid('results.seq', 'must be positive when applied');
        }
        if (reason != null || serverState != null) {
          throw _invalid(
            'results',
            'applied results cannot contain rejection fields',
          );
        }
      case SyncOperationResultStatus.rejected:
        if (reason == null || reason!.trim().isEmpty) {
          throw _invalid('results.reason', 'is required when rejected');
        }
        if (seq != null) {
          throw _invalid('results.seq', 'must be omitted when rejected');
        }
    }
    return <String, Object?>{
      'op_id': opId,
      'status': status.wireValue,
      if (seq != null) 'seq': seq,
      if (reason != null) 'reason': reason,
      if (serverState != null) 'server_state': serverState,
    };
  }

  static SyncOperationResult fromJson(Object? value) {
    final map = _object(value, 'result');
    _checkKeys(
      map,
      const {'op_id', 'status', 'seq', 'reason', 'server_state'},
      const {'op_id', 'status'},
      'result',
    );
    final result = SyncOperationResult(
      opId: _uuid(map['op_id'], 'results.op_id'),
      status: SyncOperationResultStatus.fromJson(
        map['status'],
        'results.status',
      ),
      seq: _optionalInt(map['seq'], 'results.seq'),
      reason: _optionalString(map['reason'], 'results.reason'),
      serverState: _optionalObject(map['server_state'], 'results.server_state'),
    );
    result.toJson();
    return result;
  }
}

/// One ordered canonical change entry returned by the server.
final class SyncChangeEntry {
  const SyncChangeEntry({
    required this.seq,
    required this.entity,
    required this.operation,
    required this.data,
    this.originDeviceId,
    this.createdAt,
  });

  final int seq;
  final String entity;
  final String operation;
  final Map<String, Object?> data;
  final String? originDeviceId;
  final DateTime? createdAt;

  Map<String, Object?> toJson() {
    if (seq <= 0) {
      throw _invalid('changes.seq', 'must be positive');
    }
    if (entity.trim().isEmpty || operation.trim().isEmpty) {
      throw _invalid('changes', 'entity and op are required');
    }
    if (originDeviceId != null) {
      _validateUuid(originDeviceId!, 'changes.origin_device_id');
    }
    return <String, Object?>{
      'seq': seq,
      'entity': entity,
      'op': operation,
      'data': data,
      if (originDeviceId != null) 'origin_device_id': originDeviceId,
      if (createdAt != null)
        'created_at': _timestamp(createdAt!, 'changes.created_at'),
    };
  }

  static SyncChangeEntry fromJson(Object? value) {
    final map = _object(value, 'change');
    _checkKeys(
      map,
      const {'seq', 'entity', 'op', 'data', 'origin_device_id', 'created_at'},
      const {'seq', 'entity', 'op', 'data'},
      'change',
    );
    final entry = SyncChangeEntry(
      seq: _int(map['seq'], 'changes.seq'),
      entity: _requiredString(map['entity'], 'changes.entity'),
      operation: _requiredString(map['op'], 'changes.op'),
      data: _object(map['data'], 'changes.data'),
      originDeviceId: _optionalUuid(
        map['origin_device_id'],
        'changes.origin_device_id',
      ),
      createdAt: _optionalDateTime(map['created_at'], 'changes.created_at'),
    );
    entry.toJson();
    return entry;
  }
}

/// Versioned push/pull response body for `POST /v1/sync`.
final class SyncResponse {
  const SyncResponse({
    required this.results,
    required this.changes,
    required this.nextCursor,
    required this.hasMore,
    required this.serverTime,
  });

  final List<SyncOperationResult> results;
  final List<SyncChangeEntry> changes;
  final int nextCursor;
  final bool hasMore;
  final DateTime serverTime;

  Map<String, Object?> toJson() {
    if (results.length > syncMaxOperations) {
      throw _invalid('results', 'contains too many operation results');
    }
    if (changes.length > syncMaxChanges) {
      throw _invalid('changes', 'contains too many change entries');
    }
    if (nextCursor < 0) {
      throw _invalid('next_cursor', 'must not be negative');
    }
    var previousSeq = 0;
    for (var index = 0; index < changes.length; index++) {
      final change = changes[index];
      final changeJson = change.toJson();
      final currentSeq = changeJson['seq']! as int;
      if (index > 0 && currentSeq <= previousSeq) {
        throw _invalid('changes[$index].seq', 'must be strictly ascending');
      }
      previousSeq = currentSeq;
    }
    if (changes.isNotEmpty && nextCursor < previousSeq) {
      throw _invalid(
        'next_cursor',
        'must not precede the last returned change',
      );
    }
    return <String, Object?>{
      'schema_version': syncSchemaVersion,
      'results': results.map((result) => result.toJson()).toList(),
      'changes': changes.map((change) => change.toJson()).toList(),
      'next_cursor': nextCursor,
      'has_more': hasMore,
      'server_time': _timestamp(serverTime, 'server_time'),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static SyncResponse fromJson(Object? value) {
    final map = _object(value, 'response');
    _checkKeys(
      map,
      const {
        'schema_version',
        'results',
        'changes',
        'next_cursor',
        'has_more',
        'server_time',
      },
      const {
        'schema_version',
        'results',
        'changes',
        'next_cursor',
        'has_more',
        'server_time',
      },
      'response',
    );
    _validateSchema(_int(map['schema_version'], 'schema_version'));
    final results = _list(
      map['results'],
      'results',
    ).map(SyncOperationResult.fromJson).toList(growable: false);
    final changes = _list(
      map['changes'],
      'changes',
    ).map(SyncChangeEntry.fromJson).toList(growable: false);
    if (results.length > syncMaxOperations) {
      throw _invalid('results', 'contains too many operation results');
    }
    if (changes.length > syncMaxChanges) {
      throw _invalid('changes', 'contains too many change entries');
    }
    final response = SyncResponse(
      results: results,
      changes: changes,
      nextCursor: _int(map['next_cursor'], 'next_cursor'),
      hasMore: _bool(map['has_more'], 'has_more'),
      serverTime: _dateTime(map['server_time'], 'server_time'),
    );
    response.toJson();
    return response;
  }

  static SyncResponse fromJsonString(String source) {
    return SyncResponse.fromJson(_decodeJson(source, 'response'));
  }
}

/// Stable error envelope returned for non-successful sync requests.
final class SyncErrorEnvelope {
  const SyncErrorEnvelope({
    required this.schemaVersion,
    required this.error,
    this.minimumSupportedVersion,
  });

  final int schemaVersion;
  final String error;
  final int? minimumSupportedVersion;

  Map<String, Object?> toJson() {
    _validateSchema(schemaVersion);
    if (error.trim().isEmpty) {
      throw _invalid('error', 'must be a non-empty string');
    }
    if (minimumSupportedVersion != null && minimumSupportedVersion! < 0) {
      throw _invalid('min_supported_version', 'must not be negative');
    }
    if (error == 'unsupported_schema_version' &&
        minimumSupportedVersion == null) {
      throw SyncProtocolException(
        SyncProtocolErrorKind.invalidErrorEnvelope,
        'minimum supported version is required for schema negotiation',
        field: 'min_supported_version',
      );
    }
    return <String, Object?>{
      'schema_version': schemaVersion,
      'error': error,
      if (minimumSupportedVersion != null)
        'min_supported_version': minimumSupportedVersion,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static SyncErrorEnvelope fromJson(Object? value) {
    final map = _object(value, 'error');
    _checkKeys(
      map,
      const {'schema_version', 'error', 'min_supported_version'},
      const {'schema_version', 'error'},
      'error',
    );
    final schemaVersion = _int(map['schema_version'], 'schema_version');
    _validateSchema(schemaVersion);
    final error = _requiredString(map['error'], 'error');
    final minimumSupportedVersion = _optionalInt(
      map['min_supported_version'],
      'min_supported_version',
    );
    if (error == 'unsupported_schema_version' &&
        minimumSupportedVersion == null) {
      throw SyncProtocolException(
        SyncProtocolErrorKind.invalidErrorEnvelope,
        'minimum supported version is required for schema negotiation',
        field: 'min_supported_version',
      );
    }
    return SyncErrorEnvelope(
      schemaVersion: schemaVersion,
      error: error,
      minimumSupportedVersion: minimumSupportedVersion,
    );
  }

  static SyncErrorEnvelope fromJsonString(String source) {
    return SyncErrorEnvelope.fromJson(_decodeJson(source, 'error'));
  }
}

const Set<String> _movementKinds = {'receive', 'issue', 'adjust', 'stocktake'};

void _validateRequestBounds(int cursor, int maxChanges, int operationCount) {
  if (cursor < 0) {
    throw _invalid('cursor', 'must not be negative');
  }
  if (maxChanges <= 0 || maxChanges > syncMaxChanges) {
    throw _invalid('max_changes', 'is outside the supported bounds');
  }
  if (operationCount > syncMaxOperations) {
    throw _invalid('ops', 'contains too many operations');
  }
}

void _validateSchema(int version) {
  if (version != syncSchemaVersion) {
    throw UnsupportedSchemaVersionException(
      receivedVersion: version,
      minimumSupportedVersion: syncSchemaVersion,
    );
  }
}

void _validateUuid(String value, String field) {
  if (!_uuidPattern.hasMatch(value) ||
      value.toLowerCase() == '00000000-0000-0000-0000-000000000000') {
    throw _invalid(field, 'must be a non-zero UUID string');
  }
}

String _uuid(Object? value, String field) {
  final result = _requiredString(value, field);
  _validateUuid(result, field);
  return result;
}

String? _optionalUuid(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _uuid(value, field);
}

void _validateInt32(int value, String field) {
  if (value < -2147483648 || value > 2147483647) {
    throw _invalid(field, 'is outside the supported integer range');
  }
}

int _int(Object? value, String field) {
  if (value is! int) {
    throw _invalid(field, 'must be an integer');
  }
  return value;
}

int? _optionalInt(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _int(value, field);
}

String _requiredString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw _invalid(field, 'must be a non-empty string');
  }
  return value;
}

String? _optionalString(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw _invalid(field, 'must be a string when provided');
  }
  return value;
}

bool _bool(Object? value, String field) {
  if (value is! bool) {
    throw _invalid(field, 'must be a boolean');
  }
  return value;
}

DateTime _dateTime(Object? value, String field) {
  final text = _requiredString(value, field);
  final match = _rfc3339UtcPattern.firstMatch(text);
  if (match == null) {
    throw _invalid(field, 'must be an RFC3339 UTC timestamp');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null ||
      !parsed.isUtc ||
      parsed.year != int.parse(match.group(1)!) ||
      parsed.month != int.parse(match.group(2)!) ||
      parsed.day != int.parse(match.group(3)!) ||
      parsed.hour != int.parse(match.group(4)!) ||
      parsed.minute != int.parse(match.group(5)!) ||
      parsed.second != int.parse(match.group(6)!)) {
    throw _invalid(field, 'must be an RFC3339 UTC timestamp');
  }
  return parsed;
}

DateTime? _optionalDateTime(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _dateTime(value, field);
}

String _timestamp(DateTime value, String field) {
  final timestamp = value.toUtc().toIso8601String();
  if (!_rfc3339UtcPattern.hasMatch(timestamp)) {
    throw _invalid(field, 'must be an RFC3339 UTC timestamp');
  }
  return timestamp;
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) {
    throw _invalid(field, 'must be a JSON object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw _invalid(field, 'contains a non-string field name');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, Object?>? _optionalObject(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _object(value, field);
}

List<Object?> _list(Object? value, String field) {
  if (value is! List) {
    throw _invalid(field, 'must be a JSON array');
  }
  return value.cast<Object?>();
}

void _checkKeys(
  Map<String, Object?> map,
  Set<String> allowed,
  Set<String> required,
  String field,
) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw _invalid(field, 'contains an unknown field');
    }
  }
  for (final key in required) {
    if (!map.containsKey(key)) {
      throw _invalid('$field.$key', 'is required');
    }
  }
}

Object? _decodeJson(String source, String field) {
  try {
    return jsonDecode(source);
  } on FormatException {
    throw SyncProtocolException(
      SyncProtocolErrorKind.malformedJson,
      'contains malformed JSON',
      field: field,
    );
  }
}

SyncProtocolException _invalid(String field, String message) {
  return SyncProtocolException(
    SyncProtocolErrorKind.invalidValue,
    message,
    field: field,
  );
}
