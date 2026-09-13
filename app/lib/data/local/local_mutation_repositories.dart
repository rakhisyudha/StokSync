import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sync_engine/sync_engine.dart';

import '../../core/identifiers/uuid_v7_generator.dart';
import '../../core/identity/device_identity.dart';
import 'local_write_notifier.dart';
import 'stoksync_database.dart';

/// A mutable product form used to create or replace local product details.
final class ProductDraft {
  const ProductDraft({
    required this.name,
    this.barcode,
    this.sku,
    this.description,
    this.unit = 'pcs',
    this.category,
    this.minStock,
  });

  final String? barcode;
  final String? sku;
  final String name;
  final String? description;
  final String unit;
  final String? category;
  final int? minStock;
}

/// Describes a corrected occurrence time while retaining the device's raw time.
final class MovementTiming {
  const MovementTiming({
    this.occurredAt,
    this.rawOccurredAt,
    this.clockOffsetMs = 0,
  });

  final DateTime? occurredAt;
  final DateTime? rawOccurredAt;
  final int clockOffsetMs;
}

/// The supported immutable stock-ledger movement kinds.
enum MovementKind {
  receive('receive'),
  issue('issue'),
  adjust('adjust'),
  stocktake('stocktake');

  const MovementKind(this.wireValue);

  final String wireValue;
}

/// Returned after one product mutation and its durable queued operation commit.
final class ProductMutationResult {
  const ProductMutationResult({
    required this.productId,
    required this.operationId,
    required this.localSequence,
  });

  final String productId;
  final String operationId;
  final int localSequence;
}

/// Returned after one ledger mutation, projection update, and queued operation.
final class MovementMutationResult {
  const MovementMutationResult({
    required this.movementId,
    required this.operationId,
    required this.localSequence,
    required this.delta,
  });

  final String movementId;
  final String operationId;
  final int localSequence;
  final int delta;
}

/// Raised before a database transaction when a local mutation is malformed.
final class LocalMutationValidationException implements Exception {
  LocalMutationValidationException(this.message);

  final String message;

  @override
  String toString() => 'LocalMutationValidationException: $message';
}

/// Raised when a mutation references no locally known product.
final class LocalProductNotFoundException implements Exception {
  LocalProductNotFoundException(this.productId);

  final String productId;

  @override
  String toString() => 'LocalProductNotFoundException: $productId';
}

/// Raised when a user-originated mutation targets a tombstoned product.
final class LocalProductDeletedException implements Exception {
  LocalProductDeletedException(this.productId);

  final String productId;

  @override
  String toString() => 'LocalProductDeletedException: $productId';
}

/// Raised when a requested original ledger entry does not exist.
final class LocalMovementNotFoundException implements Exception {
  LocalMovementNotFoundException(this.movementId);

  final String movementId;

  @override
  String toString() => 'LocalMovementNotFoundException: $movementId';
}

/// Allocates and writes FIFO pending operations within the caller's transaction.
///
/// This DAO is deliberately only used by local mutation repositories. Its
/// [enqueue] call must execute inside a database transaction alongside the
/// domain and projection writes it represents.
final class PendingOperationDao implements SyncPendingOperationStore {
  PendingOperationDao(this._database);

  final StokSyncDatabase _database;

