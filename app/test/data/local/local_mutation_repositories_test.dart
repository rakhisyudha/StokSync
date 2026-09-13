import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

void main() {
  group('local mutation repositories', () {
    test(
      'atomically creates, updates, and tombstones a product with FIFO operations',
      () async {
        final harness = _RepositoryHarness();
        addTearDown(harness.close);
        final products = harness.productRepository();

        final created = await products.create(
          const ProductDraft(
            name: '  Indomie Goreng  ',
            barcode: '  089686010947  ',
            sku: '  INDO-01 ',
            description: '  Noodles ',
            category: '  Food ',
            minStock: 24,
          ),
        );
        final updated = await products.update(
          productId: created.productId,
          draft: const ProductDraft(
            name: 'Indomie Goreng Special',
            unit: 'pack',
            minStock: 12,
          ),
        );
        final deleted = await products.softDelete(created.productId);

        expect(
          [created.localSequence, updated.localSequence, deleted.localSequence],
          [1, 2, 3],
        );
        final product = await _productById(harness.database, created.productId);
        expect(product.name, 'Indomie Goreng Special');
        expect(product.barcode, isNull);
        expect(product.deletedAt!.toUtc(), harness.now);
        expect(product.syncStatus, 'pending');

        final balance = await _balanceByProduct(
          harness.database,
          created.productId,
        );
        expect(balance.qty, 0);

        final operations = await _pendingOperations(harness.database);
        expect(operations, hasLength(3));
        expect(operations.map((operation) => operation.localSeq), [1, 2, 3]);
        expect(operations.map((operation) => operation.operation), [
          'upsert_product',
          'upsert_product',
          'delete_product',
        ]);
        expect(operations[1].baseVersion, 0);
        expect(operations[2].baseVersion, 0);
        expect(jsonDecode(operations[0].payload), {
          'id': created.productId,
          'barcode': '089686010947',
          'sku': 'INDO-01',
          'name': 'Indomie Goreng',
          'description': 'Noodles',
          'unit': 'pcs',
          'category': 'Food',
          'min_stock': 24,
        });
        expect(jsonDecode(operations[2].payload), {
          'id': created.productId,
          'deleted_at': harness.now.toIso8601String(),
        });
      },
    );

    test(
      'commits receive, issue, adjustment, reversal, and stocktake ledger data with matching balances and FIFO operations',
      () async {
        final harness = _RepositoryHarness();
        addTearDown(harness.close);
        final products = harness.productRepository();
        final movements = harness.movementRepository();
        final product = await products.create(
          const ProductDraft(name: 'Coffee beans'),
        );
        final timing = MovementTiming(
          occurredAt: DateTime.utc(2026, 9, 13, 10),
          rawOccurredAt: DateTime.utc(2026, 9, 13, 9, 59),
          clockOffsetMs: 60000,
        );

        final receive = await movements.receive(
          productId: product.productId,
          quantity: 10,
          note: 'Delivery',
          timing: timing,
        );
        final issue = await movements.issue(
          productId: product.productId,
          quantity: 3,
          timing: timing,
        );
        final adjustment = await movements.adjust(
          productId: product.productId,
          delta: 2,
          timing: timing,
        );
        final reversal = await movements.reverse(
          originalMovementId: adjustment.movementId,
          note: 'Undo count correction',
          timing: timing,
        );
        final stocktake = await movements.stocktake(
          productId: product.productId,
          countedQuantity: 5,
          timing: timing,
        );

        expect(receive.delta, 10);
        expect(issue.delta, -3);
        expect(adjustment.delta, 2);
        expect(reversal.delta, -2);
        expect(stocktake.delta, -2);
        expect(
          [
            receive.localSequence,
            issue.localSequence,
            adjustment.localSequence,
            reversal.localSequence,
            stocktake.localSequence,
          ],
          [2, 3, 4, 5, 6],
        );

        final rows = await (harness.database.select(
          harness.database.stockMovements,
        )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
        expect(rows, hasLength(5));
        expect(rows.map((row) => row.kind).toSet(), {
          'receive',
          'issue',
          'adjust',
          'stocktake',
        });
        final reversalRow = rows.singleWhere(
          (row) => row.id == reversal.movementId,
        );
        expect(reversalRow.kind, 'adjust');
        expect(reversalRow.reversesId, adjustment.movementId);
        final stocktakeRow = rows.singleWhere(
          (row) => row.id == stocktake.movementId,
        );
        expect(stocktakeRow.countedQty, 5);
        expect(stocktakeRow.delta, -2);
        expect(stocktakeRow.occurredAt.toUtc(), timing.occurredAt);
        expect(stocktakeRow.rawOccurredAt.toUtc(), timing.rawOccurredAt);
        expect(stocktakeRow.clockOffsetMs, 60000);

        final balance = await _balanceByProduct(
          harness.database,
          product.productId,
        );
        expect(balance.qty, 5);
        expect(balance.lastMovementAt!.toUtc(), timing.occurredAt);

        final operations = await _pendingOperations(harness.database);
        expect(operations, hasLength(6));
        expect(operations.map((operation) => operation.localSeq), [
          1,
          2,
          3,
          4,
          5,
          6,
        ]);
        expect(
          operations
              .skip(1)
              .every(
                (operation) =>
                    operation.entity == 'stock_movement' &&
                    operation.operation == 'add_movement',
              ),
          isTrue,
        );
        final stocktakePayload =
            jsonDecode(
                  operations
                      .singleWhere(
                        (operation) =>
                            operation.entityId == stocktake.movementId,
                      )
                      .payload,
                )
                as Map<String, dynamic>;
        expect(stocktakePayload['counted_qty'], 5);
        expect(stocktakePayload['delta'], -2);
        expect(stocktakePayload['device_id'], harness.deviceId);
      },
    );

    test(
      'rolls back every product and projection write when queue insertion fails',
      () async {
        final duplicateOperationId = _uuid(50);
        final harness = _RepositoryHarness(
          identifiers: [_uuid(1), duplicateOperationId],
        );
        addTearDown(harness.close);
        await _insertPendingOperation(
          harness.database,
          operationId: duplicateOperationId,
          localSequence: 1,
        );

        await expectLater(
          harness.productRepository().create(const ProductDraft(name: 'Tea')),
          throwsA(isA<Exception>()),
        );

        expect(
          await harness.database.select(harness.database.products).get(),
          isEmpty,
        );
        expect(
          await harness.database.select(harness.database.productBalances).get(),
          isEmpty,
        );
        final operations = await _pendingOperations(harness.database);
        expect(operations, hasLength(1));
        expect(operations.single.opId, duplicateOperationId);
      },
    );

    test(
      'rolls back the ledger and balance projection when movement queue insertion fails',
      () async {
        final productId = _uuid(60);
        final duplicateOperationId = _uuid(61);
        final harness = _RepositoryHarness(
          identifiers: [_uuid(62), duplicateOperationId],
        );
        addTearDown(harness.close);
        await _insertActiveProduct(
          harness.database,
          productId,
          harness.deviceId,
        );
        await _insertPendingOperation(
          harness.database,
          operationId: duplicateOperationId,
          localSequence: 1,
        );

        await expectLater(
          harness.movementRepository().receive(
            productId: productId,
            quantity: 7,
          ),
          throwsA(isA<Exception>()),
        );

        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          isEmpty,
        );
        final balance = await _balanceByProduct(harness.database, productId);
        expect(balance.qty, 0);
        expect(await _pendingOperations(harness.database), hasLength(1));
      },
    );

    test(
      'enforces local mutation invariants without writing a partial operation',
      () async {
        final harness = _RepositoryHarness();
        addTearDown(harness.close);
        final product = await harness.productRepository().create(
          const ProductDraft(name: 'Sugar'),
        );
        final movements = harness.movementRepository();

        expect(
          () => movements.receive(productId: product.productId, quantity: 0),
          throwsA(isA<LocalMutationValidationException>()),
        );
        await expectLater(
          movements.stocktake(productId: product.productId, countedQuantity: 0),
          throwsA(isA<LocalMutationValidationException>()),
        );
        await expectLater(
          harness.productRepository().update(
            productId: product.productId,
            draft: const ProductDraft(name: '   '),
          ),
          throwsA(isA<LocalMutationValidationException>()),
        );

        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          isEmpty,
        );
        expect(await _pendingOperations(harness.database), hasLength(1));
      },
    );

    test(
      'keeps ledger fields immutable while allowing local sync metadata updates',
      () async {
        final harness = _RepositoryHarness();
        addTearDown(harness.close);
        final product = await harness.productRepository().create(
          const ProductDraft(name: 'Flour'),
        );
        final movement = await harness.movementRepository().receive(
          productId: product.productId,
          quantity: 4,
        );

        await expectLater(
          (harness.database.update(harness.database.stockMovements)
                ..where((row) => row.id.equals(movement.movementId)))
              .write(const StockMovementsCompanion(delta: Value(99))),
          throwsA(isA<Exception>()),
        );
        await expectLater(
          (harness.database.delete(
            harness.database.stockMovements,
          )..where((row) => row.id.equals(movement.movementId))).go(),
          throwsA(isA<Exception>()),
        );

        await (harness.database.update(harness.database.stockMovements)
              ..where((row) => row.id.equals(movement.movementId)))
            .write(const StockMovementsCompanion(syncStatus: Value('synced')));
        final row = await (harness.database.select(
          harness.database.stockMovements,
        )..where((entry) => entry.id.equals(movement.movementId))).getSingle();
        expect(row.delta, 4);
        expect(row.syncStatus, 'synced');
      },
    );
  });
}

