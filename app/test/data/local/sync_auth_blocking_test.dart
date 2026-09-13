import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_state_store.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  test(
    'authentication blocking retains local data and leaves queued work recoverable',
    () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
      await _seedLocalReplica(database, now: now, pendingStatus: 'queued');

      final statusStore = DriftSyncStatusStore(database);
      final engine = SyncEngine(
        transport: _AuthenticationTransport(),
        pendingOperations: PendingOperationDao(database),
        cursorStore: DriftSyncCursorStore(database),
        statusStore: statusStore,
        deviceId: _deviceId,
        now: () => now,
      );

      await expectLater(
        engine.synchronize(),
        throwsA(isA<SyncAuthenticationException>()),
      );

      final state = await database.select(database.syncState).getSingle();
      expect(state.status, 'blocked');
      expect(state.lastError, contains('refresh_rejected'));
      expect(state.cursor, 0);
      expect(
        (await database.select(database.products).get()).single.name,
        'Local product',
      );
      expect(
        (await database.select(database.stockMovements).get()).single.delta,
        4,
      );
      expect(
        (await database.select(database.productBalances).get()).single.qty,
        4,
      );
      expect(
        (await database.select(database.pendingOperations).get()).single.status,
        'queued',
      );
      expect(await database.select(database.conflicts).get(), hasLength(1));
    },
  );

  test(
    'a later successful authenticated sync clears blocked metadata only',
    () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
      await _seedLocalReplica(database, now: now, pendingStatus: 'blocked');
      final statusStore = DriftSyncStatusStore(database);
      await statusStore.markBlocked(error: 'refresh_rejected');

      final engine = SyncEngine(
        transport: _SuccessfulTransport(),
        pendingOperations: PendingOperationDao(database),
        cursorStore: DriftSyncCursorStore(database),
        statusStore: statusStore,
        deviceId: _deviceId,
        now: () => now,
      );

      await engine.synchronize();

      final state = await database.select(database.syncState).getSingle();
      expect(state.status, 'idle');
      expect(state.lastError, isNull);
      expect(state.lastSyncAt?.toUtc(), now);
      expect(
        (await database.select(database.products).get()).single.name,
        'Local product',
      );
      expect(
        (await database.select(database.stockMovements).get()).single.delta,
        4,
      );
      expect(
        (await database.select(database.productBalances).get()).single.qty,
        4,
      );
      expect(
        (await database.select(database.pendingOperations).get()).single.status,
        'blocked',
      );
      expect(await database.select(database.conflicts).get(), hasLength(1));
    },
  );
  test('persists blocked status across a database reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'stoksync-auth-blocked-',
    );
    final databaseFile = File(
      '${directory.path}${Platform.pathSeparator}stoksync.sqlite',
    );
    StokSyncDatabase? database;
    addTearDown(() async {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    database = StokSyncDatabase(NativeDatabase(databaseFile));
    await DriftSyncStatusStore(database).markBlocked(
      error: 'SyncAuthenticationException(reason: refresh_rejected)',
    );
    await database.close();
    database = null;

    database = StokSyncDatabase(NativeDatabase(databaseFile));
    final state = await database.select(database.syncState).getSingle();
    expect(state.status, 'blocked');
    expect(state.lastError, contains('refresh_rejected'));
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _productId = '0192e1aa-0000-7000-8000-000000000001';
const _movementId = '0192e1aa-0000-7000-8000-000000000002';
const _operationId = '0192f3a1-0000-7000-8000-000000000001';

Future<void> _seedLocalReplica(
  StokSyncDatabase database, {
  required DateTime now,
  required String pendingStatus,
}) async {
  await database
      .into(database.products)
      .insert(
        ProductsCompanion.insert(
          id: _productId,
          name: 'Local product',
          updatedBy: _deviceId,
          updatedAt: Value(now),
          createdAt: Value(now),
          syncStatus: const Value('pending'),
        ),
      );
  await database
      .into(database.productBalances)
      .insert(
        ProductBalancesCompanion.insert(
          productId: _productId,
          qty: const Value(4),
          lastMovementAt: Value(now),
          updatedAt: Value(now),
        ),
      );
  await database
      .into(database.stockMovements)
      .insert(
        StockMovementsCompanion.insert(
          id: _movementId,
          productId: _productId,
          delta: 4,
          kind: 'receive',
          occurredAt: now,
          rawOccurredAt: now,
          deviceId: _deviceId,
          syncStatus: const Value('pending'),
        ),
      );
  await database
      .into(database.pendingOperations)
      .insert(
        PendingOperationsCompanion.insert(
          opId: _operationId,
          localSeq: 1,
          entity: 'product',
          entityId: _productId,
          operation: 'upsert_product',
          payload: '{"id":"$_productId","name":"Local product"}',
          status: Value(pendingStatus),
        ),
      );
  await database
      .into(database.conflicts)
      .insert(
        ConflictsCompanion.insert(
          opId: 'conflict-1',
          entity: 'product',
          entityId: _productId,
          localPayload: '{"name":"Local product"}',
          reason: 'existing_conflict',
        ),
      );
}

SyncResponse _successResponse(SyncRequest request) {
  return SyncResponse(
    results: const [],
    changes: const [],
    nextCursor: request.cursor,
    hasMore: false,
    serverTime: request.clientTime,
  );
}

final class _AuthenticationTransport implements SyncTransport {
  @override
  Future<SyncResponse> synchronize(SyncRequest request) {
    throw const SyncAuthenticationException(reason: 'refresh_rejected');
  }
}

final class _SuccessfulTransport implements SyncTransport {
  @override
  Future<SyncResponse> synchronize(SyncRequest request) async {
    return _successResponse(request);
  }
}