  Future<int> enqueue({
    required String operationId,
    required String entity,
    required String entityId,
    required String operation,
    required String payload,
    required int? baseVersion,
    required DateTime enqueuedAt,
  }) async {
    final nextSequence = await _nextSequence();
    await _database
        .into(_database.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            opId: operationId,
            localSeq: nextSequence,
            entity: entity,
            entityId: entityId,
            operation: operation,
            payload: payload,
            baseVersion: Value(baseVersion),
            nextAttemptAt: Value(enqueuedAt.toUtc()),
          ),
        );
    return nextSequence;
  }

  Future<int> _nextSequence() async {
    final maximumSequence = _database.pendingOperations.localSeq.max();
    final row = await (_database.selectOnly(
      _database.pendingOperations,
    )..addColumns([maximumSequence])).getSingle();
    return (row.read(maximumSequence) ?? 0) + 1;
  }

  /// Returns rows abandoned by an interrupted exchange to the recoverable
  /// queue. A row that was already removed by reconciliation is unaffected.
  @override
  Future<void> recoverInterruptedOperations() async {
    await (_database.update(_database.pendingOperations)
          ..where((row) => row.status.equals('inflight')))
        .write(const PendingOperationsCompanion(status: Value('queued')));
  }

  /// Claims due rows in local FIFO order and marks them inflight in the same
  /// SQLite transaction as selection.
  @override
  Future<List<PendingSyncOperation>> claimDueOperations({
    required DateTime now,
    required int limit,
  }) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    final nowUtc = now.toUtc();
    return _database.transaction(() async {
      final rows =
          await (_database.select(_database.pendingOperations)
                ..where(
                  (row) =>
                      row.status.isIn(const ['queued', 'retrying']) &
                      row.nextAttemptAt.isSmallerOrEqualValue(nowUtc),
                )
                ..orderBy([(row) => OrderingTerm.asc(row.localSeq)])
                ..limit(limit))
              .get();
      if (rows.isEmpty) {
        return const <PendingSyncOperation>[];
      }

      final operationIds = rows.map((row) => row.opId).toList(growable: false);
      final updatedRows =
          await (_database.update(_database.pendingOperations)..where(
                (row) =>
                    row.opId.isIn(operationIds) &
                    row.status.isIn(const ['queued', 'retrying']) &
                    row.nextAttemptAt.isSmallerOrEqualValue(nowUtc),
              ))
              .write(
                const PendingOperationsCompanion(status: Value('inflight')),
              );
      if (updatedRows != rows.length) {
        throw StateError('pending operation claim changed unexpectedly');
      }

      return rows
          .map(
            (row) => PendingSyncOperation(
              opId: row.opId,
              localSeq: row.localSeq,
              entity: row.entity,
              entityId: row.entityId,
              operation: row.operation,
              payload: row.payload,
              baseVersion: row.baseVersion,
              attempts: row.attempts,
              nextAttemptAt: row.nextAttemptAt,
              lastError: row.lastError,
              status: PendingSyncOperationStatus.inflight,
            ),
          )
          .toList(growable: false);
    });
  }

  /// Increments the durable attempt counter and schedules the next retry.
  /// Only an inflight row can be transitioned by this method.
  @override
  Future<void> scheduleRetry(
    String operationId, {
    required DateTime scheduledAt,
    required Duration delay,
    required String error,
  }) async {
    if (delay < Duration.zero) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    await _database.transaction(() async {
      final row = await (_database.select(
        _database.pendingOperations,
      )..where((entry) => entry.opId.equals(operationId))).getSingleOrNull();
      if (row == null || row.status != 'inflight') {
        return;
      }
      await (_database.update(
        _database.pendingOperations,
      )..where((entry) => entry.opId.equals(operationId))).write(
        PendingOperationsCompanion(
          attempts: Value(row.attempts + 1),
          nextAttemptAt: Value(scheduledAt.toUtc().add(delay)),
          lastError: Value(error),
          status: const Value('retrying'),
        ),
      );
    });
  }

  /// Releases claimed rows without changing retry metadata. This is used for
  /// authentication/schema blockers and failed local response application.
  @override
  Future<void> releaseInFlight(Iterable<String> operationIds) async {
    final ids = operationIds.toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    await (_database.update(_database.pendingOperations)
          ..where((row) => row.opId.isIn(ids) & row.status.equals('inflight')))
        .write(const PendingOperationsCompanion(status: Value('queued')));
  }

  /// Parks a non-retryable operation while retaining its payload and error.
  @override
  Future<void> markBlocked(String operationId, {required String error}) async {
    await (_database.update(_database.pendingOperations)..where(
          (row) => row.opId.equals(operationId) & row.status.equals('inflight'),
        ))
        .write(
          PendingOperationsCompanion(
            lastError: Value(error),
            status: const Value('blocked'),
          ),
        );
  }
}

