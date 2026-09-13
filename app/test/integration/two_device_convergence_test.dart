import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/data/local/sync_state_store.dart';
import 'package:stoksync/data/remote/auth_client.dart';
import 'package:stoksync/data/remote/sync_session_store.dart';
import 'package:stoksync/features/sync/sync_runtime_composition.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  final apiBaseUri = Platform.environment['STOKSYNC_TEST_API_BASE_URI']?.trim();
  final databaseUrl = Platform.environment['STOKSYNC_TEST_DATABASE_URL']
      ?.trim();
  final liveTestSkip =
      apiBaseUri == null ||
          apiBaseUri.isEmpty ||
          databaseUrl == null ||
          databaseUrl.isEmpty
      ? 'set STOKSYNC_TEST_API_BASE_URI and STOKSYNC_TEST_DATABASE_URL '
            'after starting the migrated PostgreSQL-backed API'
      : null;

  test(
    'converges two independent replicas through the authenticated runtime',
    () async {
      final baseUri = Uri.parse(apiBaseUri!);
      final harness = await _TwoDeviceHarness.create(baseUri);
      addTearDown(harness.close);

      // Product creation is local-only first. The second device learns the
      // product through the real authenticated pull before it goes offline.
      final product = await harness.deviceA.products.create(
        ProductDraft(
          name: 'Offline shared product',
          barcode: 'integration-shared-$_productId',
          minStock: 1,
        ),
      );
      expect(await harness.pendingCount(harness.deviceA), 1);
      await harness.synchronize(harness.deviceA);
      await harness.synchronize(harness.deviceB);
      expect(
        await harness.product(harness.deviceB, product.productId),
        isNotNull,
      );

      // Both devices now work offline and append independent ledger entries.
      // Device B synchronizes first. Its first apply is interrupted after the
      // server has committed the operation, before the local cursor advances.
      final issueA = await harness.deviceA.movements.issue(
        productId: product.productId,
        quantity: 3,
        note: 'device A offline issue',
        timing: MovementTiming(
          occurredAt: DateTime.utc(2026, 9, 13, 10, 3),
          rawOccurredAt: DateTime.utc(2026, 9, 13, 10, 3),
        ),
      );
      final issueB = await harness.deviceB.movements.issue(
        productId: product.productId,
        quantity: 2,
        note: 'device B offline issue',
        timing: MovementTiming(
          occurredAt: DateTime.utc(2026, 9, 13, 10, 4),
          rawOccurredAt: DateTime.utc(2026, 9, 13, 10, 4),
        ),
      );
      final cursorBeforeInterruptedApply = await harness.cursor(
        harness.deviceB,
      );
      await harness.installCursorFailure(harness.deviceB);
      await expectLater(
        harness.deviceB.runtime.engine.synchronize(),
        throwsA(anything),
      );
      expect(
        await harness.cursor(harness.deviceB),
        cursorBeforeInterruptedApply,
        reason: 'a failed page must not advance the local cursor',
      );
      expect(
        await harness.movement(harness.deviceB, issueA.movementId),
        isNull,
        reason: 'the failed page must roll back remote row application',
      );
      await harness.removeCursorFailure(harness.deviceB);
      await harness.synchronize(harness.deviceB);
      await harness.synchronize(harness.deviceA);

      // Repeat the exchange in the opposite order. This catches an accidental
      // dependence on which replica happens to push first.
      final receiveA = await harness.deviceA.movements.receive(
        productId: product.productId,
        quantity: 4,
        note: 'device A second offline change',
        timing: MovementTiming(
          occurredAt: DateTime.utc(2026, 9, 13, 10, 5),
          rawOccurredAt: DateTime.utc(2026, 9, 13, 10, 5),
        ),
      );
      final receiveB = await harness.deviceB.movements.receive(
        productId: product.productId,
        quantity: 1,
        note: 'device B second offline change',
        timing: MovementTiming(
          occurredAt: DateTime.utc(2026, 9, 13, 10, 6),
          rawOccurredAt: DateTime.utc(2026, 9, 13, 10, 6),
        ),
      );
      await harness.synchronize(harness.deviceA);
      await harness.synchronize(harness.deviceB);

      // A tombstone is also authored offline and pulled by the other device.
      await harness.deviceA.products.softDelete(product.productId);
      await harness.synchronize(harness.deviceA);
      await harness.synchronize(harness.deviceB);

      final snapshot = await harness.snapshot(harness.deviceA);
      final expectedMovementIds = {
        issueA.movementId,
        issueB.movementId,
        receiveA.movementId,
        receiveB.movementId,
      };
      _expectReplica(
        await harness.replicaState(harness.deviceA),
        productId: product.productId,
        expectedMovementIds: expectedMovementIds,
        expectedBalance: 0,
      );
      _expectReplica(
        await harness.replicaState(harness.deviceB),
        productId: product.productId,
        expectedMovementIds: expectedMovementIds,
        expectedBalance: 0,
      );

      final products = (snapshot['products'] as List).cast<Map>();
      final tombstones = (snapshot['tombstones'] as List).cast<Map>();
      final movements = (snapshot['movements'] as List).cast<Map>();
      final balances = (snapshot['balances'] as List).cast<Map>();
      expect(products, hasLength(1));
      expect(products.single['id'], product.productId);
      expect(products.single['deleted_at'], isNotNull);
      expect(tombstones, hasLength(1));
      expect(tombstones.single['id'], product.productId);
      expect(
        movements.map((movement) => movement['id']).toSet(),
        expectedMovementIds,
      );
      expect(movements.map((movement) => movement['delta']).toList()..sort(), [
        -3,
        -2,
        1,
        4,
      ]);
      expect(balances, hasLength(1));
      expect(balances.single['product_id'], product.productId);
      expect(balances.single['qty'], 0);
      expect(await harness.cursor(harness.deviceA), snapshot['cursor']);
      expect(await harness.cursor(harness.deviceB), snapshot['cursor']);
    },
    skip: liveTestSkip,
  );
}

