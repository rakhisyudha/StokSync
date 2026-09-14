import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'stoksync_database.dart';

/// Supplies the local replica database at the application composition root.
///
/// The concrete database lifecycle belongs to app bootstrap. Tests and feature
/// scopes override this provider with their own [StokSyncDatabase] instance.
final stoksyncDatabaseProvider = Provider<StokSyncDatabase>((ref) {
  throw StateError(
    'StokSyncDatabase must be supplied by the application composition root.',
  );
});

/// Builds the local, read-only inventory queries consumed by Riverpod streams.
final localInventoryQueriesProvider = Provider<LocalInventoryQueries>((ref) {
  return LocalInventoryQueries(ref.watch(stoksyncDatabaseProvider));
});

/// Reactively exposes active catalog products and their current local balance.
final activeProductsProvider =
    StreamProvider.autoDispose<List<ProductInventory>>((ref) {
      return ref.watch(localInventoryQueriesProvider).watchActiveProducts();
    });

/// Reactively exposes one product and its current local balance by identifier.
final productDetailProvider = StreamProvider.autoDispose
    .family<ProductInventory?, String>((ref, productId) {
      return ref
          .watch(localInventoryQueriesProvider)
          .watchProductDetail(productId);
    });

/// Reactively exposes a product's immutable movement history, newest first.
final movementHistoryProvider = StreamProvider.autoDispose
    .family<List<StockMovement>, String>((ref, productId) {
      return ref
          .watch(localInventoryQueriesProvider)
          .watchMovementHistory(productId);
    });

/// Reactively exposes active products whose balance is at or below min stock.
final lowStockProductsProvider =
    StreamProvider.autoDispose<List<ProductInventory>>((ref) {
      return ref.watch(localInventoryQueriesProvider).watchLowStockProducts();
    });

/// Reactively exposes all retained conflicts, newest first. Resolved rows stay
/// visible so the user can inspect the original intent and chosen action.
final conflictsProvider = StreamProvider.autoDispose<List<Conflict>>((ref) {
  return ref.watch(localInventoryQueriesProvider).watchConflicts();
});

/// Reactively exposes one retained conflict by its original operation id.
final conflictDetailProvider = StreamProvider.autoDispose
    .family<Conflict?, String>((ref, operationId) {
      return ref
          .watch(localInventoryQueriesProvider)
          .watchConflict(operationId);
    });

/// Reactively exposes local synchronization metadata and outstanding counts.
final syncSummaryProvider = StreamProvider.autoDispose<SyncSummary>((ref) {
  return ref.watch(localInventoryQueriesProvider).watchSyncSummary();
});

/// Read-only local views that are each backed by a Drift [watch] query.
final class LocalInventoryQueries {
  LocalInventoryQueries(this._database);

  final StokSyncDatabase _database;

  Stream<List<ProductInventory>> watchActiveProducts() {
    final query = _productWithBalanceQuery()
      ..where(_database.products.deletedAt.isNull())
      ..orderBy([
        OrderingTerm.asc(_database.products.name),
        OrderingTerm.asc(_database.products.id),
      ]);
    return query.watch().map(_mapProductInventories);
  }

  Stream<ProductInventory?> watchProductDetail(String productId) {
    final query = _productWithBalanceQuery()
      ..where(_database.products.id.equals(productId));
    return query.watchSingleOrNull().map((row) {
      if (row == null) {
        return null;
      }
      return _productInventoryFromRow(row);
    });
  }

  Stream<List<StockMovement>> watchMovementHistory(String productId) {
    final query = _database.select(_database.stockMovements)
      ..where((movement) => movement.productId.equals(productId))
      ..orderBy([
        (movement) => OrderingTerm.desc(movement.occurredAt),
        (movement) => OrderingTerm.desc(movement.id),
      ]);
    return query.watch();
  }