/// Writes product creates, edits, and tombstones with exactly one pending
/// operation per successful user-originated mutation.
final class LocalProductRepository {
  LocalProductRepository({
    required StokSyncDatabase database,
    required IdentifierGenerator identifierGenerator,
    required DeviceIdentity deviceIdentity,
    DateTime Function()? clock,
    PendingOperationDao? pendingOperations,
    LocalWriteNotifier? localWriteNotifier,
  }) : _database = database,
       _identifierGenerator = identifierGenerator,
       _deviceIdentity = deviceIdentity,
       _clock = clock ?? _utcNow,
       _pendingOperations = pendingOperations ?? PendingOperationDao(database),
       _localWriteNotifier = localWriteNotifier;

  final StokSyncDatabase _database;
  final IdentifierGenerator _identifierGenerator;
  final DeviceIdentity _deviceIdentity;
  final DateTime Function() _clock;
  final PendingOperationDao _pendingOperations;
  final LocalWriteNotifier? _localWriteNotifier;

  /// Inserts an active product, its zero-balance projection, and one
  /// `upsert_product` operation atomically.
  Future<ProductMutationResult> create(ProductDraft draft) async {
    final normalizedDraft = _normalizeProductDraft(draft);
    final productId = _newIdentifier('product');
    final operationId = _newIdentifier('operation');
    final deviceId = await _deviceIdentity.getDeviceId();
    final now = _now();

    final result = await _database.transaction(() async {
      await _database
          .into(_database.products)
          .insert(
            ProductsCompanion.insert(
              id: productId,
              name: normalizedDraft.name,
              updatedBy: deviceId,
              barcode: Value(normalizedDraft.barcode),
              sku: Value(normalizedDraft.sku),
              description: Value(normalizedDraft.description),
              unit: Value(normalizedDraft.unit),
              category: Value(normalizedDraft.category),
              minStock: Value(normalizedDraft.minStock),
              updatedAt: Value(now),
              createdAt: Value(now),
              syncStatus: const Value('pending'),
            ),
          );
      await _database
          .into(_database.productBalances)
          .insert(
            ProductBalancesCompanion.insert(
              productId: productId,
              qty: const Value(0),
              updatedAt: Value(now),
            ),
          );
      final localSequence = await _pendingOperations.enqueue(
        operationId: operationId,
        entity: 'product',
        entityId: productId,
        operation: 'upsert_product',
        payload: _productPayload(productId, normalizedDraft),
        baseVersion: null,
        enqueuedAt: now,
      );
      return ProductMutationResult(
        productId: productId,
        operationId: operationId,
        localSequence: localSequence,
      );
    });
    _localWriteNotifier?.notify();
    return result;
  }

  /// Replaces active product details and enqueues an optimistic update using
  /// the currently replicated canonical version as its base version.
  Future<ProductMutationResult> update({
    required String productId,
    required ProductDraft draft,
  }) async {
    _validateIdentifier(productId, 'productId');
    final normalizedDraft = _normalizeProductDraft(draft);
    final operationId = _newIdentifier('operation');
    final deviceId = await _deviceIdentity.getDeviceId();
    final now = _now();

    final result = await _database.transaction(() async {
      final product = await _requireActiveProduct(productId);
      await (_database.update(
        _database.products,
      )..where((row) => row.id.equals(productId))).write(
        ProductsCompanion(
          barcode: Value(normalizedDraft.barcode),
          sku: Value(normalizedDraft.sku),
          name: Value(normalizedDraft.name),
          description: Value(normalizedDraft.description),
          unit: Value(normalizedDraft.unit),
          category: Value(normalizedDraft.category),
          minStock: Value(normalizedDraft.minStock),
          updatedAt: Value(now),
          updatedBy: Value(deviceId),
          syncStatus: const Value('pending'),
        ),
      );
      final localSequence = await _pendingOperations.enqueue(
        operationId: operationId,
        entity: 'product',
        entityId: productId,
        operation: 'upsert_product',
        payload: _productPayload(productId, normalizedDraft),
        baseVersion: product.version,
        enqueuedAt: now,
      );
      return ProductMutationResult(
        productId: productId,
        operationId: operationId,
        localSequence: localSequence,
      );
    });
    _localWriteNotifier?.notify();
    return result;
  }

