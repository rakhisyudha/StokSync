import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_state_store.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('PendingOperationDao', () {
    test('claims only due rows in local-sequence FIFO order', () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = PendingOperationDao(database);
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);

      await _insertOperation(
        database,
        operationId: 'operation-2',
        localSequence: 2,
        status: 'queued',
        nextAttemptAt: now,
      );
      await _insertOperation(
        database,
        operationId: 'operation-1',
        localSequence: 1,
        status: 'retrying',
        nextAttemptAt: now.subtract(const Duration(seconds: 1)),
      );
      await _insertOperation(
        database,
        operationId: 'operation-future',
        localSequence: 3,
        status: 'queued',
        nextAttemptAt: now.add(const Duration(seconds: 1)),
      );
      await _insertOperation(
        database,
        operationId: 'operation-blocked',
        localSequence: 4,
        status: 'blocked',
        nextAttemptAt: now,
      );

      final claimed = await dao.claimDueOperations(now: now, limit: 2);

      expect(claimed.map((operation) => operation.opId), [
        'operation-1',
        'operation-2',
      ]);
      expect(claimed.map((operation) => operation.status), [
        PendingSyncOperationStatus.inflight,
        PendingSyncOperationStatus.inflight,
      ]);
      final rows = await database.select(database.pendingOperations).get();
      expect(
        rows.singleWhere((row) => row.opId == 'operation-1').status,
        'inflight',
      );
      expect(
        rows.singleWhere((row) => row.opId == 'operation-2').status,
        'inflight',
      );
      expect(
        rows.singleWhere((row) => row.opId == 'operation-future').status,
        'queued',
      );
      expect(
        rows.singleWhere((row) => row.opId == 'operation-blocked').status,
        'blocked',
      );
    });

    test(
      'persists retry metadata and makes the row due again at its deadline',
      () async {
        final database = StokSyncDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final dao = PendingOperationDao(database);
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        await _insertOperation(
          database,
          operationId: 'operation-1',
          localSequence: 1,
          status: 'queued',
          nextAttemptAt: now,
        );

        await dao.claimDueOperations(now: now, limit: 1);
        await dao.scheduleRetry(
          'operation-1',
          scheduledAt: now,
          delay: const Duration(seconds: 5),
          error: 'network failure',
        );

        var row = await _operation(database, 'operation-1');
        expect(row.status, 'retrying');
        expect(row.attempts, 1);
        expect(row.nextAttemptAt.toUtc(), now.add(const Duration(seconds: 5)));
        expect(row.lastError, 'network failure');
        expect(await dao.claimDueOperations(now: now, limit: 1), isEmpty);

        final claimed = await dao.claimDueOperations(
          now: now.add(const Duration(seconds: 5)),
          limit: 1,
        );
        expect(claimed.single.opId, 'operation-1');
        expect((await _operation(database, 'operation-1')).status, 'inflight');
      },
    );

    test(
      'recovers inflight rows after interruption without changing attempts',
      () async {
        final database = StokSyncDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final dao = PendingOperationDao(database);
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        await _insertOperation(
          database,
          operationId: 'operation-1',
          localSequence: 1,
          status: 'queued',
          nextAttemptAt: now,
          attempts: 3,
          lastError: 'previous network failure',
        );

        await dao.claimDueOperations(now: now, limit: 1);
        await dao.recoverInterruptedOperations();

        final row = await _operation(database, 'operation-1');
        expect(row.status, 'queued');
        expect(row.attempts, 3);
        expect(row.lastError, 'previous network failure');
        expect(
          (await dao.claimDueOperations(now: now, limit: 1)).single.opId,
          'operation-1',
        );
      },
    );

    test('releases blocked rows without changing retry metadata', () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final dao = PendingOperationDao(database);
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
      await _insertOperation(
        database,
        operationId: 'operation-1',
        localSequence: 1,
        status: 'queued',
        nextAttemptAt: now,
        attempts: 2,
      );

      await dao.claimDueOperations(now: now, limit: 1);
      await dao.releaseInFlight(['operation-1']);

      final row = await _operation(database, 'operation-1');
      expect(row.status, 'queued');
      expect(row.attempts, 2);
    });
  });

  test('DriftSyncCursorStore reads the singleton sync cursor', () async {
    final database = StokSyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = DriftSyncCursorStore(database);

    expect(await store.readCursor(), 0);
    await (database.update(database.syncState)
          ..where((state) => state.id.equals(1)))
        .write(const SyncStateCompanion(cursor: Value(1482)));
    expect(await store.readCursor(), 1482);
  });
}

Future<void> _insertOperation(
  StokSyncDatabase database, {
  required String operationId,
  required int localSequence,
  required String status,
  required DateTime nextAttemptAt,
  int attempts = 0,
  String? lastError,
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
          attempts: Value(attempts),
          nextAttemptAt: Value(nextAttemptAt),
          lastError: Value(lastError),
          status: Value(status),
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
