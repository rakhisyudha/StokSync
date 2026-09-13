import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

void main() {
  group('StokSyncDatabase initial schema', () {
    test('creates every local replica table and the singleton sync state', () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final tableNames = (await database
              .customSelect(
                "SELECT name FROM sqlite_master "
                "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
              )
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();

      expect(
        tableNames,
        containsAll({
          'products',
          'stock_movements',
          'product_balances',
          'pending_ops',
          'sync_state',
          'conflicts',
        }),
      );

      final syncState = await database.select(database.syncState).getSingle();
      expect(syncState.id, 1);
      expect(syncState.cursor, 0);
      expect(syncState.bootstrapped, isFalse);
      expect(syncState.serverClockOffsetMs, 0);
    });

    test('stores one connected row in each domain, queue, and conflict table', () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);

      await database.into(database.products).insert(
            ProductsCompanion.insert(
              id: 'product-1',
              name: 'Indomie Goreng',
              updatedBy: 'device-1',
              barcode: const Value('089686010947'),
            ),
          );
      await database.into(database.stockMovements).insert(
            StockMovementsCompanion.insert(
              id: 'movement-1',
              productId: 'product-1',
              delta: 6,
              kind: 'stocktake',
              occurredAt: now,
              rawOccurredAt: now,
              deviceId: 'device-1',
              countedQty: const Value(6),
            ),
          );
      await database.into(database.productBalances).insert(
            ProductBalancesCompanion.insert(
              productId: 'product-1',
              qty: const Value(6),
              lastMovementAt: Value(now),
            ),
          );
      await database.into(database.pendingOperations).insert(
            PendingOperationsCompanion.insert(
              opId: 'operation-1',
              localSeq: 1,
              entity: 'stock_movement',
              entityId: 'movement-1',
              operation: 'add_movement',
              payload: '{"id":"movement-1"}',
            ),
          );
      await database.into(database.conflicts).insert(
            ConflictsCompanion.insert(
              opId: 'operation-1',
              entity: 'product',
              entityId: 'product-1',
              localPayload: '{"name":"Local value"}',
              reason: 'version_conflict',
            ),
          );

      expect(await database.select(database.products).get(), hasLength(1));
      expect(
        await database.select(database.stockMovements).get(),
        hasLength(1),
      );
      expect(
        await database.select(database.productBalances).get(),
        hasLength(1),
      );
      expect(
        await database.select(database.pendingOperations).get(),
        hasLength(1),
      );
      expect(await database.select(database.conflicts).get(), hasLength(1));
    });

    test('enforces active barcode uniqueness while allowing barcode reuse after a tombstone', () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      Future<void> insertProduct(String id) {
        return database.into(database.products).insert(
              ProductsCompanion.insert(
                id: id,
                name: 'Product $id',
                updatedBy: 'device-1',
                barcode: const Value('shared-barcode'),
              ),
            );
      }

      await insertProduct('product-1');
      await expectLater(insertProduct('product-2'), throwsA(isA<Exception>()));

      await (database.update(database.products)
            ..where((product) => product.id.equals('product-1')))
          .write(
        ProductsCompanion(deletedAt: Value(DateTime.utc(2026, 9, 13))),
      );
      await insertProduct('product-2');

      expect(await database.select(database.products).get(), hasLength(2));
    });

    test('rejects invalid movement invariants and orphaned product references', () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);

      Future<void> insertMovement({
        required String id,
        required String productId,
        required int delta,
        required String kind,
      }) {
        return database.into(database.stockMovements).insert(
              StockMovementsCompanion.insert(
                id: id,
                productId: productId,
                delta: delta,
                kind: kind,
                occurredAt: now,
                rawOccurredAt: now,
                deviceId: 'device-1',
              ),
            );
      }

      await expectLater(
        insertMovement(
          id: 'invalid-delta',
          productId: 'missing-product',
          delta: 0,
          kind: 'issue',
        ),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        insertMovement(
          id: 'orphaned-movement',
          productId: 'missing-product',
          delta: -1,
          kind: 'issue',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