  /// Writes an audit-preserving product tombstone; historical movements and
  /// the balance projection remain present for local audit and synchronization.
  Future<ProductMutationResult> softDelete(String productId) async {
    _validateIdentifier(productId, 'productId');
    final operationId = _newIdentifier('operation');
    final deviceId = await _deviceIdentity.getDeviceId();
    final now = _now();

    final result = await _database.transaction(() async {
      final product = await _requireActiveProduct(productId);
      await (_database.update(
        _database.products,
      )..where((row) => row.id.equals(productId))).write(
        ProductsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          updatedBy: Value(deviceId),
          syncStatus: const Value('pending'),
        ),
      );
      final localSequence = await _pendingOperations.enqueue(
        operationId: operationId,
        entity: 'product',
        entityId: productId,
        operation: 'delete_product',
        payload: jsonEncode({'id': productId, 'deleted_at': _iso8601(now)}),
        baseVersion: product.version,
        enqueuedAt: now,
      );
      return ProductMutationResult(
        productId: productId,
        operationId: operationId,
        localSequence: localSequence,
      );
    });
    _localWriteNotifier?.notify();
    return result;
  }

  ProductDraft _normalizeProductDraft(ProductDraft draft) {
    final name = _normalizeRequiredText(draft.name, 'name');
    final unit = _normalizeRequiredText(draft.unit, 'unit');
    if (draft.minStock case final minStock? when minStock < 0) {
      throw LocalMutationValidationException(
        'minStock must be zero or greater when provided.',
      );
    }
    return ProductDraft(
      name: name,
      barcode: _normalizeOptionalText(draft.barcode),
      sku: _normalizeOptionalText(draft.sku),
      description: _normalizeOptionalText(draft.description),
      unit: unit,
      category: _normalizeOptionalText(draft.category),
      minStock: draft.minStock,
    );
  }

  Future<Product> _requireActiveProduct(String productId) async {
    final product = await (_database.select(
      _database.products,
    )..where((row) => row.id.equals(productId))).getSingleOrNull();
    if (product == null) {
      throw LocalProductNotFoundException(productId);
    }
    if (product.deletedAt != null) {
      throw LocalProductDeletedException(productId);
    }
    return product;
  }

  String _newIdentifier(String field) {
    final identifier = _identifierGenerator.generate();
    _validateIdentifier(identifier, '$field identifier');
    return identifier;
  }

  DateTime _now() => _clock().toUtc();
}

/// Appends immutable local ledger entries while applying their balance delta
/// and enqueuing exactly one `add_movement` operation in the same transaction.
final class LocalStockMovementRepository {
  LocalStockMovementRepository({
    required StokSyncDatabase database,
    required IdentifierGenerator identifierGenerator,
    required DeviceIdentity deviceIdentity,
    DateTime Function()? clock,
    PendingOperationDao? pendingOperations,
    LocalWriteNotifier? localWriteNotifier,
  }) : _database = database,
       _identifierGenerator = identifierGenerator,
       _deviceIdentity = deviceIdentity,
       _clock = clock ?? _utcNow,
       _pendingOperations = pendingOperations ?? PendingOperationDao(database),
       _localWriteNotifier = localWriteNotifier;

  final StokSyncDatabase _database;
  final IdentifierGenerator _identifierGenerator;
  final DeviceIdentity _deviceIdentity;
  final DateTime Function() _clock;
  final PendingOperationDao _pendingOperations;
  final LocalWriteNotifier? _localWriteNotifier;

