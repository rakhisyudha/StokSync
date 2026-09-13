import 'package:drift/drift.dart';
import 'package:sync_engine/sync_engine.dart';

import 'stoksync_database.dart';

/// Persists the sync engine's rolling server clock offset in Drift's singleton
/// sync_state row without coupling the pure-Dart package to Flutter or Drift.
final class DriftServerClockOffsetStore implements ServerClockOffsetStore {
  DriftServerClockOffsetStore(this._database);

  static const _syncStateId = 1;

  final StokSyncDatabase _database;

  @override
  Future<int?> readOffsetMs() async {
    final row = await (_database.select(
      _database.syncState,
    )..where((state) => state.id.equals(_syncStateId))).getSingleOrNull();
    return row?.serverClockOffsetMs;
  }

  @override
  Future<void> writeOffsetMs(int offsetMs) async {
    await _database.transaction(() async {
      final updatedRows =
          await (_database.update(_database.syncState)
                ..where((state) => state.id.equals(_syncStateId)))
              .write(SyncStateCompanion(serverClockOffsetMs: Value(offsetMs)));
      if (updatedRows == 0) {
        await _database
            .into(_database.syncState)
            .insert(
              SyncStateCompanion.insert(
                id: const Value(_syncStateId),
                serverClockOffsetMs: Value(offsetMs),
              ),
            );
      }
    });
  }
}
