import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/snapshot_bootstrap.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('DriftSnapshotBootstrapper', () {
    test(
      'installs products, movements, balances, tombstones, and cursor atomically',
      () async {
        final harness = _BootstrapHarness();
        addTearDown(harness.close);

        await harness.bootstrapper.bootstrapFromJson(
          harness.snapshot().toJsonString(),
        );

        final products = await (harness.database.select(
          harness.database.products,
        )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
        expect(products, hasLength(2));
        final active = products.singleWhere(
          (product) => product.id == _activeId,
        );
        final deleted = products.singleWhere(
          (product) => product.id == _deletedId,
        );
        expect(active.name, 'Active product');
        expect(active.version, 3);
        expect(active.syncStatus, 'synced');
        expect(deleted.name, 'Deleted product');
        expect(deleted.deletedAt?.toUtc(), harness.deletedAt);
        expect(deleted.version, 4);
        expect(deleted.updatedBy, _deviceId);
        expect(deleted.syncStatus, 'synced');

        final movements = await harness.database
            .select(harness.database.stockMovements)
            .get();
        expect(movements, hasLength(2));
        expect(
          movements.every((movement) => movement.syncStatus == 'synced'),
          isTrue,
        );
        final issue = movements.singleWhere(
          (movement) => movement.id == _issueId,
        );
        expect(issue.delta, -3);
        expect(issue.serverCreatedAt?.toUtc(), harness.serverTime);
        expect(issue.rawOccurredAt.toUtc(), harness.rawOccurredAt);

        final balances = await (harness.database.select(
          harness.database.productBalances,
        )..orderBy([(row) => OrderingTerm.asc(row.productId)])).get();
        expect(balances, hasLength(2));
        final activeBalance = balances.singleWhere(
          (balance) => balance.productId == _activeId,
        );
        expect(activeBalance.qty, -1);
        expect(activeBalance.lastMovementAt?.toUtc(), harness.occurredAt);
        expect(activeBalance.updatedAt.toUtc(), harness.serverTime);
        expect(
          balances
              .singleWhere((balance) => balance.productId == _deletedId)
              .qty,
          0,
        );

        final state = await harness.database
            .select(harness.database.syncState)
            .getSingle();
        expect(state.cursor, 1482);
        expect(state.bootstrapped, isTrue);
        expect(state.lastSyncAt?.toUtc(), harness.serverTime);
        expect(state.lastError, isNull);
      },
    );

    test(
      'replaces stale replicated products, movements, and projections while retaining local intent',
      () async {
        final harness = _BootstrapHarness();
        addTearDown(harness.close);
        await harness.seedStaleReplica();
        await harness.seedPendingOperation();
        await harness.bootstrapper.bootstrap(harness.snapshot());

        expect(
          await harness.database.select(harness.database.products).get(),
          hasLength(2),
        );
        expect(
          (await harness.database.select(harness.database.products).get())
              .every((product) => product.id != _staleProductId),
          isTrue,
        );
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          hasLength(2),
        );
        expect(
          (await harness.database.select(harness.database.stockMovements).get())
              .every((movement) => movement.id != _staleMovementId),
          isTrue,
        );
        expect(
          await harness.database.select(harness.database.productBalances).get(),
          hasLength(2),
        );
        expect(
          await harness.database
              .select(harness.database.pendingOperations)
              .get(),
          hasLength(1),
        );
      },
    );

    test(
      'rolls back replica replacement and cursor when a later snapshot write fails',
      () async {
        final harness = _BootstrapHarness();
        addTearDown(harness.close);
        await harness.seedStaleReplica();
        await harness.setSyncState(cursor: 77, bootstrapped: true);

        final invalidAtWrite = SnapshotResponse(
          products: [
            _product(
              id: _activeId,
              name: 'First replacement product',
              barcode: 'duplicate-barcode',
            ),
            _product(
              id: _deletedId,
              name: 'Second replacement product',
              barcode: 'duplicate-barcode',
            ),
          ],
          movements: const [],
          balances: const [],
          tombstones: const [],
          cursor: 99,
          serverTime: harness.serverTime,
        );

        await expectLater(
          harness.bootstrapper.bootstrap(invalidAtWrite),
          throwsA(isA<Exception>()),
        );

        final staleProduct = await (harness.database.select(
          harness.database.products,
        )..where((product) => product.id.equals(_staleProductId))).getSingle();
        expect(staleProduct.name, 'Stale product');
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          hasLength(1),
        );
        expect(
          await harness.database.select(harness.database.productBalances).get(),
          hasLength(1),
        );
        final state = await harness.database
            .select(harness.database.syncState)
            .getSingle();
        expect(state.cursor, 77);
        expect(state.bootstrapped, isTrue);

        // The normal immutability guard must be restored after rollback.
        await expectLater(
          (harness.database.delete(
            harness.database.stockMovements,
          )..where((movement) => movement.id.equals(_staleMovementId))).go(),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'rejects inconsistent tombstone metadata without changing local state',
      () async {
        final harness = _BootstrapHarness();
        addTearDown(harness.close);
        await harness.seedStaleReplica();
        await harness.setSyncState(cursor: 81, bootstrapped: true);

        final product = _product(
          id: _activeId,
          name: 'Tombstone mismatch',
          deletedAt: harness.deletedAt,
        );
        final invalid = SnapshotResponse(
          products: [product],
          movements: const [],
          balances: const [],
          tombstones: [
            SnapshotTombstone(
              id: product.id,
              version: product.version + 1,
              deletedAt: harness.deletedAt,
              updatedAt: product.updatedAt,
              updatedByDeviceId: product.updatedByDeviceId,
            ),
          ],
          cursor: 100,
          serverTime: harness.serverTime,
        );

        await expectLater(
          harness.bootstrapper.bootstrap(invalid),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(
          (await harness.database.select(harness.database.products).get())
              .single
              .id,
          _staleProductId,
        );
        expect(
          (await harness.database
                  .select(harness.database.syncState)
                  .getSingle())
              .cursor,
          81,
        );
      },
    );
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _activeId = '0192e1aa-0000-7000-8000-000000000001';
const _deletedId = '0192e1aa-0000-7000-8000-000000000002';
const _issueId = '0192e1aa-0000-7000-8000-000000000003';
const _receiveId = '0192e1aa-0000-7000-8000-000000000004';
const _staleProductId = '0192e1aa-0000-7000-8000-000000000010';
const _staleMovementId = '0192e1aa-0000-7000-8000-000000000011';

final class _BootstrapHarness {
  _BootstrapHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()),
      occurredAt = DateTime.utc(2026, 9, 13, 10),
      rawOccurredAt = DateTime.utc(2026, 9, 13, 9, 59),
      deletedAt = DateTime.utc(2026, 9, 13, 10, 1),
      serverTime = DateTime.utc(2026, 9, 13, 10, 2, 15) {
    bootstrapper = DriftSnapshotBootstrapper(database);
  }

  final StokSyncDatabase database;
  late final DriftSnapshotBootstrapper bootstrapper;
  final DateTime occurredAt;
  final DateTime rawOccurredAt;
  final DateTime deletedAt;
  final DateTime serverTime;

  SnapshotResponse snapshot() {
    final deletedProduct = _product(
      id: _deletedId,
      name: 'Deleted product',
      version: 4,
      updatedAt: deletedAt,
      deletedAt: deletedAt,
    );
    return SnapshotResponse(
      products: [
        _product(id: _activeId, name: 'Active product', version: 3),
        deletedProduct,
      ],
      movements: [
        SnapshotMovement(
          id: _receiveId,
          productId: _activeId,
          delta: 2,
          kind: 'receive',
          note: 'bootstrap receive',
          occurredAt: occurredAt.subtract(const Duration(minutes: 1)),
          rawOccurredAt: rawOccurredAt.subtract(const Duration(minutes: 1)),
          clockOffsetMs: 60000,
          countedQty: null,
          reversesId: null,
          deviceId: _deviceId,
          serverCreatedAt: serverTime,
        ),
        SnapshotMovement(
          id: _issueId,
          productId: _activeId,
          delta: -3,
          kind: 'issue',
          note: null,
          occurredAt: occurredAt,
          rawOccurredAt: rawOccurredAt,
          clockOffsetMs: 60000,
          countedQty: null,
          reversesId: null,
          deviceId: _deviceId,
          serverCreatedAt: serverTime,
        ),
      ],
      balances: [
        SnapshotBalance(
          productId: _activeId,
          qty: -1,
          lastMovementAt: occurredAt,
        ),
        const SnapshotBalance(
          productId: _deletedId,
          qty: 0,
          lastMovementAt: null,
        ),
      ],
      tombstones: [
        SnapshotTombstone(
          id: _deletedId,
          version: deletedProduct.version,
          deletedAt: deletedProduct.deletedAt!,
          updatedAt: deletedProduct.updatedAt,
          updatedByDeviceId: deletedProduct.updatedByDeviceId,
        ),
      ],
      cursor: 1482,
      serverTime: serverTime,
    );
  }

  Future<void> seedStaleReplica() async {
    await database
        .into(database.products)
        .insert(
          ProductsCompanion.insert(
            id: _staleProductId,
            name: 'Stale product',
            unit: const Value('pcs'),
            updatedBy: _deviceId,
          ),
        );
    await database
        .into(database.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            id: _staleMovementId,
            productId: _staleProductId,
            delta: 8,
            kind: 'receive',
            occurredAt: occurredAt,
            rawOccurredAt: rawOccurredAt,
            deviceId: _deviceId,
          ),
        );
    await database
        .into(database.productBalances)
        .insert(
          ProductBalancesCompanion.insert(
            productId: _staleProductId,
            qty: const Value(8),
            lastMovementAt: Value(occurredAt),
          ),
        );
  }

  Future<void> seedPendingOperation() {
    return database
        .into(database.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            opId: '0192f3a1-0000-7000-8000-000000000001',
            localSeq: 1,
            entity: 'product',
            entityId: _staleProductId,
            operation: 'upsert_product',
            payload: '{}',
          ),
        );
  }

  Future<void> setSyncState({required int cursor, required bool bootstrapped}) {
    return (database.update(
      database.syncState,
    )..where((state) => state.id.equals(1))).write(
      SyncStateCompanion(
        cursor: Value(cursor),
        bootstrapped: Value(bootstrapped),
      ),
    );
  }

  Future<void> close() => database.close();
}

SnapshotProduct _product({
  required String id,
  required String name,
  String? barcode,
  int version = 1,
  DateTime? updatedAt,
  DateTime? deletedAt,
}) {
  final timestamp = updatedAt ?? DateTime.utc(2026, 9, 13, 10);
  return SnapshotProduct(
    id: id,
    barcode: barcode,
    sku: null,
    name: name,
    description: null,
    unit: 'pcs',
    category: null,
    minStock: null,
    version: version,
    updatedAt: timestamp,
    updatedByDeviceId: _deviceId,
    deletedAt: deletedAt,
    createdAt: DateTime.utc(2026, 9, 13, 9),
  );
}