final class _RepositoryHarness {
  _RepositoryHarness({List<String>? identifiers})
    : database = StokSyncDatabase(NativeDatabase.memory()),
      identifierGenerator = _QueueIdentifierGenerator(
        identifiers ?? List<String>.generate(40, _uuid),
      ),
      deviceIdentity = DeviceIdentity(
        secureStore: _MemorySecureStore(),
        identifierGenerator: _QueueIdentifierGenerator([_deviceId]),
      );

  final StokSyncDatabase database;
  final IdentifierGenerator identifierGenerator;
  final DeviceIdentity deviceIdentity;
  final DateTime now = DateTime.utc(2026, 9, 13, 10, 2, 14);

  static const String _deviceId = '0192f200-0000-7000-8000-000000000001';

  String get deviceId => _deviceId;

  LocalProductRepository productRepository() => LocalProductRepository(
    database: database,
    identifierGenerator: identifierGenerator,
    deviceIdentity: deviceIdentity,
    clock: () => now,
  );

  LocalStockMovementRepository movementRepository() =>
      LocalStockMovementRepository(
        database: database,
        identifierGenerator: identifierGenerator,
        deviceIdentity: deviceIdentity,
        clock: () => now,
      );

  Future<void> close() => database.close();
}

Future<Product> _productById(StokSyncDatabase database, String productId) {
  return (database.select(
    database.products,
  )..where((row) => row.id.equals(productId))).getSingle();
}

