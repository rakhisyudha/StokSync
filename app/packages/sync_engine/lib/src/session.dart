import 'dart:async';
import 'dart:convert';

import 'errors.dart';

final RegExp _sessionUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final RegExp _sessionUtcPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$',
);

/// The client-side session returned by login or refresh.
///
/// Access and refresh tokens are intentionally kept inside this value and the
/// secure-storage seam. Callers must not log this object or its JSON form.
final class SyncSession {
  SyncSession({
    required String accessToken,
    required String refreshToken,
    required String userId,
    required String deviceId,
    required DateTime accessTokenExpiresAt,
  }) : accessToken = _requiredToken(accessToken, 'accessToken'),
       refreshToken = _requiredToken(refreshToken, 'refreshToken'),
       userId = _requiredUuid(userId, 'userId'),
       deviceId = _requiredUuid(deviceId, 'deviceId'),
       accessTokenExpiresAt = accessTokenExpiresAt.toUtc();

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String deviceId;
  final DateTime accessTokenExpiresAt;

  /// The intentionally smaller representation persisted by a session store.
  Map<String, Object?> toStorageJson() => <String, Object?>{
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'user_id': userId,
    'device_id': deviceId,
    'access_token_expires_at': _timestamp(accessTokenExpiresAt),
  };

  String toStorageJsonString() => jsonEncode(toStorageJson());

  /// Decodes the format written by [toStorageJsonString].
  static SyncSession fromStorageJsonString(String source) {
    final map = _object(_decode(source), 'stored session');
    _checkKeys(map, const {
      'access_token',
      'refresh_token',
      'user_id',
      'device_id',
      'access_token_expires_at',
    }, 'stored session');
    return SyncSession(
      accessToken: _string(map['access_token'], 'access_token'),
      refreshToken: _string(map['refresh_token'], 'refresh_token'),
      userId: _string(map['user_id'], 'user_id'),
      deviceId: _string(map['device_id'], 'device_id'),
      accessTokenExpiresAt: _timestampValue(
        map['access_token_expires_at'],
        'access_token_expires_at',
      ),
    );
  }

  /// Decodes the server's login/refresh response.
  static SyncSession fromAuthResponseJsonString(
    String source, {
    DateTime Function()? now,
  }) {
    final map = _object(_decode(source), 'session response');
    _checkKeys(map, const {
      'access_token',
      'token_type',
      'expires_in',
      'refresh_token',
      'user_id',
      'device_id',
    }, 'session response');
    final tokenType = _string(map['token_type'], 'token_type');
    if (tokenType.toLowerCase() != 'bearer') {
      throw _invalid('token_type', 'must be Bearer');
    }
    final expiresIn = _int(map['expires_in'], 'expires_in');
    if (expiresIn <= 0) {
      throw _invalid('expires_in', 'must be greater than zero');
    }
    final issuedAt = (now ?? _utcNow)().toUtc();
    return SyncSession(
      accessToken: _string(map['access_token'], 'access_token'),
      refreshToken: _string(map['refresh_token'], 'refresh_token'),
      userId: _string(map['user_id'], 'user_id'),
      deviceId: _string(map['device_id'], 'device_id'),
      accessTokenExpiresAt: issuedAt.add(Duration(seconds: expiresIn)),
    );
  }
}

/// Durable storage for the current authenticated session.
///
/// The pure-Dart engine only depends on this seam. The Flutter application
/// supplies an implementation backed by secure device storage; tokens are not
/// stored in Drift or ordinary preferences.
abstract interface class SyncSessionStore {
  Future<SyncSession?> readSession();

  Future<void> writeSession(SyncSession session);
}

/// Performs one refresh-token exchange without knowing how the session is
/// persisted.
abstract interface class SyncSessionRefresher {
  Future<SyncSession> refresh(String refreshToken);
}

/// Coordinates session reads and refreshes for concurrent sync requests.
///
/// A refresh is shared by all callers that observe the same rejected access
/// token. Once a replacement is persisted, a late 401 for the old token uses
/// that replacement instead of rotating the refresh token again.
final class SyncSessionManager {
  SyncSessionManager({
    required SyncSessionStore store,
    required SyncSessionRefresher refresher,
  }) : _store = store,
       _refresher = refresher;

  final SyncSessionStore _store;
  final SyncSessionRefresher _refresher;
  Future<SyncSession>? _refreshFuture;

