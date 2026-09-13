import 'package:drift/drift.dart';

import 'stoksync_database.dart';

/// Rebuilds the materialized product-balance projection from the ledger.
///
/// Product rows supply the projection keys so products with no movements retain
/// a zero balance. Quantities and latest movement timestamps are calculated
/// solely from immutable [StockMovements] rows; existing projection values are
/// never read.
final class LocalBalanceProjection {
  LocalBalanceProjection({
    required StokSyncDatabase database,
    DateTime Function()? clock,
  }) : _database = database,
       _clock = clock ?? _utcNow;

  final StokSyncDatabase _database;
  final DateTime Function() _clock;

  /// Atomically replaces every product-balance row with ledger-derived data.
  Future<void> rebuild() async {
    final rebuiltAt = _clock().toUtc();

    await _database.transaction(() async {
      final products = await _database.select(_database.products).get();
      final movements = await _database.select(_database.stockMovements).get();
      final balances = <String, _RebuiltBalance>{
        for (final product in products) product.id: const _RebuiltBalance(),
      };

      for (final movement in movements) {
        final balance = balances[movement.productId];
        if (balance == null) {
          throw StateError(
            'Stock movement ${movement.id} references an unknown product.',
          );
        }
        balances[movement.productId] = balance.apply(movement);
      }

      await _database.delete(_database.productBalances).go();
      for (final entry in balances.entries) {
        final balance = entry.value;
        await _database
            .into(_database.productBalances)
            .insert(
              ProductBalancesCompanion.insert(
                productId: entry.key,
                qty: Value(balance.quantity),
                lastMovementAt: Value(balance.lastMovementAt),
                updatedAt: Value(rebuiltAt),
              ),
            );
      }
    });
  }
}

final class _RebuiltBalance {
  const _RebuiltBalance({this.quantity = 0, this.lastMovementAt});

  final int quantity;
  final DateTime? lastMovementAt;

  _RebuiltBalance apply(StockMovement movement) {
    final occurredAt = movement.occurredAt;
    final latestMovementAt =
        lastMovementAt == null || occurredAt.isAfter(lastMovementAt!)
        ? occurredAt
        : lastMovementAt;
    return _RebuiltBalance(
      quantity: quantity + movement.delta,
      lastMovementAt: latestMovementAt,
    );
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