Future<ProductBalance> _balanceByProduct(
  StokSyncDatabase database,
  String productId,
) {
  return (database.select(
    database.productBalances,
  )..where((row) => row.productId.equals(productId))).getSingle();
}

Future<List<PendingOperation>> _pendingOperations(StokSyncDatabase database) {
  return (database.select(
    database.pendingOperations,
  )..orderBy([(row) => OrderingTerm.asc(row.localSeq)])).get();
}

Future<void> _insertActiveProduct(
  StokSyncDatabase database,
  String productId,
  String deviceId,
) async {
  await database
      .into(database.products)
      .insert(
        ProductsCompanion.insert(
          id: productId,
          name: 'Existing product',
          updatedBy: deviceId,
        ),
      );
  await database
      .into(database.productBalances)
      .insert(ProductBalancesCompanion.insert(productId: productId));
}

Future<void> _insertPendingOperation(
  StokSyncDatabase database, {
  required String operationId,
  required int localSequence,
}) {
  return database
      .into(database.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          opId: operationId,
          localSeq: localSequence,
          entity: 'product',
          entityId: _uuid(99),
          operation: 'upsert_product',
          payload: '{}',
        ),
      );
}

String _uuid(int index) {
  return '0192f200-${index.toRadixString(16).padLeft(4, '0')}-7000-8000-'
      '${index.toRadixString(16).padLeft(12, '0')}';
}

final class _QueueIdentifierGenerator implements IdentifierGenerator {
  _QueueIdentifierGenerator(this._identifiers);

  final List<String> _identifiers;

  @override
  String generate() {
    if (_identifiers.isEmpty) {
      throw StateError('No test identifiers remain.');
    }
    return _identifiers.removeAt(0);
  }
}

final class _MemorySecureStore implements SecureKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) => Future.value(value);

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }
}
