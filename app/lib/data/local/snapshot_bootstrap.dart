import 'package:drift/drift.dart';
import 'package:sync_engine/sync_engine.dart';

import 'stoksync_database.dart';

/// Replaces the local replicated domain with one complete server snapshot.
///
/// The replacement is deliberately kept in the Drift layer because it must
/// coordinate SQLite foreign keys, the local immutable-ledger guard, and the
/// singleton sync state in one transaction. Queued local operations and
/// conflict records are local intent rather than replica rows, so bootstrap
/// leaves them intact for the later synchronization/reconciliation workflow.
final class DriftSnapshotBootstrapper {
  DriftSnapshotBootstrapper(this._database);

  final StokSyncDatabase _database;

  /// Validates and atomically installs [snapshot].
  ///
  /// A successful call leaves no previous product, movement, or balance row in
  /// the replicated domain. Any validation or SQLite failure leaves both the
  /// previous replica and its cursor unchanged.
  Future<void> bootstrap(SnapshotResponse snapshot) async {
    snapshot.validate();
    await _database.transaction(() async {
      await _clearReplicatedDomain();
      await _insertProducts(snapshot);
      await _insertMovements(snapshot);
      await _insertBalances(snapshot);
      await _persistSyncState(snapshot);
    });
  }

  /// Decodes the server JSON response before entering the same atomic path.
  Future<void> bootstrapFromJson(String source) {
    return bootstrap(SnapshotResponse.fromJsonString(source));
  }

  Future<void> _clearReplicatedDomain() async {
    // Stock movements are immutable during normal operation. Bootstrap is the
    // one trusted full-replica replacement path, so temporarily remove only
    // the delete guard while still remaining inside the surrounding SQLite
    // transaction. The trigger is recreated even when cleanup fails; a
    // transaction rollback restores the prior trigger/data state as well.
    await _database.customStatement(
      'DROP TRIGGER IF EXISTS stock_movements_prevent_delete',
    );
    try {
      // Balances reference products, and movements reference products, so
      // clear both dependent tables before deleting the product catalog.
      await _database.delete(_database.productBalances).go();
      await _deleteMovementsInForeignKeyOrder();
      await _database.delete(_database.products).go();
    } finally {
      await _database.customStatement(_stockMovementDeleteTriggerSql);
    }
  }

  Future<void> _deleteMovementsInForeignKeyOrder() async {
    // A reversal references its original movement. Delete leaf reversals
    // first, repeating until only non-referenced base rows remain, so SQLite
    // foreign-key checks stay enabled throughout bootstrap.
    while (true) {
      final deleted = await _database.customUpdate(
        'DELETE FROM stock_movements '
        'WHERE reverses_id IS NOT NULL '
        'AND NOT EXISTS ('
        'SELECT 1 FROM stock_movements AS child '
        'WHERE child.reverses_id = stock_movements.id'
        ')',
      );
      if (deleted == 0) {
        break;
      }
    }
    await _database.customUpdate('DELETE FROM stock_movements');
  }

  Future<void> _insertProducts(SnapshotResponse snapshot) async {
    final tombstonesById = <String, SnapshotTombstone>{
      for (final tombstone in snapshot.tombstones) tombstone.id: tombstone,
    };

    for (final product in snapshot.products) {
      final tombstone = tombstonesById[product.id];
      await _database
          .into(_database.products)
          .insert(
            ProductsCompanion.insert(
              id: product.id,
              barcode: Value(product.barcode),
              sku: Value(product.sku),
              name: product.name,
              description: Value(product.description),
              unit: Value(product.unit),
              category: Value(product.category),
              minStock: Value(product.minStock),
              version: Value(tombstone?.version ?? product.version),
              updatedAt: Value(tombstone?.updatedAt ?? product.updatedAt),
              updatedBy:
                  tombstone?.updatedByDeviceId ?? product.updatedByDeviceId,
              deletedAt: Value(tombstone?.deletedAt ?? product.deletedAt),
              createdAt: Value(product.createdAt),
              syncStatus: const Value('synced'),
            ),
          );
    }
  }

