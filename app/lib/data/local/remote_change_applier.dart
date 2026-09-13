import 'package:drift/drift.dart';
import 'package:sync_engine/sync_engine.dart';

import 'stoksync_database.dart';

/// Applies canonical change-feed entries to the local Drift replica.
///
/// This class deliberately does not advance [SyncState.cursor] or coordinate a
/// sync cycle. Callers that own a page transaction can use
/// [applyChangesInTransaction] and advance the cursor after it returns. The
/// convenience methods open a transaction for callers applying an individual
/// change or a complete page in isolation.
///
/// Remote rows are idempotent: a repeated product change is a no-op once its
/// canonical version is present, and a repeated movement never changes the
/// balance a second time. Local pending/conflict rows are never removed or
/// rewritten. Their domain row may receive canonical fields, but its existing
/// non-synced status is retained so later reconciliation can still inspect the
/// local intent.
final class DriftRemoteChangeApplier {
  DriftRemoteChangeApplier(this._database, {DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  final StokSyncDatabase _database;
  final DateTime Function() _clock;

  /// Applies one remote change in a transaction owned by this method.
  Future<void> applyChange(
    SyncChangeEntry change, {
    DateTime? serverTime,
  }) async {
    await applyChanges([change], serverTime: serverTime);
  }

  /// Applies a page of changes in one transaction without advancing a cursor.
  Future<void> applyChanges(
    Iterable<SyncChangeEntry> changes, {
    DateTime? serverTime,
  }) async {
    final entries = changes.toList(growable: false);
    await _database.transaction(
      () => applyChangesInTransaction(entries, serverTime: serverTime),
    );
  }

  /// Applies one change inside a transaction owned by the caller.
  Future<void> applyChangeInTransaction(
    SyncChangeEntry change, {
    DateTime? serverTime,
  }) {
    return applyChangesInTransaction([change], serverTime: serverTime);
  }

  /// Applies changes inside a transaction owned by the caller.
  ///
  /// This method does not read or write [SyncState], making it safe for the
  /// later page-level cursor implementation to call it before persisting the
  /// page cursor in the same SQLite transaction.
  Future<void> applyChangesInTransaction(
    Iterable<SyncChangeEntry> changes, {
    DateTime? serverTime,
  }) async {
    final entries = changes.toList(growable: false);
    _validateChangeEnvelopes(entries);
    final effectiveServerTime = (serverTime ?? _clock()).toUtc();

    final products =
        entries
            .where((change) => change.entity == _productEntity)
            .toList(growable: false)
          ..sort(_compareSequence);
    final movements =
        entries
            .where((change) => change.entity == _movementEntity)
            .toList(growable: false)
          ..sort(_compareSequence);

    // Products are applied first even if a malformed/out-of-order page puts a
    // movement before its product. This satisfies the product foreign key
    // without changing the canonical order of updates for each entity.
    for (final change in products) {
      await _applyProductChange(change, effectiveServerTime);
    }

    // A reversal has a self-referential foreign key to its original movement.
    // Apply ready movements repeatedly so a valid page is accepted even when
    // a reversal precedes its original in the supplied list. Existing rows
    // satisfy dependencies immediately, which also makes replay idempotent.
    final remaining = movements.toList(growable: true);
    while (remaining.isNotEmpty) {
      var appliedAny = false;
      for (var index = 0; index < remaining.length;) {
        final change = remaining[index];
        final reversesId = _movementReversalId(change);
        if (reversesId != null && !await _movementExists(reversesId)) {
          index++;
          continue;
        }
        await _applyMovementChange(change, effectiveServerTime);
        remaining.removeAt(index);
        appliedAny = true;
      }
      if (!appliedAny) {
        final unresolved = remaining.first;
        final reversesId = _movementReversalId(unresolved);
        throw _invalid(
          _field(unresolved, 'data.reverses_id'),
          reversesId == null
              ? 'could not apply the movement because its dependencies are invalid'
              : 'references a movement that is not present locally or in this page',
        );
      }
    }
  }

  Future<void> _applyProductChange(
    SyncChangeEntry change,
    DateTime serverTime,
  ) async {
    final fieldPrefix = _field(change, 'data');
    final data = change.data;
    final id = _requiredUuid(data, 'id', '$fieldPrefix.id');
    final existing = await (_database.select(
      _database.products,
    )..where((row) => row.id.equals(id))).getSingleOrNull();

    final name = _requiredProductText(
      data,
      'name',
      existing?.name,
      '$fieldPrefix.name',
      'name',
    );
    final unit = _requiredProductText(
      data,
      'unit',
      existing?.unit,
      '$fieldPrefix.unit',
      'unit',
    );
    final barcode = _optionalStringOrExisting(
      data,
      'barcode',
      existing?.barcode,
      '$fieldPrefix.barcode',
    );
    final sku = _optionalStringOrExisting(
      data,
      'sku',
      existing?.sku,
      '$fieldPrefix.sku',
    );
    final description = _optionalStringOrExisting(
      data,
      'description',
      existing?.description,
      '$fieldPrefix.description',
    );
    final category = _optionalStringOrExisting(
      data,
      'category',
      existing?.category,
      '$fieldPrefix.category',
    );
    final minStock = _optionalIntOrExisting(
      data,
      'min_stock',
      existing?.minStock,
      '$fieldPrefix.min_stock',
    );
    if (minStock != null && minStock < 0) {
      throw _invalid('$fieldPrefix.min_stock', 'must not be negative');
    }

    final hasVersion = data.containsKey('version');
    final version = hasVersion
        ? _nonNegativeInt(data['version'], '$fieldPrefix.version')
        : existing?.version;
    if (version == null) {
      throw _invalid('$fieldPrefix.version', 'is required for a new product');
    }

    final updatedAt = _dateTimeOrExisting(
      data,
      'updated_at',
      existing?.updatedAt,
      '$fieldPrefix.updated_at',
    );
    final updatedBy = _updatedByOrExisting(
      data,
      existing?.updatedBy,
      '$fieldPrefix.updated_by_device_id',
    );
    final createdAt = _dateTimeOrExisting(
      data,
      'created_at',
      existing?.createdAt,
      '$fieldPrefix.created_at',
    );
    var deletedAt = _nullableDateTimeOrExisting(
      data,
      'deleted_at',
      existing?.deletedAt,
      '$fieldPrefix.deleted_at',
    );
    if (change.operation == _deleteOperation && deletedAt == null) {
      deletedAt = change.createdAt?.toUtc() ?? serverTime;
    }

    if (existing != null && existing.deletedAt != null && deletedAt == null) {
      // A tombstoned product never comes back through a stale or malformed
      // upsert. A future explicit resurrection policy would need a separate
      // operation and conflict rules; v1 has delete-wins semantics.
      return;
    }

    if (existing != null && hasVersion) {
      if (version < existing.version) {
        // An old feed page can be replayed after a newer page. Never let it
        // resurrect or overwrite a canonical row that is already newer.
        return;
      }
      if (version == existing.version) {
        final incomingIsDeleted = deletedAt != null;
        if (existing.deletedAt != null && !incomingIsDeleted) {
          // Deletion wins ties and prevents a stale upsert from resurrecting a
          // tombstone.
          return;
        }
        if (_sameProduct(
          existing,
          barcode: barcode,
          sku: sku,
          name: name,
          description: description,
          unit: unit,
          category: category,
          minStock: minStock,
          version: version,
          updatedAt: updatedAt,
          updatedBy: updatedBy,
          deletedAt: deletedAt,
          createdAt: createdAt,
        )) {
          return;
        }
        if (incomingIsDeleted && existing.deletedAt == null) {
          // A canonical tombstone wins over a same-version active row, even
          // when the active row still carries local pending intent.
        } else if (_preservesLocalIntent(existing.syncStatus)) {
          // The local optimistic row is the only local copy of the user's
          // intent. Keep it when a same-version concurrent canonical update
          // arrives; the pending operation/conflict record remains untouched.
          return;
        } else {
          throw _invalid(
            fieldPrefix,
            'contains conflicting product data for an existing version',
          );
        }
      }
    }

    await _ensureBarcodeAvailable(
      id: id,
      barcode: barcode,
      deletedAt: deletedAt,
      field: '$fieldPrefix.barcode',
    );

    final status = existing == null
        ? _syncedStatus
        : _preservedStatus(existing.syncStatus);
    if (existing == null) {
      await _database
          .into(_database.products)
          .insert(
            ProductsCompanion.insert(
              id: id,
              barcode: Value(barcode),
              sku: Value(sku),
              name: name,
              description: Value(description),
              unit: Value(unit),
              category: Value(category),
              minStock: Value(minStock),
              version: Value(version),
              updatedAt: Value(updatedAt),
              updatedBy: updatedBy,
              deletedAt: Value(deletedAt),
              createdAt: Value(createdAt),
              syncStatus: Value(status),
            ),
          );
      await _ensureBalance(id, serverTime);
      return;
    }

    await (_database.update(
      _database.products,
    )..where((row) => row.id.equals(id))).write(
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
        syncStatus: Value(status),
      ),
    );
    await _ensureBalance(id, serverTime);
  }

  Future<void> _applyMovementChange(
    SyncChangeEntry change,
    DateTime serverTime,
  ) async {
    final fieldPrefix = _field(change, 'data');
    final data = change.data;
    final id = _requiredUuid(data, 'id', '$fieldPrefix.id');
    final existing = await (_database.select(
      _database.stockMovements,
    )..where((row) => row.id.equals(id))).getSingleOrNull();

    final productId = _requiredUuidOrExisting(
      data,
      'product_id',
      existing?.productId,
      '$fieldPrefix.product_id',
    );
    final product = await (_database.select(
      _database.products,
    )..where((row) => row.id.equals(productId))).getSingleOrNull();
    if (product == null) {
      throw _invalid(
        '$fieldPrefix.product_id',
        'does not reference a local product',
      );
    }

    final delta = _intOrExisting(
      data,
      'delta',
      existing?.delta,
      '$fieldPrefix.delta',
    );
    if (delta == null) {
      throw _invalid('$fieldPrefix.delta', 'is required for a new movement');
    }
    if (delta == 0) {
      throw _invalid('$fieldPrefix.delta', 'must not be zero');
    }
    _validateInt32(delta, '$fieldPrefix.delta');

    final kind = _requiredStringOrExisting(
      data,
      'kind',
      existing?.kind,
      '$fieldPrefix.kind',
    );
    if (!_movementKinds.contains(kind)) {
      throw _invalid('$fieldPrefix.kind', 'is not supported');
    }

    final occurredAt = _dateTimeOrExisting(
      data,
      'occurred_at',
      existing?.occurredAt,
      '$fieldPrefix.occurred_at',
    );
    final rawOccurredAt = _dateTimeOrExisting(
      data,
      'raw_occurred_at',
      existing?.rawOccurredAt,
      '$fieldPrefix.raw_occurred_at',
    );
    final clockOffsetMs =
        _intOrExisting(
          data,
          'clock_offset_ms',
          existing?.clockOffsetMs,
          '$fieldPrefix.clock_offset_ms',
        ) ??
        0;
    final countedQty = _nullableIntOrExisting(
      data,
      'counted_qty',
      existing?.countedQty,
      '$fieldPrefix.counted_qty',
    );
    if (countedQty != null) {
      _validateInt32(countedQty, '$fieldPrefix.counted_qty');
      if (countedQty < 0) {
        throw _invalid('$fieldPrefix.counted_qty', 'must not be negative');
      }
    }
    if (kind == 'stocktake' && countedQty == null) {
      throw _invalid(
        '$fieldPrefix.counted_qty',
        'is required for stocktake movements',
      );
    }
    if (kind != 'stocktake' && countedQty != null) {
      throw _invalid(
        '$fieldPrefix.counted_qty',
        'is only valid for stocktake movements',
      );
    }

    final reversesId = _nullableUuidOrExisting(
      data,
      'reverses_id',
      existing?.reversesId,
      '$fieldPrefix.reverses_id',
    );
    if (reversesId != null && kind != 'adjust') {
      throw _invalid(
        '$fieldPrefix.reverses_id',
        'is only valid for adjust movements',
      );
    }
    if (reversesId == id) {
      throw _invalid('$fieldPrefix.reverses_id', 'must not reference itself');
    }
    if (reversesId != null) {
      final original = await (_database.select(
        _database.stockMovements,
      )..where((row) => row.id.equals(reversesId))).getSingleOrNull();
      if (original == null) {
        throw _invalid(
          '$fieldPrefix.reverses_id',
          'does not reference an existing movement',
        );
      }
      if (original.productId != productId) {
        throw _invalid(
          '$fieldPrefix.reverses_id',
          'must reference a movement for the same product',
        );
      }
    }

    final deviceId = _requiredUuidOrExisting(
      data,
      'device_id',
      existing?.deviceId,
      '$fieldPrefix.device_id',
    );
    final explicitServerCreatedAt = data.containsKey('server_created_at');
    final serverCreatedAt = explicitServerCreatedAt
        ? _nullableDateTime(
            data['server_created_at'],
            '$fieldPrefix.server_created_at',
          )
        : null;
    final fallbackServerCreatedAt =
        change.createdAt?.toUtc() ?? serverTime.toUtc();

    if (existing != null) {
      _assertSameMovement(
        existing,
        productId: productId,
        delta: delta,
        kind: kind,
        note: _optionalStringOrExisting(
          data,
          'note',
          existing.note,
          '$fieldPrefix.note',
        ),
        occurredAt: occurredAt,
        rawOccurredAt: rawOccurredAt,
        clockOffsetMs: clockOffsetMs,
        countedQty: countedQty,
        reversesId: reversesId,
        deviceId: deviceId,
        fieldPrefix: fieldPrefix,
      );

      final metadata = explicitServerCreatedAt
          ? serverCreatedAt
          : existing.serverCreatedAt == null
          ? fallbackServerCreatedAt
          : null;
      if (existing.serverCreatedAt != null &&
          metadata != null &&
          !existing.serverCreatedAt!.toUtc().isAtSameMomentAs(metadata)) {
        throw _invalid(
          '$fieldPrefix.server_created_at',
          'does not match the existing canonical movement',
        );
      }
      final status = _preservedStatus(existing.syncStatus);
      if (metadata != null || status != existing.syncStatus) {
        await (_database.update(
          _database.stockMovements,
        )..where((row) => row.id.equals(id))).write(
          StockMovementsCompanion(
            serverCreatedAt: metadata == null
                ? const Value.absent()
                : Value(metadata),
            syncStatus: Value(status),
          ),
        );
      }
      return;
    }

    final resolvedServerCreatedAt = serverCreatedAt ?? fallbackServerCreatedAt;
    await _database
        .into(_database.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: id,
            productId: productId,
            delta: delta,
            kind: kind,
            note: Value(
              _optionalStringOrExisting(
                data,
                'note',
                null,
                '$fieldPrefix.note',
              ),
            ),
            occurredAt: occurredAt,
            rawOccurredAt: rawOccurredAt,
            clockOffsetMs: Value(clockOffsetMs),
            countedQty: Value(countedQty),
            reversesId: Value(reversesId),
            deviceId: deviceId,
            serverCreatedAt: Value(resolvedServerCreatedAt),
            syncStatus: const Value(_syncedStatus),
          ),
        );
    await _applyBalanceDelta(
      productId: productId,
      delta: delta,
      occurredAt: occurredAt,
      updatedAt: serverTime,
    );
  }