const _password = 'stoksync-two-device-integration-password';
final _productId = UuidV7Generator().generate();
final _productOperationId = UuidV7Generator().generate();
final _issueAMovementId = UuidV7Generator().generate();
final _issueAOperationId = UuidV7Generator().generate();
final _deleteOperationId = UuidV7Generator().generate();
final _issueBMovementId = UuidV7Generator().generate();
final _issueBOperationId = UuidV7Generator().generate();
final _receiveAMovementId = UuidV7Generator().generate();
final _receiveAOperationId = UuidV7Generator().generate();
final _receiveBMovementId = UuidV7Generator().generate();
final _receiveBOperationId = UuidV7Generator().generate();

final class _TwoDeviceHarness {
  _TwoDeviceHarness({
    required this.baseUri,
    required this.deviceA,
    required this.deviceB,
  });

  final Uri baseUri;
  final _DeviceHarness deviceA;
  final _DeviceHarness deviceB;

  static Future<_TwoDeviceHarness> create(Uri baseUri) async {
    final email = 'two-device-${UuidV7Generator().generate()}@example.test';
    final deviceAId = UuidV7Generator().generate();
    final deviceBId = UuidV7Generator().generate();
    final registrationSender = IoSyncHttpRequestSender();
    try {
      await _register(
        sender: registrationSender,
        baseUri: baseUri,
        email: email,
        deviceId: deviceAId,
      );
    } finally {
      registrationSender.close(force: true);
    }

    final deviceA = await _DeviceHarness.signIn(
      baseUri: baseUri,
      email: email,
      deviceId: deviceAId,
      identifiers: [
        _productId,
        _productOperationId,
        _issueAMovementId,
        _issueAOperationId,
        _receiveAMovementId,
        _receiveAOperationId,
        _deleteOperationId,
      ],
    );
    try {
      final deviceB = await _DeviceHarness.signIn(
        baseUri: baseUri,
        email: email,
        deviceId: deviceBId,
        identifiers: [
          _issueBMovementId,
          _issueBOperationId,
          _receiveBMovementId,
          _receiveBOperationId,
        ],
      );
      return _TwoDeviceHarness(
        baseUri: baseUri,
        deviceA: deviceA,
        deviceB: deviceB,
      );
    } catch (_) {
      await deviceA.close();
      rethrow;
    }
  }

