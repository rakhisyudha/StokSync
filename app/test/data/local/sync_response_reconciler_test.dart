import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_response_reconciler.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('DriftSyncResponseReconciler', () {
    test(
      'marks an applied local consequence synced before deleting its queue row',
      () async {
        final harness = _ReconciliationHarness();
        addTearDown(harness.close);
        final pending = await harness.seedProductOperation();

        await harness.reconciler.reconcile(
          harness.response(
            result: const SyncOperationResult(
              opId: _operationId,
              status: SyncOperationResultStatus.applied,
              seq: 10,
            ),
          ),
          [pending],
        );

        final product = await harness.product();
        expect(product.syncStatus, 'synced');
        expect(await harness.pending(), isEmpty);
        expect(await harness.conflicts(), isEmpty);
      },
    );

    test(
      'persists a matching canonical product change before queue removal',
      () async {
        final harness = _ReconciliationHarness();
        addTearDown(harness.close);
        final pending = await harness.seedProductOperation(baseVersion: 0);
        final updatedAt = DateTime.utc(2026, 9, 13, 10, 3);

        await harness.reconciler.reconcile(
          harness.response(
            result: const SyncOperationResult(
              opId: _operationId,
              status: SyncOperationResultStatus.applied,
              seq: 11,
            ),
            changes: [
              SyncChangeEntry(
                seq: 11,
                entity: 'product',
                operation: 'upsert',
                data: <String, Object?>{
                  'id': _productId,
                  'name': 'Canonical product',
                  'barcode': 'canonical-barcode',
                  'sku': 'CAN-1',
                  'description': 'Canonical description',
                  'unit': 'box',
                  'category': 'food',
                  'min_stock': 12,
                  'version': 1,
                  'updated_at': '2026-09-13T10:03:00.000Z',
                  'updated_by_device_id': _deviceId,
                  'deleted_at': null,
                  'created_at': '2026-09-13T10:02:14.000Z',
                },
              ),
            ],
          ),
          [pending],
        );

        final product = await harness.product();
        expect(product.name, 'Canonical product');
        expect(product.barcode, 'canonical-barcode');
        expect(product.sku, 'CAN-1');
        expect(product.description, 'Canonical description');
        expect(product.unit, 'box');
        expect(product.category, 'food');
        expect(product.minStock, 12);
        expect(product.version, 1);
        expect(product.updatedAt.toUtc(), updatedAt);
        expect(product.syncStatus, 'synced');
        expect(await harness.pending(), isEmpty);
      },
    );

    test(
      'persists a canonical product tombstone before queue removal',
      () async {
        final harness = _ReconciliationHarness();
        addTearDown(harness.close);
        final pending = await harness.seedProductOperation(
          baseVersion: 1,
          operation: 'delete_product',
        );
        final deletedAt = DateTime.utc(2026, 9, 13, 10, 3);

        await harness.reconciler.reconcile(
          harness.response(
            result: const SyncOperationResult(
              opId: _operationId,
              status: SyncOperationResultStatus.applied,
              seq: 14,
            ),
            changes: [
              SyncChangeEntry(
                seq: 14,
                entity: 'product',
                operation: 'delete',
                data: <String, Object?>{
                  'id': _productId,
                  'deleted_at': '2026-09-13T10:03:00.000Z',
                },
              ),
            ],
          ),
          [pending],
        );

        final product = await harness.product();
        expect(product.deletedAt?.toUtc(), deletedAt);
        expect(product.syncStatus, 'synced');
        expect(await harness.pending(), isEmpty);
      },
    );

    test(
      'persists canonical movement metadata before deleting its queue row',
      () async {
        final harness = _ReconciliationHarness();
        addTearDown(harness.close);
        final pending = await harness.seedMovementOperation();
        final serverCreatedAt = DateTime.utc(2026, 9, 13, 10, 3, 1);

        await harness.reconciler.reconcile(
          harness.response(
            result: const SyncOperationResult(
              opId: _operationId,
              status: SyncOperationResultStatus.applied,
              seq: 12,
            ),
            changes: [
              SyncChangeEntry(
                seq: 12,
                entity: 'stock_movement',
                operation: 'upsert',
                data: <String, Object?>{
                  'id': _movementId,
                  'server_created_at': '2026-09-13T10:03:01.000Z',
                },
              ),
            ],
          ),
          [pending],
        );

        final movement = await harness.movement();
        expect(movement.serverCreatedAt?.toUtc(), serverCreatedAt);
        expect(movement.syncStatus, 'synced');
        expect(await harness.pending(), isEmpty);
      },
    );

    test(
      'retains a rejected operation as blocked work and stores its conflict',
      () async {
        final harness = _ReconciliationHarness();
        addTearDown(harness.close);
        final pending = await harness.seedProductOperation(baseVersion: 4);

        await harness.reconciler.reconcile(
          harness.response(
            result: const SyncOperationResult(
              opId: _operationId,
              status: SyncOperationResultStatus.rejected,
              reason: 'version_conflict',
              serverState: <String, Object?>{
                'id': _productId,
                'name': 'Server product',
                'version': 5,
              },
            ),
          ),
          [pending],
        );

        final queueRow = (await harness.pending()).single;
        expect(queueRow.status, 'blocked');
        expect(queueRow.lastError, 'version_conflict');
        final conflict = (await harness.conflicts()).single;
        expect(conflict.opId, _operationId);
        expect(conflict.entity, 'product');
        expect(conflict.entityId, _productId);
        expect(conflict.localPayload, _productPayload);
        expect(conflict.basePayload, '{"base_version":4}');
        expect(conflict.serverPayload, contains('Server product'));
        expect(conflict.reason, 'version_conflict');
        expect(conflict.resolutionStatus, 'unresolved');
        expect((await harness.product()).syncStatus, 'conflict');
      },
    );

    test(
      'rolls back consequence and queue deletion when canonical persistence fails',
      () async {
        final harness = _ReconciliationHarness();
        addTearDown(harness.close);
        final pending = await harness.seedProductOperation();
        await harness.database
            .into(harness.database.products)
            .insert(
              ProductsCompanion.insert(
                id: _otherProductId,
                barcode: const Value('duplicate-barcode'),
                name: 'Other product',
                updatedBy: _deviceId,
                updatedAt: Value(harness.now),
                createdAt: Value(harness.now),
              ),
            );

        await expectLater(
          harness.reconciler.reconcile(
            harness.response(
              result: const SyncOperationResult(
                opId: _operationId,
                status: SyncOperationResultStatus.applied,
                seq: 13,
              ),
              changes: [
                SyncChangeEntry(
                  seq: 13,
                  entity: 'product',
                  operation: 'upsert',
                  data: <String, Object?>{
                    'id': _productId,
                    'barcode': 'duplicate-barcode',
                  },
                ),
              ],
            ),
            [pending],
          ),
          throwsA(isA<Exception>()),
        );

        expect((await harness.product()).syncStatus, 'pending');
        expect((await harness.pending()).single.status, 'inflight');
        expect(await harness.conflicts(), isEmpty);
      },
    );
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _productId = '0192e1aa-0000-7000-8000-000000000001';
const _otherProductId = '0192e1aa-0000-7000-8000-000000000002';
const _movementId = '0192e1aa-0000-7000-8000-000000000003';
const _operationId = '0192f3a1-0000-7000-8000-000000000001';
const _productPayload = '{"id":"$_productId","name":"Local product"}';

final class _ReconciliationHarness {
  _ReconciliationHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()),
      now = DateTime.utc(2026, 9, 13, 10, 2, 14);

  final StokSyncDatabase database;
  final DateTime now;
  late final DriftSyncResponseReconciler reconciler =
      DriftSyncResponseReconciler(database, clock: () => now);

  Future<PendingSyncOperation> seedProductOperation({
    int? baseVersion,
    String operation = 'upsert_product',
  }) async {
    await database
        .into(database.products)
        .insert(
          ProductsCompanion.insert(
            id: _productId,
            name: 'Local product',
            updatedBy: _deviceId,
            updatedAt: Value(now),
            createdAt: Value(now),
            syncStatus: const Value('pending'),
          ),
        );
    await database
        .into(database.productBalances)
        .insert(ProductBalancesCompanion.insert(productId: _productId));
    await _insertPending(
      entity: 'product',
      entityId: _productId,
      operation: operation,
      baseVersion: baseVersion,
    );
    return _pendingOperation(
      entity: 'product',
      entityId: _productId,
      operation: operation,
      baseVersion: baseVersion,
    );
  }

  Future<PendingSyncOperation> seedMovementOperation() async {
    await database
        .into(database.products)
        .insert(
          ProductsCompanion.insert(
            id: _productId,
            name: 'Local product',
            updatedBy: _deviceId,
            updatedAt: Value(now),
            createdAt: Value(now),
          ),
        );
    await database
        .into(database.productBalances)
        .insert(
          ProductBalancesCompanion.insert(
            productId: _productId,
            qty: const Value(3),
          ),
        );
    await database
        .into(database.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: _movementId,
            productId: _productId,
            delta: 3,
            kind: 'receive',
            occurredAt: now,
            rawOccurredAt: now,
            deviceId: _deviceId,
            syncStatus: const Value('pending'),
          ),
        );
    await _insertPending(
      entity: 'stock_movement',
      entityId: _movementId,
      operation: 'add_movement',
    );
    return _pendingOperation(
      entity: 'stock_movement',
      entityId: _movementId,
      operation: 'add_movement',
    );
  }

  SyncResponse response({
    required SyncOperationResult result,
    List<SyncChangeEntry> changes = const [],
  }) {
    return SyncResponse(
      results: [result],
      changes: changes,
      nextCursor: 0,
      hasMore: false,
      serverTime: now,
    );
  }

  Future<Product> product() => (database.select(
    database.products,
  )..where((row) => row.id.equals(_productId))).getSingle();

  Future<StockMovement> movement() => (database.select(
    database.stockMovements,
  )..where((row) => row.id.equals(_movementId))).getSingle();

  Future<List<PendingOperation>> pending() =>
      database.select(database.pendingOperations).get();

  Future<List<Conflict>> conflicts() =>
      database.select(database.conflicts).get();

  Future<void> _insertPending({
    required String entity,
    required String entityId,
    required String operation,
    int? baseVersion,
  }) {
    return database
        .into(database.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            opId: _operationId,
            localSeq: 1,
            entity: entity,
            entityId: entityId,
            operation: operation,
            payload: _productPayload,
            baseVersion: Value(baseVersion),
            status: const Value('inflight'),
          ),
        );
  }

  PendingSyncOperation _pendingOperation({
    required String entity,
    required String entityId,
    required String operation,
    int? baseVersion,
  }) {
    return PendingSyncOperation(
      opId: _operationId,
      localSeq: 1,
      entity: entity,
      entityId: entityId,
      operation: operation,
      payload: _productPayload,
      baseVersion: baseVersion,
      attempts: 0,
      nextAttemptAt: now,
      lastError: null,
      status: PendingSyncOperationStatus.inflight,
    );
  }

  Future<void> close() => database.close();
}