  Future<bool> _movementExists(String movementId) async {
    final row = await (_database.select(
      _database.stockMovements,
    )..where((movement) => movement.id.equals(movementId))).getSingleOrNull();
    return row != null;
  }

  String? _movementReversalId(SyncChangeEntry change) {
    if (change.entity != _movementEntity ||
        change.operation != _upsertOperation ||
        !change.data.containsKey('reverses_id')) {
      return null;
    }
    final value = change.data['reverses_id'];
    if (value == null) {
      return null;
    }
    if (value is! String || value.isEmpty) {
      throw _invalid(
        _field(change, 'data.reverses_id'),
        'must be a UUID string or null',
      );
    }
    return value;
  }

  Future<void> _applyBalanceDelta({
    required String productId,
    required int delta,
    required DateTime occurredAt,
    required DateTime updatedAt,
  }) async {
    final existing = await (_database.select(
      _database.productBalances,
    )..where((row) => row.productId.equals(productId))).getSingleOrNull();
    if (existing == null) {
      await _database
          .into(_database.productBalances)
          .insert(
            ProductBalancesCompanion.insert(
              productId: productId,
              qty: Value(delta),
              lastMovementAt: Value(occurredAt),
              updatedAt: Value(updatedAt.toUtc()),
            ),
          );
      return;
    }

    final lastMovementAt =
        existing.lastMovementAt == null ||
            occurredAt.isAfter(existing.lastMovementAt!)
        ? occurredAt
        : existing.lastMovementAt;
    await (_database.update(
      _database.productBalances,
    )..where((row) => row.productId.equals(productId))).write(
      ProductBalancesCompanion(
        qty: Value(existing.qty + delta),
        lastMovementAt: Value(lastMovementAt),
        updatedAt: Value(updatedAt.toUtc()),
      ),
    );
  }