  Future<MovementMutationResult> receive({
    required String productId,
    required int quantity,
    String? note,
    MovementTiming? timing,
  }) {
    _validatePositiveQuantity(quantity, 'receive quantity');
    return _recordExplicit(
      productId: productId,
      kind: MovementKind.receive,
      delta: quantity,
      note: note,
      timing: timing,
    );
  }

  Future<MovementMutationResult> issue({
    required String productId,
    required int quantity,
    String? note,
    MovementTiming? timing,
  }) {
    _validatePositiveQuantity(quantity, 'issue quantity');
    return _recordExplicit(
      productId: productId,
      kind: MovementKind.issue,
      delta: -quantity,
      note: note,
      timing: timing,
    );
  }

  Future<MovementMutationResult> adjust({
    required String productId,
    required int delta,
    String? note,
    MovementTiming? timing,
  }) {
    _validateNonZeroDelta(delta);
    return _recordExplicit(
      productId: productId,
      kind: MovementKind.adjust,
      delta: delta,
      note: note,
      timing: timing,
    );
  }

  /// Captures the counted absolute quantity and derives the signed delta from
  /// the projection in the same transaction that appends the ledger entry.
  Future<MovementMutationResult> stocktake({
    required String productId,
    required int countedQuantity,
    String? note,
    MovementTiming? timing,
  }) async {
    _validateIdentifier(productId, 'productId');
    if (countedQuantity < 0) {
      throw LocalMutationValidationException(
        'countedQuantity must be zero or greater.',
      );
    }
    final movementId = _newIdentifier('movement');
    final operationId = _newIdentifier('operation');
    final deviceId = await _deviceIdentity.getDeviceId();
    final resolvedTiming = _resolveTiming(timing);

    final result = await _database.transaction(() async {
      await _requireActiveProduct(productId);
      final currentBalance = await _currentBalance(productId);
      final delta = countedQuantity - currentBalance;
      _validateNonZeroDelta(delta);
      await _insertMovement(
        movementId: movementId,
        productId: productId,
        delta: delta,
        kind: MovementKind.stocktake,
        note: note,
        timing: resolvedTiming,
        countedQuantity: countedQuantity,
        reversesId: null,
        deviceId: deviceId,
      );
      await _applyBalanceDelta(
        productId: productId,
        delta: delta,
        occurredAt: resolvedTiming.occurredAt,
      );
      final localSequence = await _pendingOperations.enqueue(
        operationId: operationId,
        entity: 'stock_movement',
        entityId: movementId,
        operation: 'add_movement',
        payload: _movementPayload(
          movementId: movementId,
          productId: productId,
          delta: delta,
          kind: MovementKind.stocktake,
          note: note,
          timing: resolvedTiming,
          countedQuantity: countedQuantity,
          reversesId: null,
          deviceId: deviceId,
        ),
        baseVersion: null,
        enqueuedAt: _now(),
      );
      return MovementMutationResult(
        movementId: movementId,
        operationId: operationId,
        localSequence: localSequence,
        delta: delta,
      );
    });
    _localWriteNotifier?.notify();
    return result;
  }

