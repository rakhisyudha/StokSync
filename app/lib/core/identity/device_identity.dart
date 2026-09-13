import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../identifiers/uuid_v7_generator.dart';

/// Minimal secure key-value interface so platform storage remains replaceable
/// and testable without invoking a platform plugin.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);

  Future<void> write({required String key, required String value});
}

/// Production [SecureKeyValueStore] backed by the pinned secure-storage plugin.
final class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }
}

/// Thrown when secure storage contains an identifier that is not UUIDv7.
final class DeviceIdentityException implements Exception {
  DeviceIdentityException(this.message);

  final String message;

  @override
  String toString() => 'DeviceIdentityException: $message';
}

/// Resolves one stable UUIDv7 identifier for this application installation.
///
/// The identity is cached after a successful secure read or write. Concurrent
/// callers share one initialization attempt, preventing different IDs from
/// being created before secure persistence completes. Storage errors propagate
/// unchanged so callers never silently receive an unpersisted identity.
final class DeviceIdentity {
  DeviceIdentity({
    required SecureKeyValueStore secureStore,
    required IdentifierGenerator identifierGenerator,
  }) : _secureStore = secureStore,
       _identifierGenerator = identifierGenerator;

  factory DeviceIdentity.platform({IdentifierGenerator? identifierGenerator}) {
    return DeviceIdentity(
      secureStore: FlutterSecureKeyValueStore(),
      identifierGenerator: identifierGenerator ?? UuidV7Generator(),
    );
  }

  static const String storageKey = 'stoksync.device_identity.v1';

  final SecureKeyValueStore _secureStore;
  final IdentifierGenerator _identifierGenerator;

  String? _cachedDeviceId;
  Future<String>? _initialization;

  /// Reads the persisted UUIDv7 or atomically establishes and persists one.
  Future<String> getDeviceId() {
    final cachedDeviceId = _cachedDeviceId;
    if (cachedDeviceId != null) {
      return Future.value(cachedDeviceId);
    }

    final initialization = _initialization;
    if (initialization != null) {
      return initialization;
    }

    late final Future<String> createdInitialization;
    createdInitialization = _loadOrCreate().whenComplete(() {
      if (identical(_initialization, createdInitialization)) {
        _initialization = null;
      }
    });
    _initialization = createdInitialization;
    return createdInitialization;
  }

  Future<String> _loadOrCreate() async {
    final persistedDeviceId = await _secureStore.read(storageKey);
    if (persistedDeviceId != null) {
      if (!UuidV7.isValid(persistedDeviceId)) {
        throw DeviceIdentityException(
          'Secure storage contains a non-UUIDv7 device identifier.',
        );
      }
      _cachedDeviceId = persistedDeviceId;
      return persistedDeviceId;
    }

    final generatedDeviceId = _identifierGenerator.generate();
    if (!UuidV7.isValid(generatedDeviceId)) {
      throw DeviceIdentityException(
        'The configured identifier generator did not return a UUIDv7.',
      );
    }

    await _secureStore.write(key: storageKey, value: generatedDeviceId);
    _cachedDeviceId = generatedDeviceId;
    return generatedDeviceId;
  }
}
