import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/data/local/conflict_resolution_repository.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

void main() {
  test(
    'queues an explicit local follow-up and preserves the original conflict',
    () async {
      final harness = _ConflictResolutionHarness();
      addTearDown(harness.close);
      final conflict = await harness.seedVersionConflict();

      final result = await harness.repository.resolveProduct(
        conflict: conflict,
        resolution: ProductConflictResolution.useLocal,
      );

      final conflicts = await harness.database
          .select(harness.database.conflicts)
          .get();
      final operations = await (harness.database.select(
        harness.database.pendingOperations,
      )..orderBy([(row) => OrderingTerm.asc(row.localSeq)])).get();
      final product = await (harness.database.select(
        harness.database.products,
      )..where((row) => row.id.equals(_productId))).getSingle();

      expect(result.operationId, _followUpOperationId);
      expect(result.localSequence, 2);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.opId, _originalOperationId);
      expect(conflicts.single.resolutionStatus, 'resolved');
      expect(operations, hasLength(2));
      expect(operations[0].opId, _originalOperationId);
      expect(operations[0].status, 'blocked');
      expect(operations[1].opId, _followUpOperationId);
      expect(operations[1].status, 'queued');
      expect(operations[1].baseVersion, 2);
      expect(jsonDecode(operations[1].payload), {
        'id': _productId,
        'name': 'Local name',
        'unit': 'pcs',
        'min_stock': 8,
      });
      expect(product.name, 'Local name');
      expect(product.version, 3);
      expect(product.syncStatus, 'pending');
    },
  );

  test('barcode resolution retries without the conflicting barcode', () async {
    final harness = _ConflictResolutionHarness();
    addTearDown(harness.close);
    final conflict = await harness.seedBarcodeConflict();

    await harness.repository.resolveProduct(
      conflict: conflict,
      resolution: ProductConflictResolution.removeConflictingBarcode,
    );

    final operation = (await (harness.database.select(
      harness.database.pendingOperations,
    )..where((row) => row.opId.equals(_followUpOperationId))).getSingle());
    expect(jsonDecode(operation.payload), {
      'id': _productId,
      'name': 'New product',
      'unit': 'pcs',
      'min_stock': 2,
      'barcode': null,
    });
    expect(operation.baseVersion, isNull);
    expect(
      (await (harness.database.select(
            harness.database.conflicts,
          )..where((row) => row.opId.equals(_originalOperationId))).getSingle())
          .resolutionStatus,
      'resolved',
    );
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _productId = '0192e1aa-0000-7000-8000-000000000001';
const _originalOperationId = '0192f3a1-0000-7000-8000-000000000001';
const _followUpOperationId = '0192f3a1-0000-7000-8000-000000000002';

final class _ConflictResolutionHarness {
  _ConflictResolutionHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()),
      deviceIdentity = DeviceIdentity(
        secureStore: _MemorySecureStore(),
        identifierGenerator: _QueueIdentifierGenerator([_deviceId]),
      ) {
    repository = LocalConflictResolutionRepository(
      database: database,
      identifierGenerator: _QueueIdentifierGenerator([_followUpOperationId]),
      deviceIdentity: deviceIdentity,
      clock: () => DateTime.utc(2026, 9, 13, 10, 5),
    );
  }

  final StokSyncDatabase database;
  final DeviceIdentity deviceIdentity;
  late final LocalConflictResolutionRepository repository;

  Future<Conflict> seedVersionConflict() async {
    await _insertProduct(name: 'Server name');
    await _insertPending(
      baseVersion: 1,
      basePayload: '{"id":"$_productId","name":"Base name","unit":"pcs"}',
      payload:
          '{"id":"$_productId","name":"Local name","unit":"pcs","min_stock":8}',
    );
    return _insertConflict(
      localPayload:
          '{"id":"$_productId","name":"Local name","unit":"pcs","min_stock":8}',
      basePayload: '{"id":"$_productId","name":"Base name","unit":"pcs"}',
      serverPayload:
          '{"id":"$_productId","name":"Server name","unit":"pcs","version":2,"deleted_at":null}',
      reason: 'version_conflict',
    );
  }

  Future<Conflict> seedBarcodeConflict() async {
    await _insertProduct(name: 'New product', barcode: '123');
    await _insertPending(
      payload:
          '{"id":"$_productId","name":"New product","unit":"pcs","min_stock":2,"barcode":"123"}',
    );
    return _insertConflict(
      localPayload:
          '{"id":"$_productId","name":"New product","unit":"pcs","min_stock":2,"barcode":"123"}',
      serverPayload:
          '{"id":"0192e1aa-0000-7000-8000-000000000009","name":"Owner","version":1}',
      reason: 'barcode_conflict',
    );
  }

  Future<void> _insertProduct({required String name, String? barcode}) async {
    await database
        .into(database.products)
        .insert(
          ProductsCompanion.insert(
            id: _productId,
            name: name,
            barcode: Value(barcode),
            updatedBy: _deviceId,
            version: const Value(1),
          ),
        );
    await database
        .into(database.productBalances)
        .insert(ProductBalancesCompanion.insert(productId: _productId));
  }

  Future<void> _insertPending({
    int? baseVersion,
    String? basePayload,
    required String payload,
  }) {
    return database
        .into(database.pendingOperations)
        .insert(
          PendingOperationsCompanion.insert(
            opId: _originalOperationId,
            localSeq: 1,
            entity: 'product',
            entityId: _productId,
            operation: 'upsert_product',
            payload: payload,
            basePayload: Value(basePayload),
            baseVersion: Value(baseVersion),
            status: const Value('blocked'),
          ),
        );
  }

  Future<Conflict> _insertConflict({
    required String localPayload,
    String? basePayload,
    required String serverPayload,
    required String reason,
  }) async {
    await database
        .into(database.conflicts)
        .insert(
          ConflictsCompanion.insert(
            opId: _originalOperationId,
            entity: 'product',
            entityId: _productId,
            localPayload: localPayload,
            basePayload: Value(basePayload),
            serverPayload: Value(serverPayload),
            reason: reason,
            createdAt: Value(DateTime.utc(2026, 9, 13, 10, 4)),
          ),
        );
    return (await (database.select(
      database.conflicts,
    )..where((row) => row.opId.equals(_originalOperationId))).getSingle());
  }

  Future<void> close() => database.close();
}

final class _QueueIdentifierGenerator implements IdentifierGenerator {
  _QueueIdentifierGenerator(this._identifiers);

  final List<String> _identifiers;

  @override
  String generate() {
    if (_identifiers.isEmpty) {
      throw StateError('No test identifiers remain.');
    }
    return _identifiers.removeAt(0);
  }
}

final class _MemorySecureStore implements SecureKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) => Future.value(value);

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }
}
