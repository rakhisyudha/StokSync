import 'package:sync_engine/sync_engine.dart';

import 'stoksync_database.dart';

/// Reads the durable cursor used to build the next push request.
///
/// Cursor writes remain part of incremental pull/reconciliation work. This
/// adapter intentionally exposes only the read seam needed by Task 3.6.
final class DriftSyncCursorStore implements SyncCursorStore {
  DriftSyncCursorStore(this._database);

  static const _syncStateId = 1;

  final StokSyncDatabase _database;

  @override
  Future<int> readCursor() async {
    final row = await (_database.select(
      _database.syncState,
    )..where((state) => state.id.equals(_syncStateId))).getSingleOrNull();
    return row?.cursor ?? 0;
  }
}
