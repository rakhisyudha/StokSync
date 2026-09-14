import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/data/local/conflict_resolution_repository.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_page_applier.dart';
import 'package:stoksync/data/local/sync_response_applier.dart';
import 'package:stoksync/data/local/sync_response_reconciler.dart';
import 'package:stoksync/data/local/sync_state_store.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  test(
    'task 6.2 converges seeded replicas through deterministic faults',
    () async {
      const seed = 20260913;
      final clock = _HarnessClock(DateTime.utc(2026, 9, 13, 10, 2));
      final server = _DeterministicServer(clock);
      final network = _DeterministicNetwork(server);
      final deviceA = await _Replica.create(
        name: 'device-a',
        deviceId: _deviceAId,
        network: network,
        clock: clock,
        identifierSalt: 0x101,
      );
      final deviceB = await _Replica.create(
        name: 'device-b',
        deviceId: _deviceBId,
        network: network,
        clock: clock,
        identifierSalt: 0x202,
      );
      addTearDown(() async {
        await Future.wait([deviceA.close(), deviceB.close()]);
      });

      final productA = await deviceA.products.create(
        const ProductDraft(name: 'Seeded shared product', minStock: 2),
      );
      final productB = await deviceA.products.create(
        const ProductDraft(name: 'Seeded tombstone product'),
      );
      await _drain(deviceA, clock);
      await _drain(deviceB, clock);

      expect(
        server.productIds,
        containsAll([productA.productId, productB.productId]),
      );
      expect(await _cursor(deviceB), server.cursor);

      // Both devices edit the same field from version 1 while offline. The
      // first request wins; the second retains a visible conflict rather than
      // silently overwriting the canonical value.
      await deviceA.products.update(
        productId: productA.productId,
        draft: const ProductDraft(name: 'Canonical first edit', minStock: 2),
      );
      await deviceB.products.update(
        productId: productA.productId,
        draft: const ProductDraft(name: 'Rejected competing edit', minStock: 2),
      );
      await _drain(deviceA, clock);
      await _drain(deviceB, clock);

      var conflicts = await deviceB.database
          .select(deviceB.database.conflicts)
          .get();
      expect(conflicts, hasLength(1));
      expect(conflicts.single.reason, 'version_conflict');
      expect(conflicts.single.resolutionStatus, 'unresolved');

      // Resolve the retained conflict through the explicit local follow-up
      // operation. This proves the conflict remains auditable while the active
      // product row eventually rejoins the canonical replica.
      await deviceB.conflicts.resolveProduct(
        conflict: conflicts.single,
        resolution: ProductConflictResolution.useServer,
      );
      await _drain(deviceB, clock);
      await _drain(deviceA, clock);
      conflicts = await deviceB.database
          .select(deviceB.database.conflicts)
          .get();
      expect(conflicts.single.resolutionStatus, 'resolved');

      // Tombstones are retained and propagated independently of movements.
      await deviceA.products.softDelete(productB.productId);
      await _drain(deviceA, clock);
      await _drain(deviceB, clock);

      // The first two fault rounds cover a request that never reaches the server,
      // a committed request whose response is dropped, duplicate delivery, and
      // a committed request that times out. Retries use the same operation IDs.
      deviceA.transport.addFaults(const [
        _Fault.dropRequest,
        _Fault.duplicateRequest,
        _Fault.dropResponse,
      ]);
      deviceB.transport.addFaults(const [_Fault.timeoutAfterCommit]);

      final random = Random(seed);
      for (var round = 0; round < 16; round++) {
        final first = await _recordRandomMovement(
          deviceA,
          productA.productId,
          random,
          round,
        );
        final second = await _recordRandomMovement(
          deviceB,
          productA.productId,
          random,
          round + 100,
        );

        // Once both replicas have queued work, deliver one pair in reverse
        // request order and complete the responses in reverse arrival order.
        // This is intentionally independent of the server's idempotency map.
        if (round == 3) {
          network.reorderNextPair();
        }
        await _syncBothIgnoringFailures(deviceA, deviceB);
        await _drain(deviceA, clock);
        await _drain(deviceB, clock);

        expect(first.movementId, isNotEmpty);
        expect(second.movementId, isNotEmpty);
      }

      await _drain(deviceA, clock);
      await _drain(deviceB, clock);
      expect(network.requestDrops, greaterThanOrEqualTo(1));
      expect(network.responseDrops, greaterThanOrEqualTo(1));
      expect(network.duplicateRequests, greaterThanOrEqualTo(1));
      expect(network.timeouts, greaterThanOrEqualTo(1));
      expect(network.requestReorders, greaterThanOrEqualTo(1));
      expect(network.responseReorders, greaterThanOrEqualTo(1));

      final expectedMovementIds = server.movementIds;
      final expectedBalance = server.ledgerBalance(productA.productId);
      await _assertReplica(
        deviceA,
        server: server,
        productId: productA.productId,
        expectedMovementIds: expectedMovementIds,
        expectedBalance: expectedBalance,
        expectedTombstoneId: productB.productId,
        expectedConflictCount: 0,
      );
      await _assertReplica(
        deviceB,
        server: server,
        productId: productA.productId,
        expectedMovementIds: expectedMovementIds,
        expectedBalance: expectedBalance,
        expectedTombstoneId: productB.productId,
        expectedConflictCount: 1,
      );

      // The server projection is checked against its immutable ledger, not only
      // against the projection value returned by the protocol response.
      expect(server.balanceProjection, {
        productA.productId: expectedBalance,
        productB.productId: 0,
      });
      expect(server.cursor, greaterThan(0));
    },
  );
}