  Future<void> _ensureBalance(String productId, DateTime updatedAt) async {
    final balance = await (_database.select(
      _database.productBalances,
    )..where((row) => row.productId.equals(productId))).getSingleOrNull();
    if (balance != null) {
      return;
    }

    // A healthy local mutation always creates a balance row, but deriving it
    // here keeps a remote product upsert safe for an older/partially repaired
    // replica that already contains ledger rows without their projection.
    final movements = await (_database.select(
      _database.stockMovements,
    )..where((row) => row.productId.equals(productId))).get();
    var quantity = 0;
    DateTime? lastMovementAt;
    for (final movement in movements) {
      quantity += movement.delta;
      if (lastMovementAt == null ||
          movement.occurredAt.isAfter(lastMovementAt)) {
        lastMovementAt = movement.occurredAt;
      }
    }
    await _database
        .into(_database.productBalances)
        .insert(
          ProductBalancesCompanion.insert(
            productId: productId,
            qty: Value(quantity),
            lastMovementAt: Value(lastMovementAt),
            updatedAt: Value(updatedAt.toUtc()),
          ),
        );
  }

  Future<void> _ensureBarcodeAvailable({
    required String id,
    required String? barcode,
    required DateTime? deletedAt,
    required String field,
  }) async {
    if (barcode == null || deletedAt != null) {
      return;
    }
    final activeRows =
        await (_database.select(_database.products)..where(
              (row) => row.barcode.equals(barcode) & row.deletedAt.isNull(),
            ))
            .get();
    if (activeRows.any((row) => row.id != id)) {
      throw _invalid(field, 'conflicts with another active product');
    }
  }

