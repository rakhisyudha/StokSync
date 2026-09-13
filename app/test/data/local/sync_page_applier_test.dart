import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/remote_change_applier.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_page_applier.dart';
import 'package:stoksync/data/local/sync_state_store.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('DriftSyncPageApplier', () {
    test(
      'applies the complete page and advances its cursor atomically',
      () async {
        final harness = _PageHarness();
        addTearDown(harness.close);

        await harness.pageApplier.applyPage(
          harness.response(
            changes: [
              harness.productChange(seq: 41),
              harness.movementChange(seq: 42, delta: 5),
            ],
            nextCursor: 42,
          ),
        );

        final product =
            (await harness.database.select(harness.database.products).get())
                .single;
        final movement =
            (await harness.database
                    .select(harness.database.stockMovements)
                    .get())
                .single;
        final balance =
            (await harness.database
                    .select(harness.database.productBalances)
                    .get())
                .single;
        expect(product.id, _productId);
        expect(movement.id, _movementId);
        expect(balance.qty, 5);
        expect(await harness.cursor(), 42);
      },
    );

    test(
      'advances past a change already persisted by push reconciliation',
      () async {
        final harness = _PageHarness();
        addTearDown(harness.close);

        await harness.pageApplier.applyPage(
          harness.response(
            changes: [harness.productChange(seq: 41)],
            nextCursor: 41,
          ),
          skipSequences: const {41},
        );

        expect(await harness.cursor(), 41);
        expect(
          await harness.database.select(harness.database.products).get(),
          isEmpty,
        );
      },
    );

    test(
      'replaying a complete page does not duplicate rows or balance changes',
      () async {
        final harness = _PageHarness();
        addTearDown(harness.close);
        final response = harness.response(
          changes: [
            harness.productChange(seq: 41),
            harness.movementChange(seq: 42, delta: -3),
          ],
          nextCursor: 42,
        );

        await harness.pageApplier.applyPage(response);
        await harness.pageApplier.applyPage(response);

        expect(
          await harness.database.select(harness.database.products).get(),
          hasLength(1),
        );
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          hasLength(1),
        );
        expect(
          (await harness.database
                  .select(harness.database.productBalances)
                  .getSingle())
              .qty,
          -3,
        );
        expect(await harness.cursor(), 42);
      },
    );

    test(
      'rolls back all applied changes and the cursor when a later change fails',
      () async {
        final harness = _PageHarness();
        addTearDown(harness.close);
        await harness.setCursor(40);

        await expectLater(
          harness.pageApplier.applyPage(
            harness.response(
              changes: [
                harness.productChange(seq: 41),
                harness.movementChange(seq: 42, productId: _missingProductId),
              ],
              nextCursor: 42,
            ),
          ),
          throwsA(isA<SyncProtocolException>()),
        );

        expect(
          await harness.database.select(harness.database.products).get(),
          isEmpty,
        );
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          isEmpty,
        );
        expect(
          await harness.database.select(harness.database.productBalances).get(),
          isEmpty,
        );
        expect(await harness.cursor(), 40);
      },
    );

    test(
      'rolls back applied changes when persisting the cursor fails',
      () async {
        final harness = _PageHarness();
        addTearDown(harness.close);
        await harness.setCursor(40);
        await harness.database.customStatement(
          'CREATE TRIGGER sync_state_cursor_failure '
          'BEFORE UPDATE OF cursor ON sync_state BEGIN '
          "SELECT RAISE(ABORT, 'cursor write failed'); END",
        );

        await expectLater(
          harness.pageApplier.applyPage(
            harness.response(
              changes: [harness.productChange(seq: 41)],
              nextCursor: 41,
            ),
          ),
          throwsA(isA<Exception>()),
        );

        expect(
          await harness.database.select(harness.database.products).get(),
          isEmpty,
        );
        expect(await harness.cursor(), 40);
      },
    );

    test('an empty page preserves the server cursor contract', () async {
      final harness = _PageHarness();
      addTearDown(harness.close);
      await harness.setCursor(17);

      await harness.pageApplier.applyPage(
        harness.response(changes: const [], nextCursor: 17),
      );

      expect(await harness.cursor(), 17);
      expect(
        await harness.database.select(harness.database.products).get(),
        isEmpty,
      );
      expect(
        await harness.database.select(harness.database.stockMovements).get(),
        isEmpty,
      );
    });

    test(
      'rejects an incomplete page without changing the local replica',
      () async {
        final harness = _PageHarness();
        addTearDown(harness.close);
        await harness.setCursor(17);

        await expectLater(
          harness.pageApplier.applyPage(
            harness.response(
              changes: [harness.productChange(seq: 18)],
              nextCursor: 19,
            ),
          ),
          throwsA(isA<SyncProtocolException>()),
        );

        expect(await harness.cursor(), 17);
        expect(
          await harness.database.select(harness.database.products).get(),
          isEmpty,
        );

        await expectLater(
          harness.pageApplier.applyPage(
            harness.response(changes: const [], nextCursor: 18),
          ),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(await harness.cursor(), 17);
      },
    );

    test('persists the cursor across a database reopen', () async {
      final directory = await Directory.systemTemp.createTemp(
        'stoksync-sync-page-',
      );
      final path = '${directory.path}${Platform.pathSeparator}replica.sqlite';
      StokSyncDatabase? database;

      try {
        database = StokSyncDatabase(NativeDatabase(File(path)));
        final pageApplier = DriftSyncPageApplier(database);
        await pageApplier.applyPage(
          _PageHarness.responseFor(
            changes: [_PageHarness.productChangeFor(seq: 31)],
            nextCursor: 31,
          ),
        );
        expect(await DriftSyncCursorStore(database).readCursor(), 31);

        await database.close();
        database = null;

        database = StokSyncDatabase(NativeDatabase(File(path)));
        expect(await DriftSyncCursorStore(database).readCursor(), 31);
      } finally {
        await database?.close();
        await directory.delete(recursive: true);
      }
    });
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _productId = '0192e1aa-0000-7000-8000-000000000001';
const _movementId = '0192e1aa-0000-7000-8000-000000000002';
const _missingProductId = '0192e1aa-0000-7000-8000-000000000003';

final class _PageHarness {
  _PageHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()),
      now = DateTime.utc(2026, 9, 13, 10, 2, 14) {
    remoteChangeApplier = DriftRemoteChangeApplier(database, clock: () => now);
    pageApplier = DriftSyncPageApplier(
      database,
      remoteChangeApplier: remoteChangeApplier,
    );
  }

  final StokSyncDatabase database;
  final DateTime now;
  late final DriftRemoteChangeApplier remoteChangeApplier;
  late final DriftSyncPageApplier pageApplier;

  SyncResponse response({
    required List<SyncChangeEntry> changes,
    required int nextCursor,
    bool hasMore = false,
  }) {
    return SyncResponse(
      results: const [],
      changes: changes,
      nextCursor: nextCursor,
      hasMore: hasMore,
      serverTime: now,
    );
  }

  SyncChangeEntry productChange({
    int seq = 1,
    String id = _productId,
    String name = 'Remote product',
  }) {
    return SyncChangeEntry(
      seq: seq,
      entity: 'product',
      operation: 'upsert',
      data: _productData(id: id, name: name, timestamp: now),
      createdAt: now,
    );
  }

  SyncChangeEntry movementChange({
    int seq = 2,
    String id = _movementId,
    String productId = _productId,
    int delta = 2,
  }) {
    return SyncChangeEntry(
      seq: seq,
      entity: 'stock_movement',
      operation: 'upsert',
      data: <String, Object?>{
        'id': id,
        'product_id': productId,
        'delta': delta,
        'kind': 'receive',
        'note': null,
        'occurred_at': now.toIso8601String(),
        'raw_occurred_at': now.toIso8601String(),
        'clock_offset_ms': 0,
        'counted_qty': null,
        'reverses_id': null,
        'device_id': _deviceId,
        'server_created_at': now.toIso8601String(),
      },
      createdAt: now,
    );
  }

  Future<void> setCursor(int cursor) async {
    await (database.update(database.syncState)
          ..where((row) => row.id.equals(1)))
        .write(SyncStateCompanion(cursor: Value(cursor)));
  }

  Future<int> cursor() async {
    return DriftSyncCursorStore(database).readCursor();
  }

  Future<void> close() => database.close();

  static SyncResponse responseFor({
    required List<SyncChangeEntry> changes,
    required int nextCursor,
  }) {
    return SyncResponse(
      results: const [],
      changes: changes,
      nextCursor: nextCursor,
      hasMore: false,
      serverTime: DateTime.utc(2026, 9, 13, 10, 2, 14),
    );
  }

  static SyncChangeEntry productChangeFor({required int seq}) {
    final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
    return SyncChangeEntry(
      seq: seq,
      entity: 'product',
      operation: 'upsert',
      data: _productData(
        id: _productId,
        name: 'Restart-visible product',
        timestamp: now,
      ),
      createdAt: now,
    );
  }
}

Map<String, Object?> _productData({
  required String id,
  required String name,
  required DateTime timestamp,
}) {
  return <String, Object?>{
    'id': id,
    'barcode': null,
    'sku': null,
    'name': name,
    'description': null,
    'unit': 'pcs',
    'category': null,
    'min_stock': null,
    'version': 1,
    'updated_at': timestamp.toIso8601String(),
    'updated_by_device_id': _deviceId,
    'deleted_at': null,
    'created_at': timestamp.toIso8601String(),
  };
}