const _deviceAId = '0192f200-0000-7000-8000-0000000000a1';
const _deviceBId = '0192f200-0000-7000-8000-0000000000b2';

final class _HarnessClock {
  _HarnessClock(this.current);

  DateTime current;

  DateTime now() => current.toUtc();

  void advance(Duration duration) {
    current = current.add(duration);
  }
}

final class _Replica {
  _Replica({
    required this.name,
    required this.database,
    required this.products,
    required this.movements,
    required this.conflicts,
    required this.transport,
    required this.engine,
  });

  final String name;
  final StokSyncDatabase database;
  final LocalProductRepository products;
  final LocalStockMovementRepository movements;
  final LocalConflictResolutionRepository conflicts;
  final _FaultTransport transport;
  final SyncEngine engine;

  static Future<_Replica> create({
    required String name,
    required String deviceId,
    required _DeterministicNetwork network,
    required _HarnessClock clock,
    required int identifierSalt,
  }) async {
    final database = StokSyncDatabase(NativeDatabase.memory());
    final identifierGenerator = _DeterministicIdentifierGenerator(
      identifierSalt,
    );
    final identity = DeviceIdentity(
      secureStore: _MemoryDeviceValues(deviceId),
      identifierGenerator: _ConstantIdentifierGenerator(deviceId),
    );
    final transport = _FaultTransport(deviceId: deviceId, network: network);
    final engine = SyncEngine(
      transport: transport,
      pendingOperations: PendingOperationDao(database),
      cursorStore: DriftSyncCursorStore(database),
      deviceId: deviceId,
      now: clock.now,
      maxOperations: 4,
      maxChanges: 3,
      backoff: SyncBackoffPolicy(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 8),
        jitterRatio: 0,
      ),
      onResponse: DriftSyncResponseApplier(
        responseReconciler: DriftSyncResponseReconciler(
          database,
          clock: clock.now,
          identifierGenerator: identifierGenerator,
        ),
        pageApplier: DriftSyncPageApplier(database),
      ).call,
      statusStore: DriftSyncStatusStore(database),
    );
    return _Replica(
      name: name,
      database: database,
      products: LocalProductRepository(
        database: database,
        identifierGenerator: identifierGenerator,
        deviceIdentity: identity,
        clock: clock.now,
      ),
      movements: LocalStockMovementRepository(
        database: database,
        identifierGenerator: identifierGenerator,
        deviceIdentity: identity,
        clock: clock.now,
      ),
      conflicts: LocalConflictResolutionRepository(
        database: database,
        identifierGenerator: identifierGenerator,
        deviceIdentity: identity,
        clock: clock.now,
      ),
      transport: transport,
      engine: engine,
    );
  }

  Future<void> close() => database.close();
}