  void _assertSameMovement(
    StockMovement existing, {
    required String productId,
    required int delta,
    required String kind,
    required String? note,
    required DateTime occurredAt,
    required DateTime rawOccurredAt,
    required int clockOffsetMs,
    required int? countedQty,
    required String? reversesId,
    required String deviceId,
    required String fieldPrefix,
  }) {
    if (existing.productId != productId ||
        existing.delta != delta ||
        existing.kind != kind ||
        existing.note != note ||
        !existing.occurredAt.toUtc().isAtSameMomentAs(occurredAt) ||
        !existing.rawOccurredAt.toUtc().isAtSameMomentAs(rawOccurredAt) ||
        existing.clockOffsetMs != clockOffsetMs ||
        existing.countedQty != countedQty ||
        existing.reversesId != reversesId ||
        existing.deviceId != deviceId) {
      throw _invalid(
        fieldPrefix,
        'does not match the existing immutable ledger row',
      );
    }
  }

  bool _sameProduct(
    Product existing, {
    required String? barcode,
    required String? sku,
    required String name,
    required String? description,
    required String unit,
    required String? category,
    required int? minStock,
    required int version,
    required DateTime updatedAt,
    required String updatedBy,
    required DateTime? deletedAt,
    required DateTime createdAt,
  }) {
    return existing.barcode == barcode &&
        existing.sku == sku &&
        existing.name == name &&
        existing.description == description &&
        existing.unit == unit &&
        existing.category == category &&
        existing.minStock == minStock &&
        existing.version == version &&
        existing.updatedAt.toUtc().isAtSameMomentAs(updatedAt) &&
        existing.updatedBy == updatedBy &&
        _sameInstant(existing.deletedAt, deletedAt) &&
        existing.createdAt.toUtc().isAtSameMomentAs(createdAt);
  }

