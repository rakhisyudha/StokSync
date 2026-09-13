import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/remote/sync_session_store.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  test(
    'persists and restores sessions through the secure-value seam',
    () async {
      final values = _MemorySecureValues();
      final store = SecureSyncSessionStore(values: values);
      final session = SyncSession(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        userId: '0192f1a0-0000-7000-8000-000000000001',
        deviceId: '0192f200-0000-7000-8000-000000000001',
        accessTokenExpiresAt: DateTime.utc(2026, 9, 13, 10, 17),
      );

      await store.writeSession(session);
      final restored = await store.readSession();

      expect(restored?.accessToken, 'access-token');
      expect(restored?.refreshToken, 'refresh-token');
      expect(restored?.accessTokenExpiresAt, DateTime.utc(2026, 9, 13, 10, 17));
      expect(values.values.keys, [SecureSyncSessionStore.sessionKey]);
    },
  );

  test(
    'turns malformed secure session data into a safe blocked-auth error',
    () async {
      final values = _MemorySecureValues()
        ..values[SecureSyncSessionStore.sessionKey] =
            '{"access_token":"secret-access-token"}';
      final store = SecureSyncSessionStore(values: values);

      await expectLater(
        store.readSession(),
        throwsA(
          allOf(
            isA<SyncAuthenticationException>(),
            isNot(contains('secret-access-token')),
          ),
        ),
      );
    },
  );
}

final class _MemorySecureValues implements SecureValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