final class _FaultTransport implements SyncTransport {
  _FaultTransport({required this.deviceId, required this.network});

  final String deviceId;
  final _DeterministicNetwork network;
  final Queue<_Fault> _faults = Queue<_Fault>();

  void addFaults(Iterable<_Fault> faults) {
    _faults.addAll(faults);
  }

  @override
  Future<SyncResponse> synchronize(SyncRequest request) async {
    if (request.deviceId != deviceId) {
      throw StateError('transport received a request for another device');
    }
    final fault = _faults.isEmpty ? _Fault.none : _faults.removeFirst();
    if (fault == _Fault.dropRequest) {
      network.requestDrops++;
      throw const SyncNetworkException();
    }

    final response = await network.exchange(request);
    if (fault == _Fault.duplicateRequest) {
      network.duplicateRequests++;
      // The second delivery is deliberately discarded. The server must replay
      // the original outcome without appending a second ledger row.
      await network.exchange(request);
    }
    if (fault == _Fault.dropResponse) {
      network.responseDrops++;
      throw const SyncNetworkException();
    }
    if (fault == _Fault.timeoutAfterCommit) {
      network.timeouts++;
      throw const SyncNetworkException();
    }
    return response;
  }
}

enum _Fault {
  none,
  dropRequest,
  dropResponse,
  duplicateRequest,
  timeoutAfterCommit,
}

final class _DeterministicNetwork {
  _DeterministicNetwork(this.server);

  final _DeterministicServer server;
  _PendingNetworkCall? _waitingForReorderedPair;
  bool _reorderPair = false;
  int requestDrops = 0;
  int responseDrops = 0;
  int duplicateRequests = 0;
  int timeouts = 0;
  int requestReorders = 0;
  int responseReorders = 0;

  void reorderNextPair() {
    if (_waitingForReorderedPair != null) {
      throw StateError('cannot schedule a reordered pair while one is pending');
    }
    _reorderPair = true;
  }

  Future<SyncResponse> exchange(SyncRequest request) {
    if (!_reorderPair) {
      return Future<SyncResponse>.value(server.handle(request));
    }

    final call = _PendingNetworkCall(request);
    final waiting = _waitingForReorderedPair;
    if (waiting == null) {
      _waitingForReorderedPair = call;
      return call.completer.future;
    }

    _waitingForReorderedPair = null;
    _reorderPair = false;
    requestReorders++;
    final first = waiting;
    final second = call;
    try {
      // The second request is committed first, then the first request. This
      // models request reordering while preserving independent transactions.
      final secondResponse = server.handle(second.request);
      final firstResponse = server.handle(first.request);
      responseReorders++;
      // Complete the second response first to model response arrival reorder.
      second.completer.complete(secondResponse);
      first.completer.complete(firstResponse);
    } on Object catch (error, stackTrace) {
      first.completer.completeError(error, stackTrace);
      second.completer.completeError(error, stackTrace);
    }
    return call.completer.future;
  }
}

final class _PendingNetworkCall {
  _PendingNetworkCall(this.request);

  final SyncRequest request;
  final Completer<SyncResponse> completer = Completer<SyncResponse>();
}

final class _DeterministicServer {
  _DeterministicServer(this.clock);

  final _HarnessClock clock;
  final Map<String, Map<String, Object?>> products =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> movements =
      <String, Map<String, Object?>>{};
  final Map<String, int> movementSequences = <String, int>{};
  final Map<String, int> balanceProjection = <String, int>{};
  final Map<String, SyncOperationResult> _idempotency =
      <String, SyncOperationResult>{};
  final List<_ServerChange> _changes = <_ServerChange>[];
  int cursor = 0;

  Set<String> get productIds => products.keys.toSet();

  Set<String> get movementIds => movements.keys.toSet();

  int ledgerBalance(String productId) => movements.values
      .where((movement) => movement['product_id'] == productId)
      .fold<int>(0, (sum, movement) => sum + (movement['delta']! as int));