  void _validateChangeEnvelopes(List<SyncChangeEntry> changes) {
    final sequences = <int>{};
    for (final change in changes) {
      if (change.seq <= 0) {
        throw _invalid(_field(change, 'seq'), 'must be positive');
      }
      if (!sequences.add(change.seq)) {
        throw _invalid(_field(change, 'seq'), 'is duplicated in the page');
      }
      if (change.data.isEmpty) {
        throw _invalid(_field(change, 'data'), 'must be a non-empty object');
      }
      switch (change.entity) {
        case _productEntity:
          if (change.operation != _upsertOperation &&
              change.operation != _deleteOperation) {
            throw _invalid(
              _field(change, 'op'),
              'is not supported for product changes',
            );
          }
        case _movementEntity:
          if (change.operation != _upsertOperation) {
            throw _invalid(
              _field(change, 'op'),
              'is not supported for movement changes',
            );
          }
        default:
          throw _invalid(
            _field(change, 'entity'),
            'is not supported by the remote change applier',
          );
      }
    }
  }
}

const String _productEntity = 'product';
const String _movementEntity = 'stock_movement';
const String _upsertOperation = 'upsert';
const String _deleteOperation = 'delete';
const String _syncedStatus = 'synced';
const Set<String> _movementKinds = {'receive', 'issue', 'adjust', 'stocktake'};
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final RegExp _rfc3339UtcPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$',
);

