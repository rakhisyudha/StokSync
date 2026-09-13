import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sync_engine/sync_engine.dart';

/// Minimal secure-value seam around the platform plugin.
///
/// Keeping this interface separate makes session persistence deterministic in
/// tests without putting credentials in Drift or ordinary preferences.
abstract interface class SecureValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

/// Production adapter for platform-backed secure storage.
final class FlutterSecureValueStore implements SecureValueStore {
  FlutterSecureValueStore({FlutterSecureStorage? storage})
    : _storage = storage ?? FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }
}

/// Stores the current access/refresh session as one secure JSON value.
final class SecureSyncSessionStore implements SyncSessionStore {
  SecureSyncSessionStore({SecureValueStore? values})
    : _values = values ?? FlutterSecureValueStore();

  static const sessionKey = 'stoksync.session.v1';

  final SecureValueStore _values;

  @override
  Future<SyncSession?> readSession() async {
    final encoded = await _values.read(sessionKey);
    if (encoded == null || encoded.trim().isEmpty) {
      return null;
    }
    try {
      return SyncSession.fromStorageJsonString(encoded);
    } on SyncProtocolException {
      // Do not expose stored credential material through an exception. The
      // sync layer records a stable blocked-authentication reason instead.
      throw const SyncAuthenticationException(
        reason: 'session_storage_invalid',
      );
    }
  }

  @override
  Future<void> writeSession(SyncSession session) {
    return _values.write(sessionKey, session.toStorageJsonString());
  }
}