  SyncResponse handle(SyncRequest request) {
    final results = <SyncOperationResult>[];
    for (final operation in request.operations) {
      final key = '${request.deviceId}:${operation.opId}';
      final existing = _idempotency[key];
      final result = existing ?? _apply(request, operation);
      _idempotency[key] = result;
      results.add(result);
    }

    final available = _changes
        .where((change) => change.seq > request.cursor)
        .toList();
    final page = available.take(request.maxChanges).toList(growable: false);
    final nextCursor = page.isEmpty ? request.cursor : page.last.seq;
    return SyncResponse(
      results: results,
      changes: page.map((change) => change.toWire()).toList(growable: false),
      nextCursor: nextCursor,
      hasMore: available.length > page.length,
      serverTime: clock.now(),
    );
  }

  SyncOperationResult _apply(SyncRequest request, SyncOperation operation) {
    switch (operation.kind) {
      case SyncOperationKind.upsertProduct:
        return _applyProduct(request, operation);
      case SyncOperationKind.deleteProduct:
        return _applyDelete(request, operation);
      case SyncOperationKind.addMovement:
        return _applyMovement(request, operation);
    }
  }

  SyncOperationResult _applyProduct(
    SyncRequest request,
    SyncOperation operation,
  ) {
    final payload = operation.payload as UpsertProductPayload;
    final existing = products[payload.id];
    if (existing != null && existing['deleted_at'] != null) {
      return _rejected(operation, 'product_deleted', existing);
    }
    if (existing != null && operation.baseVersion != existing['version']) {
      return _rejected(operation, 'version_conflict', existing);
    }
    final barcodeOwner = products.values.firstWhere(
      (product) =>
          product['id'] != payload.id &&
          product['deleted_at'] == null &&
          payload.barcode != null &&
          product['barcode'] == payload.barcode,
      orElse: () => <String, Object?>{},
    );
    if (barcodeOwner.isNotEmpty) {
      return _rejected(operation, 'barcode_conflict', barcodeOwner);
    }

    final now = _iso(clock.now());
    final version = existing == null ? 1 : (existing['version']! as int) + 1;
    final product = <String, Object?>{
      'id': payload.id,
      'barcode': payload.barcode,
      'sku': payload.sku,
      'name': payload.name,
      'description': payload.description,
      'unit': payload.unit ?? 'pcs',
      'category': payload.category,
      'min_stock': payload.minStock,
      'version': version,
      'updated_at': now,
      'updated_by_device_id': request.deviceId,
      'deleted_at': null,
      'created_at': existing?['created_at'] ?? now,
    };
    products[payload.id] = product;
    balanceProjection.putIfAbsent(payload.id, () => 0);
    return _appendApplied(
      operation,
      entity: 'product',
      changeOperation: 'upsert',
      entityId: payload.id,
      data: product,
    );
  }

  SyncOperationResult _applyDelete(
    SyncRequest request,
    SyncOperation operation,
  ) {
    final payload = operation.payload as DeleteProductPayload;
    final existing = products[payload.id];
    if (existing == null) {
      return _rejected(operation, 'product_not_found', null);
    }
    if (existing['deleted_at'] != null) {
      return _rejected(operation, 'product_deleted', existing);
    }
    if (operation.baseVersion != existing['version']) {
      return _rejected(operation, 'version_conflict', existing);
    }
    final deleted = Map<String, Object?>.from(existing)
      ..['version'] = (existing['version']! as int) + 1
      ..['updated_at'] = _iso(clock.now())
      ..['updated_by_device_id'] = request.deviceId
      ..['deleted_at'] = _iso(payload.deletedAt ?? clock.now());
    products[payload.id] = deleted;
    return _appendApplied(
      operation,
      entity: 'product',
      changeOperation: 'delete',
      entityId: payload.id,
      data: deleted,
    );
  }

