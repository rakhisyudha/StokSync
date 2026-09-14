import 'package:drift/drift.dart';
import 'package:sync_engine/sync_engine.dart';

import 'stoksync_database.dart';

/// Reads and persists the durable cursor used by incremental synchronization.
///
/// [writeCursor] is intentionally a narrow local-storage operation. When it
/// is called from an enclosing Drift transaction, its update participates in
/// that transaction; the page-level applier uses that property to commit the
/// cursor only with the complete applied change page.
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

  /// Persists [cursor] to the singleton sync-state row.
  ///
  /// The update is deliberately not wrapped in its own transaction. Callers
  /// that need atomicity with other replica writes must invoke it while their
  /// surrounding [StokSyncDatabase.transaction] is active.
  Future<void> writeCursor(int cursor) async {
    if (cursor < 0) {
      throw ArgumentError.value(cursor, 'cursor', 'must not be negative');
    }

    final updated =
        await (_database.update(_database.syncState)
              ..where((state) => state.id.equals(_syncStateId)))
            .write(SyncStateCompanion(cursor: Value(cursor)));
    if (updated != 1) {
      throw StateError(
        'expected exactly one sync-state row while persisting cursor',
      );
    }
  }
}

/// Persists the durable synchronization status without touching replica data.
///
/// Authentication blockers retain every product, movement, pending operation,
/// and conflict row. A later fully applied authenticated cycle clears only this
/// metadata and records its server timestamp.
final class DriftSyncStatusStore implements SyncStatusStore {
  DriftSyncStatusStore(this._database);

  static const _syncStateId = 1;

  final StokSyncDatabase _database;

  @override
  Future<void> markSyncing() async {
    await _write(const SyncStateCompanion(status: Value('syncing')));
  }

  @override
  Future<void> markBackingOff({required String error}) async {
    await _write(
      SyncStateCompanion(
        status: const Value('backing_off'),
        lastError: Value(_safeError(error)),
      ),
    );
  }

  @override
  Future<void> markError({required String error}) async {
    await _write(
      SyncStateCompanion(
        status: const Value('idle'),
        lastError: Value(_safeError(error)),
      ),
    );
  }

  @override
  Future<void> markBlocked({required String error}) async {
    await _write(
      SyncStateCompanion(
        status: const Value('blocked'),
        lastError: Value(
          error.trim().isEmpty ? 'authentication_required' : error.trim(),
        ),
      ),
    );
  }

  @override
  Future<void> markSyncSucceeded(DateTime serverTime) async {
    await _write(
      SyncStateCompanion(
        status: const Value('idle'),
        lastError: const Value(null),
        lastSyncAt: Value(serverTime.toUtc()),
      ),
    );
  }

  Future<void> _write(SyncStateCompanion values) async {
    final updated = await (_database.update(
      _database.syncState,
    )..where((state) => state.id.equals(_syncStateId))).write(values);
    if (updated != 1) {
      throw StateError(
        'expected exactly one sync-state row while persisting sync status',
      );
    }
  }
}

String _safeError(String error) {
  final normalized = error.trim();
  return normalized.isEmpty ? 'sync_failed' : normalized;
}
