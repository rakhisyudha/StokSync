import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

void main() {
  group('local inventory query providers', () {
    test(
      'stream active products and product details from local Drift data',
      () async {
        final harness = _QueryProviderHarness();
        addTearDown(harness.close);
        final container = harness.createContainer();
        addTearDown(container.dispose);
        final activeProductValues = <List<ProductInventory>>[];
        final detailValues = <ProductInventory?>[];

        container.listen<AsyncValue<List<ProductInventory>>>(
          activeProductsProvider,
          (_, next) {
            if (next.hasValue) {
              activeProductValues.add(next.value!);
            }
          },
          fireImmediately: true,
        );
        container.listen<AsyncValue<ProductInventory?>>(
          productDetailProvider('coffee'),
          (_, next) {
            if (next.hasValue) {
              detailValues.add(next.value);
            }
          },
          fireImmediately: true,
        );

        await _waitUntil(() => activeProductValues.isNotEmpty);
        await _waitUntil(() => detailValues.isNotEmpty);
        expect(activeProductValues.single, isEmpty);
        expect(detailValues.single, isNull);

        await harness.insertProduct(id: 'coffee', name: 'Coffee', quantity: 2);
        await harness.insertProduct(
          id: 'tea',
          name: 'Tea',
          quantity: 7,
          deletedAt: DateTime.utc(2026, 9, 13),
        );

        await _waitUntil(
          () => activeProductValues.any(
            (products) =>
                products.length == 1 &&
                products.single.product.id == 'coffee' &&
                products.single.quantity == 2,
          ),
        );
        await _waitUntil(
          () => detailValues.any(
            (detail) =>
                detail?.product.name == 'Coffee' && detail?.quantity == 2,
          ),
        );

        await harness.setBalance('coffee', 5);

        await _waitUntil(
          () => detailValues.any((detail) => detail?.quantity == 5),
        );
        expect(activeProductValues.last.single.quantity, 5);
      },
    );

    test('stream movement history in descending occurrence order', () async {
      final harness = _QueryProviderHarness();
      addTearDown(harness.close);
      await harness.insertProduct(id: 'coffee', name: 'Coffee');
      final container = harness.createContainer();
      addTearDown(container.dispose);
      final histories = <List<StockMovement>>[];

      container.listen<AsyncValue<List<StockMovement>>>(
        movementHistoryProvider('coffee'),
        (_, next) {
          if (next.hasValue) {
            histories.add(next.value!);
          }
        },
        fireImmediately: true,
      );

      await _waitUntil(() => histories.isNotEmpty);
      expect(histories.single, isEmpty);

      await harness.insertMovement(
        id: 'older',
        productId: 'coffee',
        occurredAt: DateTime.utc(2026, 9, 13, 9),
      );
      await _waitUntil(
        () => histories.any(
          (history) => history.length == 1 && history.single.id == 'older',
        ),
      );

      await harness.insertMovement(
        id: 'newer',
        productId: 'coffee',
        occurredAt: DateTime.utc(2026, 9, 13, 10),
      );
      await _waitUntil(
        () => histories.any(
          (history) =>
              history.length == 2 &&
              history[0].id == 'newer' &&
              history[1].id == 'older',
        ),
      );
    });

    test(
      'stream all movement history with product identity and tie ordering',
      () async {
        final harness = _QueryProviderHarness();
        addTearDown(harness.close);
        await harness.insertProduct(id: 'coffee', name: 'Coffee');
        await harness.insertProduct(
          id: 'tea',
          name: 'Tea',
          deletedAt: DateTime.utc(2026, 9, 13),
        );
        final container = harness.createContainer();
        addTearDown(container.dispose);
        final values = <List<MovementWithProduct>>[];

        container.listen<AsyncValue<List<MovementWithProduct>>>(
          allMovementHistoryProvider,
          (_, next) {
            if (next.hasValue) {
              values.add(next.value!);
            }
          },
          fireImmediately: true,
        );

        await _waitUntil(() => values.isNotEmpty);
        expect(values.single, isEmpty);

        final occurredAt = DateTime.utc(2026, 9, 13, 10);
        await harness.insertMovement(
          id: 'older',
          productId: 'coffee',
          occurredAt: occurredAt.subtract(const Duration(hours: 1)),
          note: 'Opening stock',
        );
        await harness.insertMovement(
          id: 'z-newer-tie',
          productId: 'tea',
          occurredAt: occurredAt,
          countedQty: 8,
          kind: 'stocktake',
        );
        await harness.insertMovement(
          id: 'a-older-tie',
          productId: 'coffee',
          occurredAt: occurredAt,
        );

        await _waitUntil(
          () => values.any(
            (rows) =>
                rows.length == 3 &&
                rows[0].movement.id == 'z-newer-tie' &&
                rows[0].product.name == 'Tea' &&
                rows[1].movement.id == 'a-older-tie' &&
                rows[2].product.name == 'Coffee',
          ),
          description: 'cross-product movement history ordering',
        );
        final latest = values.lastWhere((rows) => rows.length == 3);
        expect(latest[0].product.deletedAt, isNotNull);
        expect(latest[0].movement.countedQty, 8);
        expect(latest[2].movement.note, 'Opening stock');
      },
    );

    test('stream low-stock products and local sync summary changes', () async {
      final harness = _QueryProviderHarness();
      addTearDown(harness.close);
      await harness.insertProduct(
        id: 'coffee',
        name: 'Coffee',
        minStock: 5,
        quantity: 4,
      );
      await harness.insertProduct(
        id: 'tea',
        name: 'Tea',
        minStock: 5,
        quantity: 6,
      );
      await harness.insertProduct(
        id: 'tombstoned',
        name: 'Tombstoned',
        minStock: 5,
        quantity: 0,
        deletedAt: DateTime.utc(2026, 9, 13),
      );
      final container = harness.createContainer();
      addTearDown(container.dispose);
      final lowStockValues = <List<ProductInventory>>[];
      final syncSummaries = <SyncSummary>[];
      final syncSummaryErrors = <Object>[];

      container.listen<AsyncValue<List<ProductInventory>>>(
        lowStockProductsProvider,
        (_, next) {
          if (next.hasValue) {
            lowStockValues.add(next.value!);
          }
        },
        fireImmediately: true,
      );
      container.listen<AsyncValue<SyncSummary>>(syncSummaryProvider, (_, next) {
        if (next.hasError) {
          syncSummaryErrors.add(next.error!);
        }
        if (next.hasValue) {
          syncSummaries.add(next.value!);
        }
      }, fireImmediately: true);

      await _waitUntil(
        () =>
            lowStockValues.isNotEmpty &&
            (syncSummaries.isNotEmpty || syncSummaryErrors.isNotEmpty),
        description: 'initial low-stock and sync-summary values',
      );
      expect(syncSummaryErrors, isEmpty);
      expect(syncSummaries, isNotEmpty);
      expect(lowStockValues.single.map((item) => item.product.id), ['coffee']);
      expect(syncSummaries.single.pendingOperationCount, 0);
      expect(syncSummaries.single.unresolvedConflictCount, 0);

      await harness.setBalance('tea', 5);
      await _waitUntil(
        () => lowStockValues.any(
          (products) =>
              products.length == 2 &&
              products[0].product.id == 'coffee' &&
              products[1].product.id == 'tea',
        ),
        description: 'updated low-stock products',
      );

      final lastSyncedAt = DateTime.utc(2026, 9, 13, 10);
      await harness.insertPendingOperation();
      // Rejected source operations remain durable audit history and are
      // represented by conflicts, but must not keep the actionable-work count
      // elevated after a merged follow-up or manual resolution.
      await harness.database
          .into(harness.database.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              opId: 'blocked-operation-2',
              localSeq: 2,
              entity: 'product',
              entityId: 'coffee',
              operation: 'upsert_product',
              payload: '{}',
              status: const Value('blocked'),
            ),
          );
      await harness.insertConflict();
      await harness.updateSyncState(lastSyncedAt);

      await _waitUntil(
        () => syncSummaries.any(
          (summary) =>
              summary.cursor == 8 &&
              summary.pendingOperationCount == 1 &&
              summary.unresolvedConflictCount == 1,
        ),
        description: 'updated sync summary',
      );
      final updatedSummary = syncSummaries.lastWhere(
        (summary) =>
            summary.cursor == 8 &&
            summary.pendingOperationCount == 1 &&
            summary.unresolvedConflictCount == 1,
      );
      expect(updatedSummary.bootstrapped, isTrue);
      expect(updatedSummary.lastSyncedAt, lastSyncedAt);
      expect(updatedSummary.lastError, 'network timeout');
    });
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  String description = 'reactive provider output',
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $description.');
}

final class _QueryProviderHarness {
  _QueryProviderHarness()
    : database = StokSyncDatabase(NativeDatabase.memory());

  final StokSyncDatabase database;

  ProviderContainer createContainer() {
    return ProviderContainer(
      overrides: [stoksyncDatabaseProvider.overrideWithValue(database)],
    );
  }

  Future<void> insertProduct({
    required String id,
    required String name,
    int? minStock,
    int quantity = 0,
    DateTime? deletedAt,
  }) async {
    await database.transaction(() async {
      await database
          .into(database.products)
          .insert(
            ProductsCompanion.insert(
              id: id,
              name: name,
              updatedBy: 'device-1',
              minStock: Value(minStock),
              deletedAt: Value(deletedAt),
            ),
          );
      await database
          .into(database.productBalances)
          .insert(
            ProductBalancesCompanion.insert(
              productId: id,
              qty: Value(quantity),
            ),
          );
    });
  }

  Future<void> setBalance(String productId, int quantity) {
    return (database.update(database.productBalances)
          ..where((balance) => balance.productId.equals(productId)))
        .write(ProductBalancesCompanion(qty: Value(quantity)));
  }

  Future<void> insertMovement({
    required String id,
    required String productId,
    required DateTime occurredAt,
    int delta = 1,
    String kind = 'receive',
    String? note,
    int? countedQty,
  }) {
    return database
        .into(database.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: id,
            productId: productId,
            delta: delta,
            kind: kind,
            note: Value(note),
            occurredAt: occurredAt,
            rawOccurredAt: occurredAt,
            countedQty: Value(countedQty),
            deviceId: 'device-1',
          ),
        );
  }

  Future<void> insertPendingOperation() {
    return database
        .into(database.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            opId: 'operation-1',
            localSeq: 1,
            entity: 'product',
            entityId: 'coffee',
            operation: 'upsert_product',
            payload: '{}',
          ),
        );
  }

  Future<void> insertConflict() {
    return database
        .into(database.conflicts)
        .insert(
          ConflictsCompanion.insert(
            opId: 'operation-1',
            entity: 'product',
            entityId: 'coffee',
            localPayload: '{}',
            reason: 'version_conflict',
          ),
        );
  }

  Future<void> updateSyncState(DateTime lastSyncedAt) {
    return database
        .update(database.syncState)
        .write(
          SyncStateCompanion(
            cursor: const Value(8),
            bootstrapped: const Value(true),
            lastSyncAt: Value(lastSyncedAt),
            lastError: const Value('network timeout'),
          ),
        );
  }

  Future<void> close() => database.close();
}