  Future<void> _insertMovements(SnapshotResponse snapshot) async {
    final remaining = snapshot.movements.toList(growable: true);
    final insertedIds = <String>{};

    // The server normally returns movements in creation order. This small
    // topological pass also accepts a valid snapshot whose reversal appears
    // before its original, while retaining the self-referencing FK guard.
    while (remaining.isNotEmpty) {
      final ready = remaining
          .where(
            (movement) =>
                movement.reversesId == null ||
                insertedIds.contains(movement.reversesId),
          )
          .toList(growable: false);
      if (ready.isEmpty) {
        throw StateError(
          'snapshot movements contain an unresolvable reversal reference',
        );
      }

      for (final movement in ready) {
        await _database
            .into(_database.stockMovements)
            .insert(
              StockMovementsCompanion.insert(
                id: movement.id,
                productId: movement.productId,
                delta: movement.delta,
                kind: movement.kind,
                note: Value(movement.note),
                occurredAt: movement.occurredAt,
                rawOccurredAt: movement.rawOccurredAt,
                clockOffsetMs: Value(movement.clockOffsetMs),
                countedQty: Value(movement.countedQty),
                reversesId: Value(movement.reversesId),
                deviceId: movement.deviceId,
                serverCreatedAt: Value(movement.serverCreatedAt),
                syncStatus: const Value('synced'),
              ),
            );
        insertedIds.add(movement.id);
        remaining.remove(movement);
      }
    }
  }

  Future<void> _insertBalances(SnapshotResponse snapshot) async {
    final balancesByProductId = <String, SnapshotBalance>{
      for (final balance in snapshot.balances) balance.productId: balance,
    };

    for (final product in snapshot.products) {
      final balance = balancesByProductId[product.id];
      final resolved =
          balance ?? _deriveBalance(product.id, snapshot.movements);
      await _database
          .into(_database.productBalances)
          .insert(
            ProductBalancesCompanion.insert(
              productId: product.id,
              qty: Value(resolved.qty),
              lastMovementAt: Value(resolved.lastMovementAt),
              updatedAt: Value(snapshot.serverTime.toUtc()),
            ),
          );
    }
  }

  SnapshotBalance _deriveBalance(
    String productId,
    List<SnapshotMovement> movements,
  ) {
    var quantity = 0;
    DateTime? lastMovementAt;
    for (final movement in movements) {
      if (movement.productId != productId) {
        continue;
      }
      quantity += movement.delta;
      if (lastMovementAt == null ||
          movement.occurredAt.isAfter(lastMovementAt)) {
        lastMovementAt = movement.occurredAt;
      }
    }
    return SnapshotBalance(
      productId: productId,
      qty: quantity,
      lastMovementAt: lastMovementAt,
    );
  }

  Future<void> _persistSyncState(SnapshotResponse snapshot) async {
    final updated =
        await (_database.update(
          _database.syncState,
        )..where((state) => state.id.equals(_syncStateId))).write(
          SyncStateCompanion(
            cursor: Value(snapshot.cursor),
            bootstrapped: const Value(true),
            lastSyncAt: Value(snapshot.serverTime.toUtc()),
            lastError: const Value<String?>(null),
          ),
        );
    if (updated == 1) {
      return;
    }
    if (updated != 0) {
      throw StateError('snapshot bootstrap updated an unexpected sync state');
    }

    await _database
        .into(_database.syncState)
        .insert(
          SyncStateCompanion.insert(
            id: const Value(_syncStateId),
            cursor: Value(snapshot.cursor),
            bootstrapped: const Value(true),
            lastSyncAt: Value(snapshot.serverTime.toUtc()),
            lastError: const Value<String?>(null),
          ),
        );
  }
}

const int _syncStateId = 1;

const String _stockMovementDeleteTriggerSql =
    'CREATE TRIGGER IF NOT EXISTS stock_movements_prevent_delete '
    'BEFORE DELETE ON stock_movements BEGIN '
    "SELECT RAISE(ABORT, 'stock movements cannot be deleted'); "
    'END';