  SyncOperationResult _applyMovement(
    SyncRequest request,
    SyncOperation operation,
  ) {
    final payload = operation.payload as AddMovementPayload;
    final product = products[payload.productId];
    if (product == null) {
      return _rejected(operation, 'product_not_found', null);
    }
    if (product['deleted_at'] != null) {
      return _rejected(operation, 'product_deleted', product);
    }
    final priorSequence = movementSequences[payload.id];
    if (priorSequence != null) {
      return SyncOperationResult(
        opId: operation.opId,
        status: SyncOperationResultStatus.applied,
        seq: priorSequence,
      );
    }

    var delta = payload.delta;
    if (payload.kind == 'stocktake' && payload.countedQty != null) {
      delta = payload.countedQty! - (balanceProjection[payload.productId] ?? 0);
      if (delta == 0) {
        return _rejected(operation, 'invalid_stocktake', null);
      }
    }
    if (delta == 0) {
      return _rejected(operation, 'invalid_delta', null);
    }
    if (payload.reversesId != null &&
        !movements.containsKey(payload.reversesId)) {
      return _rejected(operation, 'movement_not_found', null);
    }

    final movement = <String, Object?>{
      'id': payload.id,
      'product_id': payload.productId,
      'delta': delta,
      'kind': payload.kind,
      'note': payload.note,
      'occurred_at': _iso(payload.occurredAt),
      'raw_occurred_at': _iso(payload.rawOccurredAt ?? payload.occurredAt),
      'clock_offset_ms': payload.clockOffsetMs,
      'counted_qty': payload.countedQty,
      'reverses_id': payload.reversesId,
      'device_id': request.deviceId,
      'server_created_at': _iso(clock.now()),
    };
    movements[payload.id] = movement;
    balanceProjection[payload.productId] =
        (balanceProjection[payload.productId] ?? 0) + delta;
    final result = _appendApplied(
      operation,
      entity: 'stock_movement',
      changeOperation: 'upsert',
      entityId: payload.id,
      data: movement,
    );
    movementSequences[payload.id] = result.seq!;
    return result;
  }

  SyncOperationResult _appendApplied(
    SyncOperation operation, {
    required String entity,
    required String changeOperation,
    required String entityId,
    required Map<String, Object?> data,
  }) {
    final sequence = ++cursor;
    _changes.add(
      _ServerChange(
        seq: sequence,
        entity: entity,
        operation: changeOperation,
        data: Map<String, Object?>.from(data),
      ),
    );
    return SyncOperationResult(
      opId: operation.opId,
      status: SyncOperationResultStatus.applied,
      seq: sequence,
    );
  }

  SyncOperationResult _rejected(
    SyncOperation operation,
    String reason,
    Map<String, Object?>? state,
  ) {
    return SyncOperationResult(
      opId: operation.opId,
      status: SyncOperationResultStatus.rejected,
      reason: reason,
      serverState: state == null ? null : Map<String, Object?>.from(state),
    );
  }
}

final class _ServerChange {
  const _ServerChange({
    required this.seq,
    required this.entity,
    required this.operation,
    required this.data,
  });

  final int seq;
  final String entity;
  final String operation;
  final Map<String, Object?> data;

  SyncChangeEntry toWire() => SyncChangeEntry(
    seq: seq,
    entity: entity,
    operation: operation,
    data: Map<String, Object?>.from(data),
  );
}

Future<MovementMutationResult> _recordRandomMovement(
  _Replica replica,
  String productId,
  Random random,
  int timingOffset,
) {
  final kind = random.nextInt(3);
  final quantity = random.nextInt(5) + 1;
  final timing = MovementTiming(
    occurredAt: DateTime.utc(
      2026,
      9,
      13,
      10,
      3,
    ).add(Duration(minutes: timingOffset)),
    rawOccurredAt: DateTime.utc(
      2026,
      9,
      13,
      10,
      3,
    ).add(Duration(minutes: timingOffset)),
  );
  return switch (kind) {
    0 => replica.movements.receive(
      productId: productId,
      quantity: quantity,
      note: 'seeded receive $timingOffset',
      timing: timing,
    ),
    1 => replica.movements.issue(
      productId: productId,
      quantity: quantity,
      note: 'seeded issue $timingOffset',
      timing: timing,
    ),
    _ => replica.movements.adjust(
      productId: productId,
      delta: random.nextBool() ? quantity : -quantity,
      note: 'seeded adjust $timingOffset',
      timing: timing,
    ),
  };
}

Future<void> _syncBothIgnoringFailures(_Replica first, _Replica second) async {
  await Future.wait([_ignoreSyncFailure(first), _ignoreSyncFailure(second)]);
}

