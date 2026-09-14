import 'dart:convert';

import 'package:sync_engine/sync_engine.dart';

import '../../core/diagnostics/diagnostics.dart';

/// A safe, user-facing classification for login and session persistence
/// failures. It intentionally never includes request bodies or credentials.
final class AuthClientException implements Exception {
  const AuthClientException({required this.reason, this.statusCode});

  final String reason;
  final int? statusCode;

  String get userMessage {
    return switch (reason) {
      'invalid_credentials' => 'The email or password is incorrect.',
      'network_unavailable' =>
        'The server could not be reached. Check your connection and try again.',
      'session_response_invalid' =>
        'The server returned an invalid sign-in response.',
      'session_persistence_failed' =>
        'The session could not be stored securely on this device.',
      _ => 'Could not sign in. Please try again.',
    };
  }

  @override
  String toString() => 'AuthClientException(reason: $reason)';
}

/// Performs the unauthenticated login exchange against the StokSync API.
final class HttpAuthClient {
  HttpAuthClient({
    required Uri baseUri,
    SyncHttpRequestSender? sender,
    SyncNow? now,
    AppDiagnostics? diagnostics,
  }) : _endpoint = _resolveLoginEndpoint(baseUri),
       _sender = sender ?? IoSyncHttpRequestSender(),
       _now = now ?? _utcNow,
       _diagnostics = diagnostics;

  final Uri _endpoint;
  final SyncHttpRequestSender _sender;
  final SyncNow _now;
  final AppDiagnostics? _diagnostics;

  Uri get endpoint => _endpoint;

  Future<SyncSession> login({
    required String email,
    required String password,
    required String deviceId,
    String deviceName = 'StokSync device',
    String platform = 'unknown',
  }) async {
    final normalizedEmail = email.trim();
    final normalizedDeviceId = deviceId.trim();
    if (normalizedEmail.isEmpty ||
        password.isEmpty ||
        normalizedDeviceId.isEmpty) {
      _diagnostics?.event(
        'auth.login',
        fields: const <String, Object?>{
          'outcome': 'rejected',
          'reason': 'invalid_request',
        },
      );
      throw const AuthClientException(reason: 'invalid_request');
    }

    final SyncHttpResponse response;
    try {
      response = await _sender.send(
        method: 'POST',
        uri: _endpoint,
        headers: const <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: utf8.encode(
          jsonEncode(<String, String>{
            'email': normalizedEmail,
            'password': password,
            'device_id': normalizedDeviceId,
            'device_name': deviceName.trim(),
            'platform': platform.trim(),
          }),
        ),
      );
    } on SyncTransportException {
      _diagnostics?.event(
        'auth.login',
        fields: const <String, Object?>{
          'outcome': 'failed',
          'reason': 'network_unavailable',
        },
      );
      throw const AuthClientException(reason: 'network_unavailable');
    } on Object {
      _diagnostics?.event(
        'auth.login',
        fields: const <String, Object?>{
          'outcome': 'failed',
          'reason': 'network_unavailable',
        },
      );
      throw const AuthClientException(reason: 'network_unavailable');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      _diagnostics?.event(
        'auth.login',
        fields: <String, Object?>{
          'outcome': 'rejected',
          'status_code': response.statusCode,
        },
      );
      throw AuthClientException(
        reason: _errorCode(response.body) ?? _statusReason(response.statusCode),
        statusCode: response.statusCode,
      );
    }

    try {
      final session = SyncSession.fromAuthResponseJsonString(
        _decodeBody(response.body),
        now: _now,
      );
      _diagnostics?.event(
        'auth.login',
        fields: <String, Object?>{
          'outcome': 'succeeded',
          'status_code': response.statusCode,
        },
      );
      return session;
    } on FormatException {
      _diagnostics?.event(
        'auth.login',
        fields: <String, Object?>{
          'outcome': 'failed',
          'reason': 'session_response_invalid',
          'status_code': response.statusCode,
        },
      );
      throw const AuthClientException(reason: 'session_response_invalid');
    } on SyncProtocolException {
      _diagnostics?.event(
        'auth.login',
        fields: <String, Object?>{
          'outcome': 'failed',
          'reason': 'session_response_invalid',
          'status_code': response.statusCode,
        },
      );
      throw const AuthClientException(reason: 'session_response_invalid');
    }
  }
}

/// Logs in through [HttpAuthClient] and persists the resulting session using
/// the application's secure session store before reporting success to the UI.
final class AuthSessionController {
  const AuthSessionController({
    required HttpAuthClient client,
    required SyncSessionStore sessionStore,
  }) : _client = client,
       _sessionStore = sessionStore;

  final HttpAuthClient _client;
  final SyncSessionStore _sessionStore;

  Future<SyncSession> login({
    required String email,
    required String password,
    required String deviceId,
    String deviceName = 'StokSync device',
    String platform = 'unknown',
  }) async {
    final session = await _client.login(
      email: email,
      password: password,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
    );
    try {
      await _sessionStore.writeSession(session);
    } on Object {
      throw const AuthClientException(reason: 'session_persistence_failed');
    }
    return session;
  }
}

String _decodeBody(List<int> body) {
  return utf8.decode(body, allowMalformed: false);
}

String? _errorCode(List<int> body) {
  if (body.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(_decodeBody(body));
    if (decoded is Map && decoded['error'] is String) {
      final code = (decoded['error'] as String).trim();
      return code.isEmpty ? null : code;
    }
  } on FormatException {
    return null;
  }
  return null;
}

String _statusReason(int statusCode) {
  return switch (statusCode) {
    401 => 'invalid_credentials',
    _ => 'login_failed',
  };
}

Uri _resolveLoginEndpoint(Uri baseUri) {
  if (baseUri.scheme != 'http' && baseUri.scheme != 'https') {
    throw ArgumentError.value(baseUri, 'baseUri', 'must use HTTP or HTTPS');
  }
  if (baseUri.host.isEmpty) {
    throw ArgumentError.value(baseUri, 'baseUri', 'must include a host');
  }

  var rootPath = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  for (final suffix in const [
    '/v1/auth/login',
    '/v1/auth/refresh',
    '/v1/sync',
    '/v1/health',
    '/v1',
  ]) {
    if (rootPath.endsWith(suffix)) {
      rootPath = rootPath.substring(0, rootPath.length - suffix.length);
      break;
    }
  }
  return Uri(
    scheme: baseUri.scheme,
    host: baseUri.host,
    port: baseUri.hasPort ? baseUri.port : null,
    path: '${rootPath.isEmpty ? '' : rootPath}/v1/auth/login',
  );
}

DateTime _utcNow() => DateTime.now().toUtc();
