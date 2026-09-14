import 'dart:convert';

import 'package:drift/drift.dart';

import 'stoksync_database.dart';

/// Persists stocktake intents that lost the deterministic canonical ordering.
///
/// A displaced intent may already have been synchronized and therefore no
/// longer have a pending operation. In that case the immutable movement id is
/// used as a stable history key; when a pending operation is still present its
/// operation id and original payload are retained instead.
final class StocktakeConflictStore {
  StocktakeConflictStore(this._database, {DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  final StokSyncDatabase _database;
  final DateTime Function() _clock;

  Future<void> recordOutcome(Map<String, Object?> outcome) async {
    final displaced = outcome['displaced'];
    if (displaced == null) {
      return;
    }
    if (displaced is! List) {
      throw FormatException('stocktake_outcome.displaced must be an array');
    }
    if (displaced.isEmpty) {
      return;
    }

    final serverPayload = jsonEncode(outcome);
    final canonicalBalance = outcome['canonical_balance'];
    final basePayload = jsonEncode(<String, Object?>{
      'canonical_balance': canonicalBalance,
    });
    for (final value in displaced) {
      if (value is! Map) {
        throw FormatException(
          'stocktake_outcome.displaced entries must be objects',
        );
      }
      final intent = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw FormatException('stocktake intent keys must be strings');
        }
        intent[entry.key as String] = entry.value;
      }
      final movementId = intent['movement_id'];
      if (movementId is! String || movementId.trim().isEmpty) {
        throw FormatException(
          'stocktake_outcome.displaced.movement_id is required',
        );
      }

      final pending =
          await (_database.select(_database.pendingOperations)..where(
                (row) =>
                    row.entity.equals('stock_movement') &
                    row.entityId.equals(movementId),
              ))
              .getSingleOrNull();
      final historyId = pending?.opId ?? movementId;
      final localPayload = pending?.payload ?? jsonEncode(intent);
      if (pending != null && pending.status != 'blocked') {
        await (_database.update(
          _database.pendingOperations,
        )..where((row) => row.opId.equals(pending.opId))).write(
          PendingOperationsCompanion(
            status: const Value('blocked'),
            lastError: const Value('stocktake_displaced'),
          ),
        );
      }

      final existing = await (_database.select(
        _database.conflicts,
      )..where((row) => row.opId.equals(historyId))).getSingleOrNull();
      final createdAt = _clock().toUtc();
      if (existing == null) {
        await _database
            .into(_database.conflicts)
            .insert(
              ConflictsCompanion.insert(
                opId: historyId,
                entity: 'stock_movement',
                entityId: movementId,
                localPayload: localPayload,
                basePayload: Value(basePayload),
                serverPayload: Value(serverPayload),
                reason: 'stocktake_displaced',
                createdAt: Value(createdAt),
                resolutionStatus: const Value('unresolved'),
              ),
            );
      } else {
        await (_database.update(
          _database.conflicts,
        )..where((row) => row.opId.equals(historyId))).write(
          ConflictsCompanion(
            entity: const Value('stock_movement'),
            entityId: Value(movementId),
            localPayload: Value(localPayload),
            basePayload: Value(basePayload),
            serverPayload: Value(serverPayload),
            reason: const Value('stocktake_displaced'),
            createdAt: Value(createdAt),
            resolutionStatus: const Value('unresolved'),
          ),
        );
      }
    }
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