Future<void> _ignoreSyncFailure(_Replica replica) async {
  try {
    await replica.engine.synchronize();
  } on Object {
    // Faults are intentional. _drain advances the deterministic clock and
    // retries the same durable queue rows below.
  }
}

Future<void> _drain(_Replica replica, _HarnessClock clock) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    final pending = await replica.database
        .select(replica.database.pendingOperations)
        .get();
    final eligible = pending.any(
      (row) => const ['queued', 'retrying', 'inflight'].contains(row.status),
    );
    if (!eligible) {
      try {
        await replica.engine.synchronize();
      } on Object {
        // A pull may also be faulted; the next iteration retries it.
      }
      final afterPull = await replica.database
          .select(replica.database.pendingOperations)
          .get();
      if (!afterPull.any(
        (row) => const ['queued', 'retrying', 'inflight'].contains(row.status),
      )) {
        return;
      }
    } else {
      try {
        await replica.engine.synchronize();
      } on Object {
        // Retryable transport failures are expected in this harness.
      }
    }
    clock.advance(const Duration(seconds: 2));
  }
  final remaining = await replica.database
      .select(replica.database.pendingOperations)
      .get();
  fail('${replica.name} did not drain: $remaining');
}

Future<int> _cursor(_Replica replica) =>
    DriftSyncCursorStore(replica.database).readCursor();

Future<void> _assertReplica(
  _Replica replica, {
  required _DeterministicServer server,
  required String productId,
  required Set<String> expectedMovementIds,
  required int expectedBalance,
  required String expectedTombstoneId,
  required int expectedConflictCount,
}) async {
  final products = await replica.database
      .select(replica.database.products)
      .get();
  final movements = await replica.database
      .select(replica.database.stockMovements)
      .get();
  final balances = await replica.database
      .select(replica.database.productBalances)
      .get();
  final pending = await replica.database
      .select(replica.database.pendingOperations)
      .get();
  final conflicts = await replica.database
      .select(replica.database.conflicts)
      .get();

  expect(products.map((row) => row.id).toSet(), server.productIds);
  expect(
    products.singleWhere((row) => row.id == expectedTombstoneId).deletedAt,
    isNotNull,
  );
  expect(
    products.singleWhere((row) => row.id == expectedTombstoneId).syncStatus,
    'synced',
  );
  final shared = products.singleWhere((row) => row.id == productId);
  expect(shared.name, server.products[productId]!['name']);
  expect(shared.version, server.products[productId]!['version']);
  expect(shared.syncStatus, 'synced');

  expect(movements.map((row) => row.id).toSet(), expectedMovementIds);
  expect(
    movements.fold<int>(0, (sum, movement) => sum + movement.delta),
    expectedBalance,
  );
  final projected = balances.singleWhere((row) => row.productId == productId);
  expect(projected.qty, expectedBalance);
  expect(
    balances.singleWhere((row) => row.productId == expectedTombstoneId).qty,
    0,
  );
  expect(
    conflicts.where((conflict) => conflict.reason == 'version_conflict'),
    hasLength(expectedConflictCount),
  );
  if (expectedConflictCount == 1) {
    expect(conflicts.single.resolutionStatus, 'resolved');
  }
  expect(
    pending.where(
      (row) => const ['queued', 'retrying', 'inflight'].contains(row.status),
    ),
    isEmpty,
  );
  expect(await _cursor(replica), server.cursor);
}

final class _DeterministicIdentifierGenerator implements IdentifierGenerator {
  _DeterministicIdentifierGenerator(this.salt);

  final int salt;
  int counter = 0;

  @override
  String generate() {
    counter++;
    final suffix = ((salt << 36) + counter).toRadixString(16).padLeft(12, '0');
    return '0192f200-0000-7000-8000-$suffix';
  }
}

final class _ConstantIdentifierGenerator implements IdentifierGenerator {
  _ConstantIdentifierGenerator(this.value);

  final String value;

  @override
  String generate() => value;
}

final class _MemoryDeviceValues implements SecureKeyValueStore {
  _MemoryDeviceValues(this.value);

  final String value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write({required String key, required String value}) async {}
}

String _iso(DateTime value) => value.toUtc().toIso8601String();
