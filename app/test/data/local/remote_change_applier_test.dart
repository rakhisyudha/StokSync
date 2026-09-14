import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/remote_change_applier.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('DriftRemoteChangeApplier', () {
    test('reapplying a product upsert is idempotent', () async {
      final harness = _ApplierHarness();
      addTearDown(harness.close);
      final change = harness.productChange(version: 1);

      await harness.applier.applyChange(change);
      await harness.applier.applyChange(change);

      final products = await harness.database
          .select(harness.database.products)
          .get();
      final balances = await harness.database
          .select(harness.database.productBalances)
          .get();
      expect(products, hasLength(1));
      expect(products.single.name, 'Remote product');
      expect(products.single.syncStatus, 'synced');
      expect(balances, hasLength(1));
      expect(balances.single.qty, 0);
    });

    test('updates a product and applies an idempotent tombstone', () async {
      final harness = _ApplierHarness();
      addTearDown(harness.close);
      await harness.applier.applyChange(harness.productChange(version: 1));

      await harness.applier.applyChange(
        harness.productChange(
          version: 2,
          name: 'Updated product',
          barcode: 'updated-barcode',
          minStock: 12,
        ),
      );
      final deletedAt = harness.now.add(const Duration(minutes: 2));
      final tombstone = harness.productChange(
        version: 3,
        name: 'Updated product',
        barcode: 'updated-barcode',
        minStock: 12,
        operation: 'delete',
        deletedAt: deletedAt,
      );
      await harness.applier.applyChange(tombstone);
      await harness.applier.applyChange(
        harness.productChange(
          version: 4,
          name: 'Stale resurrection',
          operation: 'upsert',
        ),
      );

      final product =
          (await harness.database.select(harness.database.products).get())
              .single;
      expect(product.name, 'Updated product');
      expect(product.barcode, 'updated-barcode');
      expect(product.minStock, 12);
      expect(product.version, 3);
      expect(product.deletedAt?.toUtc(), deletedAt);
      expect(product.syncStatus, 'synced');
      expect(
        await harness.database.select(harness.database.productBalances).get(),
        hasLength(1),
      );
    });

    test(
      'lets a canonical tombstone override a higher optimistic local version',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);
        await harness.seedProduct(status: 'pending');
        await (harness.database.update(
          harness.database.products,
        )..where((row) => row.id.equals(_productId))).write(
          const ProductsCompanion(
            name: Value('Optimistic local edit'),
            version: Value(7),
          ),
        );

        final deletedAt = harness.now.add(const Duration(minutes: 3));
        await harness.applier.applyChange(
          harness.productChange(
            version: 2,
            name: 'Canonical deleted product',
            operation: 'delete',
            deletedAt: deletedAt,
          ),
        );

        final product = await harness.database
            .select(harness.database.products)
            .getSingle();
        expect(product.name, 'Canonical deleted product');
        expect(product.version, 2);
        expect(product.deletedAt?.toUtc(), deletedAt);
        expect(product.syncStatus, 'pending');
      },
    );

    test(
      'preserves local pending and conflict intent while applying a tombstone',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);
        await harness.seedProduct(status: 'pending');
        await harness.database
            .into(harness.database.pendingOperations)
            .insert(
              PendingOperationsCompanion.insert(
                opId: _operationId,
                localSeq: 1,
                entity: 'product',
                entityId: _productId,
                operation: 'upsert_product',
                payload: '{"id":"$_productId","name":"Local edit"}',
              ),
            );
        await harness.database
            .into(harness.database.conflicts)
            .insert(
              ConflictsCompanion.insert(
                opId: _conflictId,
                entity: 'product',
                entityId: _productId,
                localPayload: '{"name":"Local edit"}',
                reason: 'existing_local_intent',
              ),
            );

        await harness.applier.applyChange(
          harness.productChange(
            version: 1,
            name: 'Server edit',
            operation: 'upsert',
          ),
        );
        await harness.applier.applyChange(
          harness.productChange(
            version: 2,
            name: 'Server edit',
            operation: 'delete',
            deletedAt: harness.now.add(const Duration(minutes: 1)),
          ),
        );

        final product =
            (await harness.database.select(harness.database.products).get())
                .single;
        expect(product.name, 'Server edit');
        expect(product.deletedAt, isNotNull);
        expect(product.syncStatus, 'pending');
        expect(
          await harness.database
              .select(harness.database.pendingOperations)
              .get(),
          hasLength(1),
        );
        expect(
          await harness.database.select(harness.database.conflicts).get(),
          hasLength(1),
        );
      },
    );

    test(
      'unions independent canonical movements and remains idempotent on replay',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);
        await harness.applier.applyChange(harness.productChange(version: 1));

        final deviceAMovement = harness.movementChange(
          id: _movementId,
          seq: 20,
          delta: -3,
          kind: 'issue',
          deviceId: _deviceId,
        );
        final deviceBMovement = harness.movementChange(
          id: _otherMovementId,
          seq: 21,
          delta: -2,
          kind: 'issue',
          deviceId: _otherDeviceId,
        );

        await harness.applier.applyChanges([deviceAMovement, deviceBMovement]);
        await harness.applier.applyChanges([deviceAMovement, deviceBMovement]);

        final movements = await harness.database
            .select(harness.database.stockMovements)
            .get();
        expect(movements, hasLength(2));
        expect(movements.map((movement) => movement.id).toSet(), {
          _movementId,
          _otherMovementId,
        });
        expect(
          movements.fold<int>(0, (sum, movement) => sum + movement.delta),
          -5,
        );
        expect(
          (await harness.database
                  .select(harness.database.productBalances)
                  .getSingle())
              .qty,
          -5,
        );
      },
    );

    test(
      'applies movement reversals in dependency order and does not double-count replay',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);
        await harness.applier.applyChange(harness.productChange(version: 1));
        final originalOccurredAt = harness.now;
        final original = harness.movementChange(
          id: _movementId,
          seq: 20,
          delta: -3,
          kind: 'issue',
          occurredAt: originalOccurredAt,
          serverCreatedAt: harness.now.add(const Duration(seconds: 1)),
        );
        final reversal = harness.movementChange(
          id: _reversalId,
          seq: 19,
          delta: 3,
          kind: 'adjust',
          reversesId: _movementId,
          occurredAt: harness.now.add(const Duration(seconds: 2)),
          serverCreatedAt: harness.now.add(const Duration(seconds: 3)),
        );

        await harness.applier.applyChanges([reversal, original]);
        await harness.applier.applyChanges([reversal, original]);

        final movements = await (harness.database.select(
          harness.database.stockMovements,
        )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
        expect(movements, hasLength(2));
        expect(movements.singleWhere((row) => row.id == _movementId).delta, -3);
        final appliedReversal = movements.singleWhere(
          (row) => row.id == _reversalId,
        );
        expect(appliedReversal.reversesId, _movementId);
        expect(
          appliedReversal.serverCreatedAt?.toUtc(),
          harness.now.add(const Duration(seconds: 3)),
        );
        final balance =
            (await harness.database
                    .select(harness.database.productBalances)
                    .get())
                .single;
        expect(balance.qty, 0);
      },
    );

    test(
      'records displaced stocktake intent from a remote canonical change',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);
        await harness.seedProduct();

        await harness.applier.applyChange(
          harness.movementChange(
            id: _movementId,
            delta: 3,
            kind: 'stocktake',
            countedQty: 6,
            stocktakeOutcome: <String, Object?>{
              'product_id': _productId,
              'canonical_balance': 6,
              'canonical': <String, Object?>{
                'movement_id': _movementId,
                'product_id': _productId,
                'delta': 3,
                'counted_qty': 6,
                'occurred_at': harness.now.toIso8601String(),
                'device_id': _deviceId,
              },
              'incoming': <String, Object?>{
                'movement_id': _movementId,
                'product_id': _productId,
                'delta': 3,
                'counted_qty': 6,
                'occurred_at': harness.now.toIso8601String(),
                'device_id': _deviceId,
              },
              'displaced': <Object?>[
                <String, Object?>{
                  'movement_id': _otherMovementId,
                  'product_id': _productId,
                  'delta': 2,
                  'counted_qty': 5,
                  'occurred_at': harness.now.toIso8601String(),
                  'device_id': _deviceId,
                },
              ],
            },
          ),
        );

        final conflict = await harness.database
            .select(harness.database.conflicts)
            .getSingle();
        expect(conflict.entity, 'stock_movement');
        expect(conflict.entityId, _otherMovementId);
        expect(conflict.reason, 'stocktake_displaced');
        expect(conflict.resolutionStatus, 'unresolved');
        expect(conflict.serverPayload, contains('canonical_balance'));
        expect(
          (await harness.database
                  .select(harness.database.productBalances)
                  .getSingle())
              .qty,
          3,
        );
      },
    );

    test(
      'persists remote movement metadata without changing local pending status',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);
        await harness.seedProduct();
        await harness.database
            .into(harness.database.stockMovements)
            .insert(
              StockMovementsCompanion.insert(
                id: _movementId,
                productId: _productId,
                delta: 4,
                kind: 'receive',
                note: const Value('local note'),
                occurredAt: harness.now,
                rawOccurredAt: harness.now,
                deviceId: _deviceId,
                syncStatus: const Value('pending'),
              ),
            );
        await (harness.database.update(
          harness.database.productBalances,
        )..where((row) => row.productId.equals(_productId))).write(
          ProductBalancesCompanion(
            qty: const Value(4),
            lastMovementAt: Value(harness.now),
          ),
        );
        await harness.database
            .into(harness.database.pendingOperations)
            .insert(
              PendingOperationsCompanion.insert(
                opId: _operationId,
                localSeq: 1,
                entity: 'stock_movement',
                entityId: _movementId,
                operation: 'add_movement',
                payload: '{"id":"$_movementId","delta":4}',
              ),
            );

        final serverCreatedAt = harness.now.add(const Duration(minutes: 1));
        await harness.applier.applyChange(
          harness.movementChange(
            id: _movementId,
            delta: 4,
            note: 'local note',
            serverCreatedAt: serverCreatedAt,
          ),
        );

        final movement =
            (await harness.database
                    .select(harness.database.stockMovements)
                    .get())
                .single;
        expect(movement.serverCreatedAt?.toUtc(), serverCreatedAt);
        expect(movement.syncStatus, 'pending');
        expect(
          await harness.database
              .select(harness.database.pendingOperations)
              .get(),
          hasLength(1),
        );
        expect(
          (await harness.database
                  .select(harness.database.productBalances)
                  .getSingle())
              .qty,
          4,
        );
      },
    );

    test(
      'rejects missing dependencies and immutable conflicts atomically',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);

        await expectLater(
          harness.applier.applyChange(
            harness.movementChange(productId: _missingProductId),
          ),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          isEmpty,
        );

        await harness.applier.applyChange(harness.productChange(version: 1));
        await expectLater(
          harness.applier.applyChange(
            harness.movementChange(
              reversesId: _missingMovementId,
              kind: 'adjust',
            ),
          ),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          isEmpty,
        );

        await harness.applier.applyChange(
          harness.movementChange(id: _movementId, delta: 2),
        );
        await expectLater(
          harness.applier.applyChange(
            harness.movementChange(id: _movementId, delta: 3),
          ),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(
          (await harness.database
                  .select(harness.database.productBalances)
                  .getSingle())
              .qty,
          2,
        );
      },
    );

    test(
      'rejects active barcode conflicts without leaving a partial row',
      () async {
        final harness = _ApplierHarness();
        addTearDown(harness.close);
        await harness.applier.applyChange(
          harness.productChange(version: 1, barcode: 'shared-barcode'),
        );

        await expectLater(
          harness.applier.applyChange(
            harness.productChange(
              id: _otherProductId,
              version: 1,
              barcode: 'shared-barcode',
            ),
          ),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(
          await harness.database.select(harness.database.products).get(),
          hasLength(1),
        );
      },
    );
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _otherDeviceId = '0192f200-0000-7000-8000-000000000002';
const _productId = '0192e1aa-0000-7000-8000-000000000001';
const _otherProductId = '0192e1aa-0000-7000-8000-000000000002';
const _movementId = '0192e1aa-0000-7000-8000-000000000003';
const _otherMovementId = '0192e1aa-0000-7000-8000-000000000007';
const _reversalId = '0192e1aa-0000-7000-8000-000000000004';
const _missingProductId = '0192e1aa-0000-7000-8000-000000000005';
const _missingMovementId = '0192e1aa-0000-7000-8000-000000000006';
const _operationId = '0192f3a1-0000-7000-8000-000000000001';
const _conflictId = '0192f3a1-0000-7000-8000-000000000002';

final class _ApplierHarness {
  _ApplierHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()),
      now = DateTime.utc(2026, 9, 13, 10, 2, 14) {
    applier = DriftRemoteChangeApplier(database, clock: () => now);
  }

  final StokSyncDatabase database;
  final DateTime now;
  late final DriftRemoteChangeApplier applier;

  Future<void> seedProduct({String status = 'synced'}) async {
    await database
        .into(database.products)
        .insert(
          ProductsCompanion.insert(
            id: _productId,
            barcode: const Value('original-barcode'),
            sku: const Value('SKU-1'),
            name: 'Original product',
            description: const Value('Original description'),
            unit: const Value('pcs'),
            category: const Value('food'),
            minStock: const Value(2),
            version: const Value(0),
            updatedAt: Value(now),
            updatedBy: _deviceId,
            createdAt: Value(now),
            syncStatus: Value(status),
          ),
        );
    await database
        .into(database.productBalances)
        .insert(
          ProductBalancesCompanion.insert(
            productId: _productId,
            updatedAt: Value(now),
          ),
        );
  }

  SyncChangeEntry productChange({
    String id = _productId,
    String name = 'Remote product',
    String? barcode,
    String operation = 'upsert',
    int version = 1,
    int? minStock = 5,
    DateTime? deletedAt,
  }) {
    final timestamp = deletedAt ?? now;
    return SyncChangeEntry(
      seq: version,
      entity: 'product',
      operation: operation,
      data: <String, Object?>{
        'id': id,
        'barcode': barcode,
        'sku': 'REMOTE-SKU',
        'name': name,
        'description': 'Remote description',
        'unit': 'box',
        'category': 'remote',
        'min_stock': minStock,
        'version': version,
        'updated_at': timestamp.toIso8601String(),
        'updated_by_device_id': _deviceId,
        'deleted_at': deletedAt?.toIso8601String(),
        'created_at': now.toIso8601String(),
      },
      createdAt: timestamp,
    );
  }

  SyncChangeEntry movementChange({
    String id = _movementId,
    String productId = _productId,
    int seq = 10,
    int delta = 2,
    String kind = 'receive',
    String? note,
    String? reversesId,
    DateTime? occurredAt,
    DateTime? serverCreatedAt,
    Map<String, Object?>? stocktakeOutcome,
    int? countedQty,
    String deviceId = _deviceId,
  }) {
    final occurred = occurredAt ?? now;
    final created = serverCreatedAt ?? now.add(const Duration(seconds: 1));
    return SyncChangeEntry(
      seq: seq,
      entity: 'stock_movement',
      operation: 'upsert',
      data: <String, Object?>{
        'id': id,
        'product_id': productId,
        'delta': delta,
        'kind': kind,
        'note': note,
        'occurred_at': occurred.toIso8601String(),
        'raw_occurred_at': occurred.toIso8601String(),
        'clock_offset_ms': 0,
        'counted_qty': countedQty,
        'reverses_id': reversesId,
        'device_id': deviceId,
        'server_created_at': created.toIso8601String(),
        if (stocktakeOutcome != null) 'stocktake_outcome': stocktakeOutcome,
      },
      createdAt: created,
    );
  }

  Future<void> close() => database.close();
}