  /// Appends an `adjust` movement whose delta exactly negates the referenced
  /// immutable movement. The original row is never changed or deleted.
  Future<MovementMutationResult> reverse({
    required String originalMovementId,
    String? note,
    MovementTiming? timing,
  }) async {
    _validateIdentifier(originalMovementId, 'originalMovementId');
    final movementId = _newIdentifier('movement');
    final operationId = _newIdentifier('operation');
    final deviceId = await _deviceIdentity.getDeviceId();
    final resolvedTiming = _resolveTiming(timing);

    final result = await _database.transaction(() async {
      final original = await (_database.select(
        _database.stockMovements,
      )..where((row) => row.id.equals(originalMovementId))).getSingleOrNull();
      if (original == null) {
        throw LocalMovementNotFoundException(originalMovementId);
      }
      await _requireActiveProduct(original.productId);
      final delta = -original.delta;
      _validateNonZeroDelta(delta);
      await _insertMovement(
        movementId: movementId,
        productId: original.productId,
        delta: delta,
        kind: MovementKind.adjust,
        note: note,
        timing: resolvedTiming,
        countedQuantity: null,
        reversesId: originalMovementId,
        deviceId: deviceId,
      );
      await _applyBalanceDelta(
        productId: original.productId,
        delta: delta,
        occurredAt: resolvedTiming.occurredAt,
      );
      final localSequence = await _pendingOperations.enqueue(
        operationId: operationId,
        entity: 'stock_movement',
        entityId: movementId,
        operation: 'add_movement',
        payload: _movementPayload(
          movementId: movementId,
          productId: original.productId,
          delta: delta,
          kind: MovementKind.adjust,
          note: note,
          timing: resolvedTiming,
          countedQuantity: null,
          reversesId: originalMovementId,
          deviceId: deviceId,
        ),
        baseVersion: null,
        enqueuedAt: _now(),
      );
      return MovementMutationResult(
        movementId: movementId,
        operationId: operationId,
        localSequence: localSequence,
        delta: delta,
      );
    });
    _localWriteNotifier?.notify();
    return result;
  }

  Future<MovementMutationResult> _recordExplicit({
    required String productId,
    required MovementKind kind,
    required int delta,
    required String? note,
    required MovementTiming? timing,
  }) async {
    _validateIdentifier(productId, 'productId');
    _validateNonZeroDelta(delta);
    final movementId = _newIdentifier('movement');
    final operationId = _newIdentifier('operation');
    final deviceId = await _deviceIdentity.getDeviceId();
    final resolvedTiming = _resolveTiming(timing);

    final result = await _database.transaction(() async {
      await _requireActiveProduct(productId);
      await _insertMovement(
        movementId: movementId,
        productId: productId,
        delta: delta,
        kind: kind,
        note: note,
        timing: resolvedTiming,
        countedQuantity: null,
        reversesId: null,
        deviceId: deviceId,
      );
      await _applyBalanceDelta(
        productId: productId,
        delta: delta,
        occurredAt: resolvedTiming.occurredAt,
      );
      final localSequence = await _pendingOperations.enqueue(
        operationId: operationId,
        entity: 'stock_movement',
        entityId: movementId,
        operation: 'add_movement',
        payload: _movementPayload(
          movementId: movementId,
          productId: productId,
          delta: delta,
          kind: kind,
          note: note,
          timing: resolvedTiming,
          countedQuantity: null,
          reversesId: null,
          deviceId: deviceId,
        ),
        baseVersion: null,
        enqueuedAt: _now(),
      );
      return MovementMutationResult(
        movementId: movementId,
        operationId: operationId,
        localSequence: localSequence,
        delta: delta,
      );
    });
    _localWriteNotifier?.notify();
    return result;
  }

