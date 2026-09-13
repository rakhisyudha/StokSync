import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';

void main() {
  group('DeviceIdentity', () {
    test(
      'creates a UUIDv7 once and restores it after service recreation',
      () async {
        final secureStore = _FakeSecureKeyValueStore();
        final firstGenerator = _FakeIdentifierGenerator([
          '0192f200-0000-7000-8000-000000000001',
        ]);
        final firstIdentity = DeviceIdentity(
          secureStore: secureStore,
          identifierGenerator: firstGenerator,
        );

        final created = await firstIdentity.getDeviceId();

        expect(UuidV7.isValid(created), isTrue);
        expect(secureStore.value, created);
        expect(secureStore.writeCalls, 1);
        expect(firstGenerator.calls, 1);

        final restartedGenerator = _FakeIdentifierGenerator([
          '0192f200-0000-7000-8000-000000000002',
        ]);
        final restartedIdentity = DeviceIdentity(
          secureStore: secureStore,
          identifierGenerator: restartedGenerator,
        );

        expect(await restartedIdentity.getDeviceId(), created);
        expect(secureStore.writeCalls, 1);
        expect(restartedGenerator.calls, 0);
      },
    );

    test(
      'coalesces concurrent initialization into one secure read and write',
      () async {
        final secureStore = _FakeSecureKeyValueStore()
          ..pendingRead = Completer<String?>();
        final generator = _FakeIdentifierGenerator([
          '0192f200-0000-7000-8000-000000000001',
        ]);
        final identity = DeviceIdentity(
          secureStore: secureStore,
          identifierGenerator: generator,
        );

        final first = identity.getDeviceId();
        final second = identity.getDeviceId();
        expect(secureStore.readCalls, 1);

        secureStore.pendingRead!.complete(null);
        final resolved = await Future.wait([first, second]);

        expect(resolved, [
          '0192f200-0000-7000-8000-000000000001',
          '0192f200-0000-7000-8000-000000000001',
        ]);
        expect(secureStore.writeCalls, 1);
        expect(generator.calls, 1);
      },
    );

    test(
      'propagates secure-store read failures without generating an ID',
      () async {
        final failure = StateError('secure storage unavailable');
        final secureStore = _FakeSecureKeyValueStore()..readFailure = failure;
        final generator = _FakeIdentifierGenerator([
          '0192f200-0000-7000-8000-000000000001',
        ]);
        final identity = DeviceIdentity(
          secureStore: secureStore,
          identifierGenerator: generator,
        );

        await expectLater(identity.getDeviceId(), throwsA(same(failure)));
        expect(generator.calls, 0);
        expect(secureStore.writeCalls, 0);
      },
    );

    test('allows a later retry after a secure-store write failure', () async {
      final failure = StateError('secure storage unavailable');
      final secureStore = _FakeSecureKeyValueStore()..writeFailure = failure;
      final generator = _FakeIdentifierGenerator([
        '0192f200-0000-7000-8000-000000000001',
        '0192f200-0000-7000-8000-000000000002',
      ]);
      final identity = DeviceIdentity(
        secureStore: secureStore,
        identifierGenerator: generator,
      );

      await expectLater(identity.getDeviceId(), throwsA(same(failure)));

      secureStore.writeFailure = null;
      expect(
        await identity.getDeviceId(),
        '0192f200-0000-7000-8000-000000000002',
      );
      expect(secureStore.value, '0192f200-0000-7000-8000-000000000002');
      expect(secureStore.writeCalls, 2);
      expect(generator.calls, 2);
    });

    test(
      'rejects a malformed persisted value without overwriting it',
      () async {
        final secureStore = _FakeSecureKeyValueStore()
          ..value = 'legacy-device-id';
        final generator = _FakeIdentifierGenerator([
          '0192f200-0000-7000-8000-000000000001',
        ]);
        final identity = DeviceIdentity(
          secureStore: secureStore,
          identifierGenerator: generator,
        );

        await expectLater(
          identity.getDeviceId(),
          throwsA(isA<DeviceIdentityException>()),
        );
        expect(secureStore.value, 'legacy-device-id');
        expect(secureStore.writeCalls, 0);
        expect(generator.calls, 0);
      },
    );
  });
}

final class _FakeSecureKeyValueStore implements SecureKeyValueStore {
  String? value;
  int readCalls = 0;
  int writeCalls = 0;
  Completer<String?>? pendingRead;
  Object? readFailure;
  Object? writeFailure;

  @override
  Future<String?> read(String key) {
    readCalls++;
    final failure = readFailure;
    if (failure != null) {
      return Future<String?>.error(failure);
    }
    final pending = pendingRead;
    if (pending != null) {
      return pending.future;
    }
    return Future.value(value);
  }

  @override
  Future<void> write({required String key, required String value}) {
    writeCalls++;
    final failure = writeFailure;
    if (failure != null) {
      return Future<void>.error(failure);
    }
    this.value = value;
    return Future.value();
  }
}

final class _FakeIdentifierGenerator implements IdentifierGenerator {
  _FakeIdentifierGenerator(this._identifiers);

  final List<String> _identifiers;
  int calls = 0;

  @override
  String generate() {
    calls++;
    if (_identifiers.isEmpty) {
      throw StateError('No test identifiers remain.');
    }
    return _identifiers.removeAt(0);
  }
}
