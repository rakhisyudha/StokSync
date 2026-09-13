import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sync_engine/sync_engine.dart';

import 'stoksync_database.dart';

/// Applies push outcomes to the local replica.
///
/// The handler is intentionally kept in the Flutter application's Drift layer:
/// the pure-Dart sync engine only owns scheduling and calls this handler after a
/// transport response has been received. Every outcome is reconciled in one
/// SQLite transaction. An applied queue row is deleted only after its local
/// consequence has been persisted; a rejected row is retained as blocked work
/// and paired with an inspectable conflict record.
final class DriftSyncResponseReconciler {
  DriftSyncResponseReconciler(this._database, {DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  final StokSyncDatabase _database;
  final DateTime Function() _clock;

  /// Reconciles the response for the operations claimed by one sync cycle.
  ///
  /// A response must contain exactly one result for each claimed operation.
  /// Missing, duplicate, or unexpected results are treated as invalid
  /// responses and leave the whole transaction rolled back. The scheduler can
  /// then release the rows, and its next recovery pass can safely retry them.
  Future<void> reconcile(
    SyncResponse response,
    List<PendingSyncOperation> operations,
  ) async {
    final operationsById = <String, PendingSyncOperation>{};
    for (final operation in operations) {
      if (operationsById.containsKey(operation.opId)) {
        throw _invalidResponse(
          'operations.${operation.opId}',
          'contains a duplicate operation id',
        );
      }
      operationsById[operation.opId] = operation;
    }

    final resultsById = <String, SyncOperationResult>{};
    for (final result in response.results) {
      if (resultsById.containsKey(result.opId)) {
        throw _invalidResponse(
          'results.${result.opId}',
          'contains a duplicate operation id',
        );
      }
      resultsById[result.opId] = result;
      if (!operationsById.containsKey(result.opId)) {
        throw _invalidResponse(
          'results.${result.opId}',
          'does not correspond to a claimed operation',
        );
      }
    }
    for (final operation in operations) {
      if (!resultsById.containsKey(operation.opId)) {
        throw _invalidResponse(
          'results.${operation.opId}',
          'is missing the claimed operation result',
        );
      }
    }

    final changesBySequence = <int, SyncChangeEntry>{};
    for (final change in response.changes) {
      if (changesBySequence.containsKey(change.seq)) {
        throw _invalidResponse(
          'changes.${change.seq}',
          'contains a duplicate change sequence',
        );
      }
      changesBySequence[change.seq] = change;
    }

    await _database.transaction(() async {
      for (final operation in operations) {
        final stored = await _requireClaimedOperation(operation);
        final result = resultsById[operation.opId]!;

        switch (result.status) {
          case SyncOperationResultStatus.applied:
            final sequence = result.seq;
            if (sequence == null || sequence <= 0) {
              throw _invalidResponse(
                'results.${result.opId}.seq',
                'is required and must be positive for an applied result',
              );
            }
            final canonicalChange = changesBySequence[sequence];
            if (canonicalChange == null) {
              await _markLocalConsequenceSynchronized(stored);
            } else {
              await _applyCanonicalChange(
                stored,
                canonicalChange,
                response.serverTime,
              );
            }
            await _removeAppliedOperation(stored.opId);
          case SyncOperationResultStatus.rejected:
            await _retainRejectedOperation(stored, result);
        }
      }
    });
  }

  Future<PendingOperation> _requireClaimedOperation(
    PendingSyncOperation operation,
  ) async {
    final row = await (_database.select(
      _database.pendingOperations,
    )..where((entry) => entry.opId.equals(operation.opId))).getSingleOrNull();
    if (row == null) {
      throw _invalidResponse(
        'results.${operation.opId}',
        'has no local pending operation',
      );
    }
    if (row.status != PendingSyncOperationStatus.inflight.wireValue) {
      throw _invalidResponse(
        'results.${operation.opId}',
        'does not target an inflight local operation',
      );
    }
    if (row.localSeq != operation.localSeq ||
        row.entity != operation.entity ||
        row.entityId != operation.entityId ||
        row.operation != operation.operation ||
        row.payload != operation.payload ||
        row.baseVersion != operation.baseVersion) {
      throw _invalidResponse(
        'results.${operation.opId}',
        'does not match the claimed local operation',
      );
    }
    return row;
  }

  Future<void> _markLocalConsequenceSynchronized(
    PendingOperation operation,
  ) async {
    switch (operation.entity) {
      case 'product':
        final updated =
            await (_database.update(_database.products)
                  ..where((row) => row.id.equals(operation.entityId)))
                .write(const ProductsCompanion(syncStatus: Value('synced')));
        if (updated != 1) {
          throw _invalidResponse(
            'results.${operation.opId}',
            'has no local product consequence to reconcile',
          );
        }
      case 'stock_movement':
        final updated =
            await (_database.update(
              _database.stockMovements,
            )..where((row) => row.id.equals(operation.entityId))).write(
              const StockMovementsCompanion(syncStatus: Value('synced')),
            );
        if (updated != 1) {
          throw _invalidResponse(
            'results.${operation.opId}',
            'has no local movement consequence to reconcile',
          );
        }
      default:
        throw _invalidResponse(
          'operations.${operation.opId}.entity',
          'is not supported for reconciliation',
        );
    }
  }

  Future<void> _applyCanonicalChange(
    PendingOperation operation,
    SyncChangeEntry change,
    DateTime serverTime,
  ) async {
    final canonicalId = _requiredString(
      change.data,
      'id',
      'changes.${change.seq}.data.id',
    );
    if (canonicalId != operation.entityId) {
      throw _invalidResponse(
        'changes.${change.seq}.data.id',
        'does not match the pending operation entity',
      );
    }

    switch (operation.entity) {
      case 'product':
        final expectedChangeOperation = operation.operation == 'delete_product'
            ? 'delete'
            : 'upsert';
        if (change.entity != 'product' ||
            change.operation != expectedChangeOperation) {
          throw _invalidResponse(
            'changes.${change.seq}',
            'does not describe the canonical product consequence',
          );
        }
        await _applyCanonicalProduct(operation, change, serverTime);
      case 'stock_movement':
        if (operation.operation != 'add_movement' ||
            change.entity != 'stock_movement' ||
            change.operation != 'upsert') {
          throw _invalidResponse(
            'changes.${change.seq}',
            'does not describe the canonical movement consequence',
          );
        }
        await _applyCanonicalMovement(operation, change, serverTime);
      default:
        throw _invalidResponse(
          'operations.${operation.opId}.entity',
          'is not supported for reconciliation',
        );
    }
  }

  Future<void> _applyCanonicalProduct(
    PendingOperation operation,
    SyncChangeEntry change,
    DateTime serverTime,
  ) async {
    final existing = await (_database.select(
      _database.products,
    )..where((row) => row.id.equals(operation.entityId))).getSingleOrNull();
    if (existing == null) {
      throw _invalidResponse(
        'changes.${change.seq}',
        'has no local product row to reconcile',
      );
    }

    final data = change.data;
    final name = _requiredOrExistingString(
      data,
      'name',
      existing.name,
      'changes.${change.seq}.data.name',
    );
    final unit = _requiredOrExistingString(
      data,
      'unit',
      existing.unit,
      'changes.${change.seq}.data.unit',
    );
    if (name.trim().isEmpty || unit.trim().isEmpty) {
      throw _invalidResponse(
        'changes.${change.seq}.data',
        'canonical product name and unit must not be blank',
      );
    }

    final barcode = _optionalStringOrExisting(
      data,
      'barcode',
      existing.barcode,
      'changes.${change.seq}.data.barcode',
    );
    final sku = _optionalStringOrExisting(
      data,
      'sku',
      existing.sku,
      'changes.${change.seq}.data.sku',
    );
    final description = _optionalStringOrExisting(
      data,
      'description',
      existing.description,
      'changes.${change.seq}.data.description',
    );
    final category = _optionalStringOrExisting(
      data,
      'category',
      existing.category,
      'changes.${change.seq}.data.category',
    );
    final minStock = _optionalIntOrExisting(
      data,
      'min_stock',
      existing.minStock,
      'changes.${change.seq}.data.min_stock',
    );
    if (minStock != null && minStock < 0) {
      throw _invalidResponse(
        'changes.${change.seq}.data.min_stock',
        'must not be negative',
      );
    }

    final version = _intOrExisting(
      data,
      'version',
      existing.version,
      'changes.${change.seq}.data.version',
    );
    if (version < 0) {
      throw _invalidResponse(
        'changes.${change.seq}.data.version',
        'must not be negative',
      );
    }
    final updatedAt = _dateTimeOrExisting(
      data,
      'updated_at',
      existing.updatedAt,
      'changes.${change.seq}.data.updated_at',
    );
    final updatedBy = _requiredStringOrExisting(
      data,
      const ['updated_by_device_id', 'updated_by'],
      existing.updatedBy,
      'changes.${change.seq}.data.updated_by_device_id',
    );
    final createdAt = _dateTimeOrExisting(
      data,
      'created_at',
      existing.createdAt,
      'changes.${change.seq}.data.created_at',
    );
    var deletedAt = _nullableDateTimeOrExisting(
      data,
      'deleted_at',
      existing.deletedAt,
      'changes.${change.seq}.data.deleted_at',
    );
    if (change.operation == 'delete' && !data.containsKey('deleted_at')) {
      deletedAt = serverTime.toUtc();
    }

    await (_database.update(
      _database.products,
    )..where((row) => row.id.equals(operation.entityId))).write(
      ProductsCompanion(
        barcode: Value(barcode),
        sku: Value(sku),
        name: Value(name),
        description: Value(description),
        unit: Value(unit),
        category: Value(category),
        minStock: Value(minStock),
        version: Value(version),
        updatedAt: Value(updatedAt),
        updatedBy: Value(updatedBy),
        deletedAt: Value(deletedAt),
        createdAt: Value(createdAt),
        syncStatus: const Value('synced'),
      ),
    );
  }

  Future<void> _applyCanonicalMovement(
    PendingOperation operation,
    SyncChangeEntry change,
    DateTime serverTime,
  ) async {
    final existing = await (_database.select(
      _database.stockMovements,
    )..where((row) => row.id.equals(operation.entityId))).getSingleOrNull();
    if (existing == null) {
      await _insertCanonicalMovement(operation, change, serverTime);
      return;
    }

    final data = change.data;
    _assertOptionalStringEquals(
      data,
      'product_id',
      existing.productId,
      'changes.${change.seq}.data.product_id',
    );
    _assertOptionalIntEquals(
      data,
      'delta',
      existing.delta,
      'changes.${change.seq}.data.delta',
    );
    _assertOptionalStringEquals(
      data,
      'kind',
      existing.kind,
      'changes.${change.seq}.data.kind',
    );
    _assertOptionalNullableStringEquals(
      data,
      'note',
      existing.note,
      'changes.${change.seq}.data.note',
    );
    _assertOptionalDateTimeEquals(
      data,
      'occurred_at',
      existing.occurredAt,
      'changes.${change.seq}.data.occurred_at',
    );
    _assertOptionalDateTimeEquals(
      data,
      'raw_occurred_at',
      existing.rawOccurredAt,
      'changes.${change.seq}.data.raw_occurred_at',
    );
    _assertOptionalIntEquals(
      data,
      'clock_offset_ms',
      existing.clockOffsetMs,
      'changes.${change.seq}.data.clock_offset_ms',
    );
    _assertOptionalNullableIntEquals(
      data,
      'counted_qty',
      existing.countedQty,
      'changes.${change.seq}.data.counted_qty',
    );
    _assertOptionalNullableStringEquals(
      data,
      'reverses_id',
      existing.reversesId,
      'changes.${change.seq}.data.reverses_id',
    );
    _assertOptionalStringEquals(
      data,
      'device_id',
      existing.deviceId,
      'changes.${change.seq}.data.device_id',
    );

    final hasServerCreatedAt = data.containsKey('server_created_at');
    final serverCreatedAt = hasServerCreatedAt
        ? _nullableDateTime(
            data['server_created_at'],
            'changes.${change.seq}.data.server_created_at',
          )
        : change.createdAt?.toUtc();
    final serverCreatedAtValue = hasServerCreatedAt || change.createdAt != null
        ? Value<DateTime?>(serverCreatedAt)
        : const Value<DateTime?>.absent();
    await (_database.update(
      _database.stockMovements,
    )..where((row) => row.id.equals(operation.entityId))).write(
      StockMovementsCompanion(
        serverCreatedAt: serverCreatedAtValue,
        syncStatus: const Value('synced'),
      ),
    );
  }

  Future<void> _insertCanonicalMovement(
    PendingOperation operation,
    SyncChangeEntry change,
    DateTime serverTime,
  ) async {
    final data = change.data;
    final productId = _requiredString(
      data,
      'product_id',
      'changes.${change.seq}.data.product_id',
    );
    final delta = _requiredInt(
      data,
      'delta',
      'changes.${change.seq}.data.delta',
    );
    final kind = _requiredString(
      data,
      'kind',
      'changes.${change.seq}.data.kind',
    );
    final occurredAt = _requiredDateTime(
      data,
      'occurred_at',
      'changes.${change.seq}.data.occurred_at',
    );
    final rawOccurredAt = _requiredDateTime(
      data,
      'raw_occurred_at',
      'changes.${change.seq}.data.raw_occurred_at',
    );
    final deviceId = _requiredString(
      data,
      'device_id',
      'changes.${change.seq}.data.device_id',
    );
    final note = _nullableString(
      data['note'],
      'changes.${change.seq}.data.note',
    );
    final clockOffsetMs = data.containsKey('clock_offset_ms')
        ? _requiredInt(
            data,
            'clock_offset_ms',
            'changes.${change.seq}.data.clock_offset_ms',
          )
        : 0;
    final countedQty = _nullableInt(
      data['counted_qty'],
      'changes.${change.seq}.data.counted_qty',
    );
    final reversesId = _nullableString(
      data['reverses_id'],
      'changes.${change.seq}.data.reverses_id',
    );
    final serverCreatedAt = data.containsKey('server_created_at')
        ? _nullableDateTime(
            data['server_created_at'],
            'changes.${change.seq}.data.server_created_at',
          )
        : change.createdAt?.toUtc() ?? serverTime.toUtc();

    if (delta == 0) {
      throw _invalidResponse(
        'changes.${change.seq}.data.delta',
        'must not be zero',
      );
    }
    if (kind == 'stocktake' && countedQty == null) {
      throw _invalidResponse(
        'changes.${change.seq}.data.counted_qty',
        'is required for stocktake movements',
      );
    }
    if (kind != 'stocktake' && countedQty != null) {
      throw _invalidResponse(
        'changes.${change.seq}.data.counted_qty',
        'is only valid for stocktake movements',
      );
    }

    final product = await (_database.select(
      _database.products,
    )..where((row) => row.id.equals(productId))).getSingleOrNull();
    if (product == null) {
      throw _invalidResponse(
        'changes.${change.seq}.data.product_id',
        'does not reference a local product',
      );
    }

    await _database
        .into(_database.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: operation.entityId,
            productId: productId,
            delta: delta,
            kind: kind,
            note: Value(note),
            occurredAt: occurredAt,
            rawOccurredAt: rawOccurredAt,
            clockOffsetMs: Value(clockOffsetMs),
            countedQty: Value(countedQty),
            reversesId: Value(reversesId),
            deviceId: deviceId,
            serverCreatedAt: Value(serverCreatedAt),
            syncStatus: const Value('synced'),
          ),
        );

    final balance = await (_database.select(
      _database.productBalances,
    )..where((row) => row.productId.equals(productId))).getSingleOrNull();
    final updatedAt = serverTime.toUtc();
    if (balance == null) {
      await _database
          .into(_database.productBalances)
          .insert(
            ProductBalancesCompanion.insert(
              productId: productId,
              qty: Value(delta),
              lastMovementAt: Value(occurredAt),
              updatedAt: Value(updatedAt),
            ),
          );
    } else {
      final lastMovementAt =
          balance.lastMovementAt == null ||
              occurredAt.isAfter(balance.lastMovementAt!)
          ? occurredAt
          : balance.lastMovementAt;
      await (_database.update(
        _database.productBalances,
      )..where((row) => row.productId.equals(productId))).write(
        ProductBalancesCompanion(
          qty: Value(balance.qty + delta),
          lastMovementAt: Value(lastMovementAt),
          updatedAt: Value(updatedAt),
        ),
      );
    }
  }

  Future<void> _retainRejectedOperation(
    PendingOperation operation,
    SyncOperationResult result,
  ) async {
    final reason = result.reason;
    if (reason == null || reason.trim().isEmpty) {
      throw _invalidResponse(
        'results.${result.opId}.reason',
        'is required for a rejected result',
      );
    }

    final updated =
        await (_database.update(_database.pendingOperations)..where(
              (row) =>
                  row.opId.equals(operation.opId) &
                  row.status.equals(
                    PendingSyncOperationStatus.inflight.wireValue,
                  ),
            ))
            .write(
              PendingOperationsCompanion(
                lastError: Value(reason),
                status: Value(PendingSyncOperationStatus.blocked.wireValue),
              ),
            );
    if (updated != 1) {
      throw _invalidResponse(
        'results.${result.opId}',
        'could not retain the rejected pending operation',
      );
    }

    final serverPayload = result.serverState == null
        ? null
        : jsonEncode(result.serverState);
    final basePayload = operation.baseVersion == null
        ? null
        : jsonEncode(<String, Object?>{'base_version': operation.baseVersion});
    final createdAt = _clock().toUtc();
    final existing = await (_database.select(
      _database.conflicts,
    )..where((row) => row.opId.equals(operation.opId))).getSingleOrNull();
    if (existing == null) {
      await _database
          .into(_database.conflicts)
          .insert(
            ConflictsCompanion.insert(
              opId: operation.opId,
              entity: operation.entity,
              entityId: operation.entityId,
              localPayload: operation.payload,
              basePayload: Value(basePayload),
              serverPayload: Value(serverPayload),
              reason: reason,
              createdAt: Value(createdAt),
            ),
          );
    } else {
      await (_database.update(
        _database.conflicts,
      )..where((row) => row.opId.equals(operation.opId))).write(
        ConflictsCompanion(
          entity: Value(operation.entity),
          entityId: Value(operation.entityId),
          localPayload: Value(operation.payload),
          basePayload: Value(basePayload),
          serverPayload: Value(serverPayload),
          reason: Value(reason),
          createdAt: Value(createdAt),
        ),
      );
    }

    await _markLocalStatusIfPresent(operation, 'conflict');
  }

  Future<void> _markLocalStatusIfPresent(
    PendingOperation operation,
    String status,
  ) async {
    switch (operation.entity) {
      case 'product':
        await (_database.update(_database.products)
              ..where((row) => row.id.equals(operation.entityId)))
            .write(ProductsCompanion(syncStatus: Value(status)));
      case 'stock_movement':
        await (_database.update(_database.stockMovements)
              ..where((row) => row.id.equals(operation.entityId)))
            .write(StockMovementsCompanion(syncStatus: Value(status)));
    }
  }

  Future<void> _removeAppliedOperation(String operationId) async {
    final deleted =
        await (_database.delete(_database.pendingOperations)..where(
              (row) =>
                  row.opId.equals(operationId) &
                  row.status.equals(
                    PendingSyncOperationStatus.inflight.wireValue,
                  ),
            ))
            .go();
    if (deleted != 1) {
      throw _invalidResponse(
        'results.$operationId',
        'could not remove the reconciled pending operation',
      );
    }
  }
}

String _requiredString(Map<String, Object?> data, String key, String field) {
  if (!data.containsKey(key)) {
    throw _invalidResponse(field, 'is required');
  }
  return _string(data[key], field);
}

String _requiredOrExistingString(
  Map<String, Object?> data,
  String key,
  String existing,
  String field,
) {
  if (!data.containsKey(key)) {
    return existing;
  }
  return _string(data[key], field);
}

String _requiredStringOrExisting(
  Map<String, Object?> data,
  List<String> keys,
  String existing,
  String field,
) {
  for (final key in keys) {
    if (data.containsKey(key)) {
      return _string(data[key], field);
    }
  }
  return existing;
}

String _string(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw _invalidResponse(field, 'must be a non-empty string');
  }
  return value;
}