  Future<void> synchronize(_DeviceHarness device) async {
    final result = await device.runtime.engine.synchronize();
    expect(result, isNotNull);
  }

  Future<int> cursor(_DeviceHarness device) {
    return DriftSyncCursorStore(device.database).readCursor();
  }

  Future<int> pendingCount(_DeviceHarness device) async {
    return (await device.database
            .select(device.database.pendingOperations)
            .get())
        .length;
  }

  Future<Product?> product(_DeviceHarness device, String productId) {
    return (device.database.select(
      device.database.products,
    )..where((row) => row.id.equals(productId))).getSingleOrNull();
  }

  Future<StockMovement?> movement(_DeviceHarness device, String movementId) {
    return (device.database.select(
      device.database.stockMovements,
    )..where((row) => row.id.equals(movementId))).getSingleOrNull();
  }

  Future<void> installCursorFailure(_DeviceHarness device) {
    return device.database.customStatement(
      'CREATE TRIGGER integration_cursor_failure '
      'BEFORE UPDATE OF cursor ON sync_state BEGIN '
      "SELECT RAISE(ABORT, 'simulated client interruption'); END",
    );
  }

  Future<void> removeCursorFailure(_DeviceHarness device) {
    return device.database.customStatement(
      'DROP TRIGGER integration_cursor_failure',
    );
  }

  Future<_ReplicaState> replicaState(_DeviceHarness device) async {
    final products = await device.database
        .select(device.database.products)
        .get();
    final movements = await device.database
        .select(device.database.stockMovements)
        .get();
    final balances = await device.database
        .select(device.database.productBalances)
        .get();
    final pending = await device.database
        .select(device.database.pendingOperations)
        .get();
    return _ReplicaState(
      products: products,
      movements: movements,
      balances: balances,
      pending: pending,
    );
  }

  Future<Map<String, dynamic>> snapshot(_DeviceHarness device) async {
    final session = await device.sessionStore.readSession();
    expect(session, isNotNull);
    final response = await device.sender.send(
      method: 'GET',
      uri: _snapshotEndpoint(baseUri),
      headers: <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer ${session!.accessToken}',
      },
      body: const <int>[],
    );
    expect(response.statusCode, 200, reason: utf8.decode(response.body));
    return (jsonDecode(utf8.decode(response.body)) as Map)
        .cast<String, dynamic>();
  }

  Future<void> close() async {
    await Future.wait(<Future<void>>[deviceA.close(), deviceB.close()]);
  }
}

final class _DeviceHarness {
  _DeviceHarness({
    required this.database,
    required this.sender,
    required this.sessionStore,
    required this.runtime,
    required this.products,
    required this.movements,
  });

  final StokSyncDatabase database;
  final IoSyncHttpRequestSender sender;
  final SecureSyncSessionStore sessionStore;
  final AuthenticatedSyncRuntime runtime;
  final LocalProductRepository products;
  final LocalStockMovementRepository movements;

  static Future<_DeviceHarness> signIn({
    required Uri baseUri,
    required String email,
    required String deviceId,
    required List<String> identifiers,
  }) async {
    final database = StokSyncDatabase(NativeDatabase.memory());
    final sender = IoSyncHttpRequestSender();
    final sessionStore = SecureSyncSessionStore(values: _MemorySecureValues());
    final deviceIdentity = DeviceIdentity(
      secureStore: _MemoryDeviceValues(),
      identifierGenerator: _QueueIdentifierGenerator([deviceId]),
    );
    final authController = AuthSessionController(
      client: HttpAuthClient(baseUri: baseUri, sender: sender),
      sessionStore: sessionStore,
    );
    try {
      await authController.login(
        email: email,
        password: _password,
        deviceId: deviceId,
        deviceName: 'Task 4.9 integration device',
        platform: 'test',
      );
      final runtime = AuthenticatedSyncRuntime(
        database: database,
        baseUri: baseUri,
        deviceId: await deviceIdentity.getDeviceId(),
        sessionStore: sessionStore,
        sender: sender,
      );
      final identifierGenerator = _QueueIdentifierGenerator(identifiers);
      return _DeviceHarness(
        database: database,
        sender: sender,
        sessionStore: sessionStore,
        runtime: runtime,
        products: LocalProductRepository(
          database: database,
          identifierGenerator: identifierGenerator,
          deviceIdentity: deviceIdentity,
          clock: () => DateTime.utc(2026, 9, 13, 10, 2),
        ),
        movements: LocalStockMovementRepository(
          database: database,
          identifierGenerator: identifierGenerator,
          deviceIdentity: deviceIdentity,
          clock: () => DateTime.utc(2026, 9, 13, 10, 2),
        ),
      );
    } catch (_) {
      await database.close();
      sender.close(force: true);
      rethrow;
    }
  }