int _compareSequence(SyncChangeEntry left, SyncChangeEntry right) =>
    left.seq.compareTo(right.seq);

String _field(SyncChangeEntry change, String field) =>
    'changes.${change.seq}.$field';

String _requiredUuid(Map<String, Object?> data, String key, String field) {
  if (!data.containsKey(key)) {
    throw _invalid(field, 'is required');
  }
  final value = data[key];
  if (value is! String || !_isUuid(value)) {
    throw _invalid(field, 'must be a non-zero UUID string');
  }
  return value;
}

String? _nullableUuidOrExisting(
  Map<String, Object?> data,
  String key,
  String? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    return existing;
  }
  final value = data[key];
  if (value == null) {
    return null;
  }
  if (value is! String || !_isUuid(value)) {
    throw _invalid(field, 'must be a UUID string or null');
  }
  return value;
}

String _requiredUuidOrExisting(
  Map<String, Object?> data,
  String key,
  String? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    if (existing == null) {
      throw _invalid(field, 'is required');
    }
    return existing;
  }
  return _requiredUuid(data, key, field);
}

String _requiredProductText(
  Map<String, Object?> data,
  String key,
  String? existing,
  String field,
  String label,
) {
  if (!data.containsKey(key)) {
    if (existing == null) {
      throw _invalid(field, 'is required for a new product');
    }
    return existing;
  }
  final value = data[key];
  if (value is! String || value.trim().isEmpty) {
    throw _invalid(field, '$label must not be blank');
  }
  return value;
}