String? _optionalStringOrExisting(
  Map<String, Object?> data,
  String key,
  String? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    return existing;
  }
  return _nullableString(data[key], field);
}

String? _nullableString(Object? value, String field) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw _invalidResponse(field, 'must be a string or null');
  }
  return value;
}

int _requiredInt(Map<String, Object?> data, String key, String field) {
  if (!data.containsKey(key)) {
    throw _invalidResponse(field, 'is required');
  }
  return _int(data[key], field);
}

int _int(Object? value, String field) {
  if (value is! int) {
    throw _invalidResponse(field, 'must be an integer');
  }
  return value;
}

int _intOrExisting(
  Map<String, Object?> data,
  String key,
  int existing,
  String field,
) {
  return data.containsKey(key) ? _int(data[key], field) : existing;
}

int? _optionalIntOrExisting(
  Map<String, Object?> data,
  String key,
  int? existing,
  String field,
) {
  return data.containsKey(key) ? _nullableInt(data[key], field) : existing;
}

int? _nullableInt(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _int(value, field);
}

DateTime _requiredDateTime(
  Map<String, Object?> data,
  String key,
  String field,
) {
  if (!data.containsKey(key)) {
    throw _invalidResponse(field, 'is required');
  }
  return _dateTime(data[key], field);
}