  Stream<List<ProductInventory>> watchLowStockProducts() {
    final query = _productWithBalanceQuery()
      ..where(
        _database.products.deletedAt.isNull() &
            _database.products.minStock.isNotNull(),
      )
      ..orderBy([
        OrderingTerm.asc(_database.products.name),
        OrderingTerm.asc(_database.products.id),
      ]);
    return query.watch().map(
      (rows) => _mapProductInventories(rows)
          .where((item) => item.quantity <= item.product.minStock!)
          .toList(growable: false),
    );
  }

  Stream<List<Conflict>> watchConflicts() {
    final query = _database.select(_database.conflicts)
      ..orderBy([
        (conflict) => OrderingTerm.desc(conflict.createdAt),
        (conflict) => OrderingTerm.desc(conflict.opId),
      ]);
    return query.watch();
  }

  Stream<Conflict?> watchConflict(String operationId) {
    return (_database.select(_database.conflicts)
          ..where((conflict) => conflict.opId.equals(operationId)))
        .watchSingleOrNull();
  }

  Stream<SyncSummary> watchSyncSummary() {
    final query = _database.customSelect(
      '''
      SELECT
        sync_state.cursor AS cursor,
        sync_state.bootstrapped AS bootstrapped,
        sync_state.last_sync_at AS last_sync_at,
        sync_state.last_error AS last_error,
        sync_state.status AS status,
        -- Blocked rows are retained as conflict/audit history, not actionable
        -- queue work. In particular, a source operation that produced an
        -- auto-merged follow-up must not leave the pending indicator stuck.
        (SELECT COUNT(*) FROM pending_ops
          WHERE status != 'blocked') AS pending_operation_count,
        (SELECT COUNT(*) FROM conflicts
          WHERE resolution_status = 'unresolved') AS unresolved_conflict_count
      FROM sync_state
      WHERE sync_state.id = 1
      ''',
      readsFrom: {
        _database.syncState,
        _database.pendingOperations,
        _database.conflicts,
      },
    );
    return query.watchSingle().map(
      (row) => SyncSummary(
        cursor: row.read<int>('cursor'),
        bootstrapped: row.read<int>('bootstrapped') != 0,
        status: row.read<String>('status'),
        lastSyncedAt: row.readNullable<DateTime>('last_sync_at')?.toUtc(),
        lastError: row.readNullable<String>('last_error'),
        pendingOperationCount: row.read<int>('pending_operation_count'),
        unresolvedConflictCount: row.read<int>('unresolved_conflict_count'),
      ),
    );
  }

  JoinedSelectStatement<HasResultSet, dynamic> _productWithBalanceQuery() {
    return _database.select(_database.products).join([
      leftOuterJoin(
        _database.productBalances,
        _database.productBalances.productId.equalsExp(_database.products.id),
      ),
    ]);
  }

  List<ProductInventory> _mapProductInventories(List<TypedResult> rows) {
    return rows.map(_productInventoryFromRow).toList(growable: false);
  }

  ProductInventory _productInventoryFromRow(TypedResult row) {
    final balance = row.readTableOrNull(_database.productBalances);
    return ProductInventory(
      product: row.readTable(_database.products),
      quantity: balance?.qty ?? 0,
    );
  }
}

/// A product paired with its derived local stock balance.
final class ProductInventory {
  const ProductInventory({required this.product, required this.quantity});

  final Product product;
  final int quantity;
}

/// Local sync metadata needed for a truthful, network-independent status UI.
final class SyncSummary {
  const SyncSummary({
    required this.cursor,
    required this.bootstrapped,
    this.status = 'idle',
    required this.lastSyncedAt,
    required this.lastError,
    required this.pendingOperationCount,
    required this.unresolvedConflictCount,
  });

  final int cursor;
  final bool bootstrapped;
  final String status;
  final DateTime? lastSyncedAt;
  final String? lastError;
  final int pendingOperationCount;
  final int unresolvedConflictCount;
}
