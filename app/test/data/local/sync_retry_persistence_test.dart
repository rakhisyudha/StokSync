import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_state_store.dart';
import 'package:sync_engine/sync_engine.dart';

const _operationId = '0192f3a1-0000-7000-8000-000000000001';

void main() {
  test(
    'retains server-error retry metadata after reopening local database',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'stoksync-sync-retry-',
      );
      StokSyncDatabase? database;
      addTearDown(() async {
        await database?.close();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final databaseFile = File(
        '${directory.path}${Platform.pathSeparator}stoksync.sqlite',
      );
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
      final firstDatabase = StokSyncDatabase(NativeDatabase(databaseFile));
      database = firstDatabase;
      await _insertOperation(
        firstDatabase,
        operationId: _operationId,
        localSequence: 1,
        nextAttemptAt: now,
      );

      final engine = SyncEngine(
        transport: _ServerErrorTransport(),
        pendingOperations: PendingOperationDao(firstDatabase),
        cursorStore: DriftSyncCursorStore(firstDatabase),
        deviceId: '0192f200-0000-7000-8000-000000000001',
        now: () => now,
        backoff: SyncBackoffPolicy(
          baseDelay: const Duration(seconds: 5),
          maxDelay: const Duration(minutes: 5),
          jitterRatio: 0,
        ),
      );

      await expectLater(
        engine.synchronize(),
        throwsA(isA<SyncHttpException>()),
      );
      final afterFailure = await _operation(firstDatabase, _operationId);
      expect(afterFailure.status, 'retrying');
      expect(afterFailure.attempts, 1);
      expect(
        afterFailure.nextAttemptAt.toUtc(),
        now.add(const Duration(seconds: 5)),
      );
      expect(
        afterFailure.lastError,
        'SyncHttpException(status: 503, kind: server)',
      );

      await firstDatabase.close();
      database = null;
      final reopenedDatabase = StokSyncDatabase(NativeDatabase(databaseFile));
      database = reopenedDatabase;
      final reopenedDao = PendingOperationDao(reopenedDatabase);

      final persisted = await _operation(reopenedDatabase, _operationId);
      expect(persisted.status, 'retrying');
      expect(persisted.attempts, 1);
      expect(
        persisted.nextAttemptAt.toUtc(),
        now.add(const Duration(seconds: 5)),
      );
      expect(
        persisted.lastError,
        'SyncHttpException(status: 503, kind: server)',
      );
      expect(await reopenedDao.claimDueOperations(now: now, limit: 1), isEmpty);

      final claimed = await reopenedDao.claimDueOperations(
        now: now.add(const Duration(seconds: 5)),
        limit: 1,
      );
      expect(claimed.single.opId, _operationId);
      expect(
        (await _operation(reopenedDatabase, _operationId)).status,
        'inflight',
      );
    },
  );
}

Future<void> _insertOperation(
  StokSyncDatabase database, {
  required String operationId,
  required int localSequence,
  required DateTime nextAttemptAt,
}) {
  return database
      .into(database.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          opId: operationId,
          localSeq: localSequence,
          entity: 'product',
          entityId: 'product-1',
          operation: 'upsert_product',
          payload:
              '{"id":"0192e1aa-0000-7000-8000-000000000001",'
              '"name":"Product"}',
          nextAttemptAt: Value(nextAttemptAt),
        ),
      );
}

Future<PendingOperation> _operation(
  StokSyncDatabase database,
  String operationId,
) {
  return (database.select(
    database.pendingOperations,
  )..where((row) => row.opId.equals(operationId))).getSingle();
}

final class _ServerErrorTransport implements SyncTransport {
  @override
  Future<SyncResponse> synchronize(SyncRequest request) async {
    throw const SyncHttpException(
      statusCode: 503,
      kind: SyncHttpErrorKind.server,
    );
  }
}