String _requiredStringOrExisting(
  Map<String, Object?> data,
  String key,
  String? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    if (existing == null) {
      throw _invalid(field, 'is required');
    }
    return existing;
  }
  final value = data[key];
  if (value is! String || value.isEmpty) {
    throw _invalid(field, 'must be a non-empty string');
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
  final value = data[key];
  if (value != null && value is! String) {
    throw _invalid(field, 'must be a string or null');
  }
  return value as String?;
}

int? _optionalIntOrExisting(
  Map<String, Object?> data,
  String key,
  int? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    return existing;
  }
  final value = data[key];
  if (value == null) {
    return null;
  }
  return _nonNegativeRangeInt(value, field);
}

int? _nullableIntOrExisting(
  Map<String, Object?> data,
  String key,
  int? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    return existing;
  }
  final value = data[key];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw _invalid(field, 'must be an integer or null');
  }
  return value;
}

int? _intOrExisting(
  Map<String, Object?> data,
  String key,
  int? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    return existing;
  }
  final value = data[key];
  if (value is! int) {
    throw _invalid(field, 'must be an integer');
  }
  return value;
}

int _nonNegativeInt(Object? value, String field) {
  if (value is! int) {
    throw _invalid(field, 'must be an integer');
  }
  if (value < 0) {
    throw _invalid(field, 'must not be negative');
  }
  return value;
}

int _nonNegativeRangeInt(Object? value, String field) {
  final result = _nonNegativeInt(value, field);
  _validateInt32(result, field);
  return result;
}

void _validateInt32(int value, String field) {
  if (value < -2147483648 || value > 2147483647) {
    throw _invalid(field, 'is outside the supported integer range');
  }
}

String _updatedByOrExisting(
  Map<String, Object?> data,
  String? existing,
  String field,
) {
  const keys = ['updated_by_device_id', 'updated_by'];
  for (final key in keys) {
    if (data.containsKey(key)) {
      return _requiredUuid(data, key, field);
    }
  }
  if (existing == null) {
    throw _invalid(field, 'is required for a new product');
  }
  return existing;
}

DateTime _dateTimeOrExisting(
  Map<String, Object?> data,
  String key,
  DateTime? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    if (existing == null) {
      throw _invalid(field, 'is required');
    }
    return existing.toUtc();
  }
  return _dateTime(data[key], field);
}

DateTime? _nullableDateTimeOrExisting(
  Map<String, Object?> data,
  String key,
  DateTime? existing,
  String field,
) {
  if (!data.containsKey(key)) {
    return existing?.toUtc();
  }
  final value = data[key];
  if (value == null) {
    return null;
  }
  return _dateTime(value, field);
}

DateTime? _nullableDateTime(Object? value, String field) {
  if (value == null) {
    return null;
  }
  return _dateTime(value, field);
}

DateTime _dateTime(Object? value, String field) {
  if (value is! String || !_rfc3339UtcPattern.hasMatch(value)) {
    throw _invalid(field, 'must be an RFC3339 UTC timestamp');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) {
    throw _invalid(field, 'must be an RFC3339 UTC timestamp');
  }
  return parsed.toUtc();
}

bool _isUuid(String value) =>
    _uuidPattern.hasMatch(value) &&
    value.toLowerCase() != '00000000-0000-0000-0000-000000000000';

bool _sameInstant(DateTime? left, DateTime? right) {
  if (left == null || right == null) {
    return left == null && right == null;
  }
  return left.toUtc().isAtSameMomentAs(right.toUtc());
}

bool _preservesLocalIntent(String status) => status != _syncedStatus;

String _preservedStatus(String status) => status;

SyncProtocolException _invalid(String field, String message) {
  return SyncProtocolException(
    SyncProtocolErrorKind.invalidResponse,
    message,
    field: field,
  );
}

DateTime _utcNow() => DateTime.now().toUtc();