  /// Reads the current access token for a request.
  Future<String?> accessToken() async {
    final session = await _readSession();
    if (session == null) {
      throw const SyncAuthenticationException(reason: 'session_missing');
    }
    return session.accessToken;
  }

  /// Refreshes after [rejectedAccessToken], at most once for the current
  /// session generation, and returns the session to use for a retry.
  Future<SyncSession> refreshAfterUnauthorized(String rejectedAccessToken) {
    final ongoing = _refreshFuture;
    if (ongoing != null) {
      return ongoing;
    }

    // Install the gate before the first await. This closes the race where two
    // callers observe the same expired session while the first caller is
    // still reading secure storage.
    final completer = Completer<SyncSession>();
    final refresh = completer.future;
    _refreshFuture = refresh;
    unawaited(_refreshAndComplete(rejectedAccessToken, completer, refresh));
    return refresh;
  }

  Future<void> _refreshAndComplete(
    String rejectedAccessToken,
    Completer<SyncSession> completer,
    Future<SyncSession> refresh,
  ) async {
    try {
      final current = await _readSession();
      if (current == null) {
        throw const SyncAuthenticationException(reason: 'session_missing');
      }

      final rejected = rejectedAccessToken.trim();
      if (rejected.isNotEmpty && current.accessToken != rejected) {
        // Another request already rotated the session before this caller got
        // to the refresh gate. Reuse the persisted replacement.
        completer.complete(current);
        return;
      }

      completer.complete(await _refreshAndPersist(current));
    } on Object catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_refreshFuture, refresh)) {
        _refreshFuture = null;
      }
    }
  }

  Future<SyncSession?> _readSession() async {
    try {
      return await _store.readSession();
    } on SyncAuthenticationException {
      rethrow;
    } on Object {
      throw const SyncAuthenticationException(
        reason: 'session_storage_unavailable',
      );
    }
  }

  Future<SyncSession> _refreshAndPersist(SyncSession current) async {
    final replacement = await _refresh(current.refreshToken);
    try {
      await _store.writeSession(replacement);
    } on SyncAuthenticationException {
      rethrow;
    } on Object {
      throw const SyncAuthenticationException(
        reason: 'session_storage_unavailable',
      );
    }
    return replacement;
  }

  Future<SyncSession> _refresh(String refreshToken) async {
    if (refreshToken.trim().isEmpty) {
      throw const SyncAuthenticationException(reason: 'refresh_token_missing');
    }
    try {
      return await _refresher.refresh(refreshToken);
    } on SyncAuthenticationException {
      rethrow;
    } on SyncTransportException {
      rethrow;
    } on Object {
      throw const SyncAuthenticationException(reason: 'refresh_failed');
    }
  }
}

Object? _decode(String source) {
  try {
    return jsonDecode(source);
  } on FormatException {
    throw _invalid('session', 'contains malformed JSON');
  }
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) {
    throw _invalid(field, 'must be a JSON object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw _invalid(field, 'contains a non-string field name');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

void _checkKeys(Map<String, Object?> map, Set<String> allowed, String field) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw _invalid('$field.$key', 'is not supported');
    }
  }
}

String _string(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw _invalid(field, 'must be a non-empty string');
  }
  return value;
}

String _requiredToken(String value, String field) => _string(value, field);

String _requiredUuid(String value, String field) {
  final normalized = _string(value, field);
  if (!_sessionUuidPattern.hasMatch(normalized)) {
    throw _invalid(field, 'must be a UUID');
  }
  return normalized;
}

int _int(Object? value, String field) {
  if (value is! int) {
    throw _invalid(field, 'must be an integer');
  }
  return value;
}

DateTime _timestampValue(Object? value, String field) {
  final source = _string(value, field);
  if (!_sessionUtcPattern.hasMatch(source)) {
    throw _invalid(field, 'must be an RFC 3339 UTC timestamp');
  }
  final parsed = DateTime.tryParse(source);
  if (parsed == null || !parsed.isUtc) {
    throw _invalid(field, 'must be a valid RFC 3339 UTC timestamp');
  }
  return parsed;
}

String _timestamp(DateTime value) => value.toUtc().toIso8601String();

SyncProtocolException _invalid(String field, String message) {
  return SyncProtocolException(
    SyncProtocolErrorKind.invalidValue,
    message,
    field: field,
  );
}

DateTime _utcNow() => DateTime.now().toUtc();
