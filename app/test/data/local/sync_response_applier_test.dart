import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_page_applier.dart';
import 'package:stoksync/data/local/sync_response_applier.dart';
import 'package:stoksync/data/local/sync_response_reconciler.dart';
import 'package:stoksync/data/local/sync_state_store.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  test(
    'reconciles push results before applying the complete page and cursor',
    () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14, 987654);

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
          .insert(ProductBalancesCompanion.insert(productId: _productId));
      await database
          .into(database.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              opId: _operationId,
              localSeq: 1,
              entity: 'product',
              entityId: _productId,
              operation: 'upsert_product',
              payload: _payload,
              status: const Value('inflight'),
            ),
          );

      final pending = PendingSyncOperation(
        opId: _operationId,
        localSeq: 1,
        entity: 'product',
        entityId: _productId,
        operation: 'upsert_product',
        payload: _payload,
        baseVersion: null,
        attempts: 0,
        nextAttemptAt: now,
        lastError: null,
        status: PendingSyncOperationStatus.inflight,
      );
      final applier = DriftSyncResponseApplier(
        responseReconciler: DriftSyncResponseReconciler(
          database,
          clock: () => now,
        ),
        pageApplier: DriftSyncPageApplier(database),
      );

      await applier(
        SyncResponse(
          results: const [
            SyncOperationResult(
              opId: _operationId,
              status: SyncOperationResultStatus.applied,
              seq: 1,
            ),
          ],
          changes: [
            SyncChangeEntry(
              seq: 1,
              entity: 'product',
              operation: 'upsert',
              data: <String, Object?>{
                'id': _productId,
                'barcode': null,
                'sku': null,
                'name': 'Canonical product',
                'description': null,
                'unit': 'pcs',
                'category': null,
                'min_stock': null,
                'version': 1,
                'updated_at': now.toIso8601String(),
                'updated_by_device_id': _deviceId,
                'deleted_at': null,
                'created_at': now.toIso8601String(),
              },
              createdAt: now,
            ),
          ],
          nextCursor: 1,
          hasMore: false,
          serverTime: now,
        ),
        [pending],
      );

      final product = await database.select(database.products).getSingle();
      expect(product.name, 'Canonical product');
      expect(product.syncStatus, 'synced');
      expect(await database.select(database.pendingOperations).get(), isEmpty);
      expect(await DriftSyncCursorStore(database).readCursor(), 1);
    },
  );
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _productId = '0192e1aa-0000-7000-8000-000000000001';
const _operationId = '0192f3a1-0000-7000-8000-000000000001';
const _payload = '{"id":"$_productId","name":"Local product"}';