DateTime _dateTimeOrExisting(
  Map<String, Object?> data,
  String key,
  DateTime existing,
  String field,
) {
  return data.containsKey(key) ? _dateTime(data[key], field) : existing.toUtc();
}

DateTime? _nullableDateTimeOrExisting(
  Map<String, Object?> data,
  String key,
  DateTime? existing,
  String field,
) {
  return data.containsKey(key)
      ? _nullableDateTime(data[key], field)
      : existing?.toUtc();
}

DateTime _dateTime(Object? value, String field) {
  if (value is! String) {
    throw _invalidResponse(field, 'must be an RFC3339 timestamp');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw _invalidResponse(field, 'must be an RFC3339 timestamp');
  }
  return parsed.toUtc();
}

DateTime? _nullableDateTime(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _dateTime(value, field);
}

void _assertOptionalStringEquals(
  Map<String, Object?> data,
  String key,
  String expected,
  String field,
) {
  if (data.containsKey(key) && _string(data[key], field) != expected) {
    throw _invalidResponse(field, 'does not match the local ledger row');
  }
}

void _assertOptionalNullableStringEquals(
  Map<String, Object?> data,
  String key,
  String? expected,
  String field,
) {
  if (!data.containsKey(key)) {
    return;
  }
  final actual = _nullableString(data[key], field);
  if (actual != expected) {
    throw _invalidResponse(field, 'does not match the local ledger row');
  }
}

void _assertOptionalIntEquals(
  Map<String, Object?> data,
  String key,
  int expected,
  String field,
) {
  if (data.containsKey(key) && _int(data[key], field) != expected) {
    throw _invalidResponse(field, 'does not match the local ledger row');
  }
}

void _assertOptionalNullableIntEquals(
  Map<String, Object?> data,
  String key,
  int? expected,
  String field,
) {
  if (!data.containsKey(key)) {
    return;
  }
  final actual = _nullableInt(data[key], field);
  if (actual != expected) {
    throw _invalidResponse(field, 'does not match the local ledger row');
  }
}

void _assertOptionalDateTimeEquals(
  Map<String, Object?> data,
  String key,
  DateTime expected,
  String field,
) {
  if (data.containsKey(key) &&
      !_dateTime(data[key], field).isAtSameMomentAs(expected)) {
    throw _invalidResponse(field, 'does not match the local ledger row');
  }
}

SyncProtocolException _invalidResponse(String field, String message) {
  return SyncProtocolException(
    SyncProtocolErrorKind.invalidResponse,
    message,
    field: field,
  );
}

DateTime _utcNow() => DateTime.now().toUtc();