  Future<void> close() async {
    sender.close(force: true);
    await database.close();
  }
}

final class _ReplicaState {
  const _ReplicaState({
    required this.products,
    required this.movements,
    required this.balances,
    required this.pending,
  });

  final List<Product> products;
  final List<StockMovement> movements;
  final List<ProductBalance> balances;
  final List<PendingOperation> pending;
}

void _expectReplica(
  _ReplicaState state, {
  required String productId,
  required Set<String> expectedMovementIds,
  required int expectedBalance,
}) {
  expect(state.products, hasLength(1));
  expect(state.products.single.id, productId);
  expect(state.products.single.deletedAt, isNotNull);
  expect(state.products.single.syncStatus, 'synced');
  expect(state.movements, hasLength(expectedMovementIds.length));
  expect(
    state.movements.map((movement) => movement.id).toSet(),
    expectedMovementIds,
  );
  expect(
    state.movements.fold<int>(0, (sum, movement) => sum + movement.delta),
    expectedBalance,
  );
  expect(state.balances, hasLength(1));
  expect(state.balances.single.qty, expectedBalance);
  expect(state.pending, isEmpty);
}

Future<void> _register({
  required IoSyncHttpRequestSender sender,
  required Uri baseUri,
  required String email,
  required String deviceId,
}) async {
  final response = await sender.send(
    method: 'POST',
    uri: _authEndpoint(baseUri, 'register'),
    headers: const <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
    body: utf8.encode(
      jsonEncode(<String, String>{
        'email': email,
        'password': _password,
        'device_id': deviceId,
        'device_name': 'Task 4.9 integration device A',
        'platform': 'test',
      }),
    ),
  );
  if (response.statusCode != 201) {
    fail('integration account registration failed: ${response.statusCode}');
  }
}

Uri _authEndpoint(Uri baseUri, String action) {
  var root = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  for (final suffix in const [
    '/v1/auth/login',
    '/v1/auth/refresh',
    '/v1/sync',
    '/v1/health',
    '/v1',
  ]) {
    if (root.endsWith(suffix)) {
      root = root.substring(0, root.length - suffix.length);
      break;
    }
  }
  return baseUri.replace(
    path: '${root.isEmpty ? '' : root}/v1/auth/$action',
    queryParameters: const <String, String>{},
    fragment: '',
    userInfo: '',
  );
}

Uri _snapshotEndpoint(Uri baseUri) {
  var root = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  for (final suffix in const ['/v1/sync', '/v1/health', '/v1']) {
    if (root.endsWith(suffix)) {
      root = root.substring(0, root.length - suffix.length);
      break;
    }
  }
  return baseUri.replace(
    path: '${root.isEmpty ? '' : root}/v1/snapshot',
    queryParameters: const <String, String>{},
    fragment: '',
    userInfo: '',
  );
}

final class _QueueIdentifierGenerator implements IdentifierGenerator {
  _QueueIdentifierGenerator(Iterable<String> identifiers)
    : _identifiers = identifiers.toList();

  final List<String> _identifiers;

  @override
  String generate() {
    if (_identifiers.isEmpty) {
      throw StateError('Task 4.9 identifier queue exhausted.');
    }
    return _identifiers.removeAt(0);
  }
}

final class _MemorySecureValues implements SecureValueStore {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}

final class _MemoryDeviceValues implements SecureKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }
}