  Future<void> _insertMovement({
    required String movementId,
    required String productId,
    required int delta,
    required MovementKind kind,
    required String? note,
    required _ResolvedMovementTiming timing,
    required int? countedQuantity,
    required String? reversesId,
    required String deviceId,
  }) {
    return _database
        .into(_database.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: movementId,
            productId: productId,
            delta: delta,
            kind: kind.wireValue,
            occurredAt: timing.occurredAt,
            rawOccurredAt: timing.rawOccurredAt,
            deviceId: deviceId,
            note: Value(_normalizeOptionalText(note)),
            clockOffsetMs: Value(timing.clockOffsetMs),
            countedQty: Value(countedQuantity),
            reversesId: Value(reversesId),
            syncStatus: const Value('pending'),
          ),
        );
  }

  Future<Product> _requireActiveProduct(String productId) async {
    final product = await (_database.select(
      _database.products,
    )..where((row) => row.id.equals(productId))).getSingleOrNull();
    if (product == null) {
      throw LocalProductNotFoundException(productId);
    }
    if (product.deletedAt != null) {
      throw LocalProductDeletedException(productId);
    }
    return product;
  }

  Future<int> _currentBalance(String productId) async {
    final balance = await (_database.select(
      _database.productBalances,
    )..where((row) => row.productId.equals(productId))).getSingleOrNull();
    return balance?.qty ?? 0;
  }

  Future<void> _applyBalanceDelta({
    required String productId,
    required int delta,
    required DateTime occurredAt,
  }) async {
    final currentBalance = await (_database.select(
      _database.productBalances,
    )..where((row) => row.productId.equals(productId))).getSingleOrNull();
    final updatedAt = _now();
    if (currentBalance == null) {
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
      return;
    }

    final lastMovementAt = currentBalance.lastMovementAt;
    final latestMovementAt =
        lastMovementAt == null || occurredAt.isAfter(lastMovementAt)
        ? occurredAt
        : lastMovementAt;
    await (_database.update(
      _database.productBalances,
    )..where((row) => row.productId.equals(productId))).write(
      ProductBalancesCompanion(
        qty: Value(currentBalance.qty + delta),
        lastMovementAt: Value(latestMovementAt),
        updatedAt: Value(updatedAt),
      ),
    );
  }

  _ResolvedMovementTiming _resolveTiming(MovementTiming? timing) {
    final now = _now();
    final rawOccurredAt = (timing?.rawOccurredAt ?? now).toUtc();
    return _ResolvedMovementTiming(
      occurredAt: (timing?.occurredAt ?? rawOccurredAt).toUtc(),
      rawOccurredAt: rawOccurredAt,
      clockOffsetMs: timing?.clockOffsetMs ?? 0,
    );
  }

  String _newIdentifier(String field) {
    final identifier = _identifierGenerator.generate();
    _validateIdentifier(identifier, '$field identifier');
    return identifier;
  }

  DateTime _now() => _clock().toUtc();
}

final class _ResolvedMovementTiming {
  const _ResolvedMovementTiming({
    required this.occurredAt,
    required this.rawOccurredAt,
    required this.clockOffsetMs,
  });

  final DateTime occurredAt;
  final DateTime rawOccurredAt;
  final int clockOffsetMs;
}

String _productPayload(String productId, ProductDraft draft) {
  return jsonEncode({
    'id': productId,
    'barcode': draft.barcode,
    'sku': draft.sku,
    'name': draft.name,
    'description': draft.description,
    'unit': draft.unit,
    'category': draft.category,
    'min_stock': draft.minStock,
  });
}

String _movementPayload({
  required String movementId,
  required String productId,
  required int delta,
  required MovementKind kind,
  required String? note,
  required _ResolvedMovementTiming timing,
  required int? countedQuantity,
  required String? reversesId,
  required String deviceId,
}) {
  return jsonEncode({
    'id': movementId,
    'product_id': productId,
    'delta': delta,
    'kind': kind.wireValue,
    'note': _normalizeOptionalText(note),
    'occurred_at': _iso8601(timing.occurredAt),
    'raw_occurred_at': _iso8601(timing.rawOccurredAt),
    'clock_offset_ms': timing.clockOffsetMs,
    'counted_qty': countedQuantity,
    'reverses_id': reversesId,
    'device_id': deviceId,
  });
}

DateTime _utcNow() => DateTime.now().toUtc();

String _iso8601(DateTime value) => value.toUtc().toIso8601String();

String? _normalizeOptionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _normalizeRequiredText(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw LocalMutationValidationException('$field must not be blank.');
  }
  return normalized;
}

void _validateIdentifier(String value, String field) {
  if (!UuidV7.isValid(value)) {
    throw LocalMutationValidationException('$field must be a UUIDv7.');
  }
}

void _validatePositiveQuantity(int value, String field) {
  if (value <= 0) {
    throw LocalMutationValidationException('$field must be greater than zero.');
  }
}

void _validateNonZeroDelta(int value) {
  if (value == 0) {
    throw LocalMutationValidationException('movement delta must not be zero.');
  }
}
