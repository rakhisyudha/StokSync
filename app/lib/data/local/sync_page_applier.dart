import 'package:sync_engine/sync_engine.dart';

import 'remote_change_applier.dart';
import 'stoksync_database.dart';
import 'sync_state_store.dart';

/// Atomically applies one complete remote change-feed page.
///
/// Response validation happens before any local write. The current cursor is
/// then read inside the transaction, every change is delegated to
/// [DriftRemoteChangeApplier], and the returned cursor is persisted only after
/// the complete page succeeds. A failed change or cursor write therefore
/// rolls back the entire page and leaves the previous cursor visible after a
/// restart.
final class DriftSyncPageApplier {
  DriftSyncPageApplier(
    this._database, {
    DriftRemoteChangeApplier? remoteChangeApplier,
  }) : _remoteChangeApplier =
           remoteChangeApplier ?? DriftRemoteChangeApplier(_database),
       _cursorStore = DriftSyncCursorStore(_database);

  final StokSyncDatabase _database;
  final DriftRemoteChangeApplier _remoteChangeApplier;
  final DriftSyncCursorStore _cursorStore;

  /// Applies [response.changes] and advances the local cursor atomically.
  ///
  /// [skipSequences] identifies changes whose canonical consequences were
  /// already persisted while reconciling applied push results in the same
  /// response. Those entries still belong to the page and therefore still
  /// contribute to the cursor, but are not written a second time.
  Future<void> applyPage(
    SyncResponse response, {
    Set<int> skipSequences = const <int>{},
  }) async {
    // Validate protocol-level metadata before opening a write transaction.
    // Entity payload validation remains in DriftRemoteChangeApplier so that a
    // failure after an earlier change still exercises SQLite rollback.
    response.toJson();
    _validateSkippedSequences(response, skipSequences);

    await _database.transaction(() async {
      final state = await (_database.select(
        _database.syncState,
      )..where((row) => row.id.equals(_syncStateId))).getSingleOrNull();
      if (state == null) {
        throw StateError('sync-state row is missing');
      }

      _validatePage(response, state.cursor);
      final changesToApply = response.changes
          .where((change) => !skipSequences.contains(change.seq))
          .toList(growable: false);
      await _remoteChangeApplier.applyChangesInTransaction(
        changesToApply,
        serverTime: response.serverTime,
      );

      if (response.nextCursor != state.cursor) {
        await _cursorStore.writeCursor(response.nextCursor);
      }
    });
  }

  /// Alias that keeps the boundary convenient for callers treating a response
  /// as the unit of local application.
  Future<void> apply(
    SyncResponse response, {
    Set<int> skipSequences = const <int>{},
  }) => applyPage(response, skipSequences: skipSequences);

  void _validateSkippedSequences(
    SyncResponse response,
    Set<int> skipSequences,
  ) {
    final changeSequences = response.changes
        .map((change) => change.seq)
        .toSet();
    for (final sequence in skipSequences) {
      if (!changeSequences.contains(sequence)) {
        throw _invalidPage(
          'skip_sequences',
          'contains a sequence that is not present in the response page',
        );
      }
    }
  }

  void _validatePage(SyncResponse response, int currentCursor) {
    if (response.nextCursor < currentCursor) {
      throw _invalidPage(
        'next_cursor',
        'must not move the local cursor backwards',
      );
    }

    final changes = response.changes;
    if (changes.isEmpty) {
      if (response.hasMore) {
        throw _invalidPage(
          'has_more',
          'cannot be true when a page contains no changes',
        );
      }
      if (response.nextCursor != currentCursor) {
        throw _invalidPage(
          'next_cursor',
          'must preserve the local cursor when a page contains no changes',
        );
      }
      return;
    }

    final lastSequence = changes.last.seq;
    if (response.nextCursor != lastSequence) {
      throw _invalidPage(
        'next_cursor',
        'must equal the last change sequence in a non-empty page',
      );
    }

    // A page that advances the cursor must begin after the cursor read for
    // this transaction. A page ending at the current cursor is a safe replay;
    // mixed stale/future pages are incomplete and could conceal a skipped
    // change, so reject them without applying any row.
    if (response.nextCursor > currentCursor &&
        changes.first.seq <= currentCursor) {
      throw _invalidPage(
        'changes',
        'contains changes at or before the current cursor while advancing it',
      );
    }
  }
}

const int _syncStateId = 1;

SyncProtocolException _invalidPage(String field, String message) {
  return SyncProtocolException(
    SyncProtocolErrorKind.invalidResponse,
    message,
    field: field,
  );
}
