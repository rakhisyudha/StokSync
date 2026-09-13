import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'clock.dart';
import 'errors.dart';
import 'protocol.dart';
import 'session.dart';

/// Narrow transport boundary consumed by future sync orchestration.
///
/// Queue selection, retry scheduling, mutexes, and local reconciliation stay
/// outside this interface. A call represents one bounded push/pull exchange.
abstract interface class SyncTransport {
  Future<SyncResponse> synchronize(SyncRequest request);
}

typedef SyncAccessTokenProvider = FutureOr<String?> Function();
typedef SyncNow = DateTime Function();

/// Platform-independent HTTP sender seam used by [HttpSyncTransport].
///
/// Tests can inject a deterministic sender without opening sockets. The
/// production implementation below uses the SDK's `dart:io` HttpClient and
/// therefore requires no additional package dependency.
abstract interface class SyncHttpRequestSender {
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  });
}

/// Minimal HTTP response value passed from the sender to the protocol layer.
final class SyncHttpResponse {
  SyncHttpResponse({
    required this.statusCode,
    required List<int> body,
    Map<String, String> headers = const {},
  }) : body = List<int>.unmodifiable(body),
       headers = Map<String, String>.unmodifiable(headers);

  final int statusCode;
  final List<int> body;
  final Map<String, String> headers;
}

/// Real mobile-capable sender backed by [dart:io]'s HttpClient.
final class IoSyncHttpRequestSender implements SyncHttpRequestSender {
  IoSyncHttpRequestSender({
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    try {
      final request = await _client.openUrl(method, uri).timeout(timeout);
      headers.forEach(request.headers.set);
      request.add(body);
      final response = await request.close().timeout(timeout);
      final responseBody = <int>[];
      await for (final chunk in response) {
        responseBody.addAll(chunk);
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = values.join(',');
      });
      return SyncHttpResponse(
        statusCode: response.statusCode,
        body: responseBody,
        headers: responseHeaders,
      );
    } on TimeoutException {
      throw const SyncNetworkException();
    } on IOException {
      throw const SyncNetworkException();
    }
  }

  /// Releases the underlying socket pool when the app no longer needs it.
  void close({bool force = false}) {
    _client.close(force: force);
  }
}

/// Performs the rotating refresh-token request used by [SyncSessionManager].
///
/// The refresh token is sent only in the request body and is never included in
/// an exception or endpoint string.
final class HttpSyncSessionRefresher implements SyncSessionRefresher {
  HttpSyncSessionRefresher({
    required Uri baseUri,
    SyncHttpRequestSender? sender,
    SyncNow? now,
  }) : _endpoint = _resolveRefreshEndpoint(baseUri),
       _sender = sender ?? IoSyncHttpRequestSender(),
       _now = now ?? _utcNow;

  final Uri _endpoint;
  final SyncHttpRequestSender _sender;
  final SyncNow _now;

  Uri get endpoint => _endpoint;

  @override
  Future<SyncSession> refresh(String refreshToken) async {
    final token = refreshToken.trim();
    if (token.isEmpty) {
      throw const SyncAuthenticationException(reason: 'refresh_token_missing');
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
        body: utf8.encode(jsonEncode(<String, String>{'refresh_token': token})),
      );
    } on SyncTransportException {
      rethrow;
    } on Object {
      throw const SyncNetworkException();
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = _httpExceptionFor(response, _endpoint);
      if (_isRefreshAuthenticationRejection(response.statusCode)) {
        throw const SyncAuthenticationException(reason: 'refresh_rejected');
      }
      throw error;
    }

    try {
      return SyncSession.fromAuthResponseJsonString(
        _decodeUtf8(response.body, 'refresh response'),
        now: _now,
      );
    } on SyncProtocolException {
      throw const SyncAuthenticationException(
        reason: 'refresh_response_invalid',
      );
    }
  }
}

/// JSON HTTP implementation of [SyncTransport] for Android and iOS.
final class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport({
    required Uri baseUri,
    SyncAccessTokenProvider? accessTokenProvider,
    SyncSessionManager? sessionManager,
    SyncHttpRequestSender? sender,
    ServerClockOffsetStore? clockOffsetStore,
    SyncNow? now,
  }) : _endpoint = _resolveEndpoint(baseUri),
       _accessTokenProvider = accessTokenProvider,
       _sessionManager = sessionManager,
       _sender = sender ?? IoSyncHttpRequestSender(),
       _clockOffsetStore = clockOffsetStore,
       _now = now ?? _utcNow {
    if (_accessTokenProvider == null && _sessionManager == null) {
      throw ArgumentError(
        'an accessTokenProvider or sessionManager is required',
      );
    }
    if (_accessTokenProvider != null && _sessionManager != null) {
      throw ArgumentError(
        'provide only one of accessTokenProvider or sessionManager',
      );
    }
  }

  final Uri _endpoint;
  final SyncAccessTokenProvider? _accessTokenProvider;
  final SyncSessionManager? _sessionManager;
  final SyncHttpRequestSender _sender;
  final ServerClockOffsetStore? _clockOffsetStore;
  final SyncNow _now;

  Uri get endpoint => _endpoint;

  @override
  Future<SyncResponse> synchronize(SyncRequest request) async {
    final token = await _readAccessToken();
    var attempt = await _sendSyncRequest(request, token);

    final sessionManager = _sessionManager;
    if (attempt.response.statusCode == 401 && sessionManager != null) {
      final replacement = await sessionManager.refreshAfterUnauthorized(token);
      // This is deliberately a single retry. A second 401 is terminal for
      // this exchange and cannot recursively trigger another refresh.
      attempt = await _sendSyncRequest(request, replacement.accessToken);
      if (attempt.response.statusCode == 401) {
        throw const SyncAuthenticationException(
          reason: 'access_token_rejected_after_refresh',
        );
      }
    }

    final response = attempt.response;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _httpException(response);
    }

    final decoded = SyncResponse.fromJsonString(
      _decodeUtf8(response.body, 'response'),
    );
    final store = _clockOffsetStore;
    if (store != null) {
      final offsetMs = ServerClockOffset.calculateMs(
        serverTime: decoded.serverTime,
        requestSentAt: attempt.sentAt,
        responseReceivedAt: attempt.receivedAt,
      );
      try {
        await store.writeOffsetMs(offsetMs);
      } on Object {
        throw const SyncClockOffsetException();
      }
    }
    return decoded;
  }

  Future<String> _readAccessToken() async {
    final String? token;
    final manager = _sessionManager;
    final provider = _accessTokenProvider;
    try {
      if (manager != null) {
        token = await manager.accessToken();
      } else if (provider != null) {
        token = await provider();
      } else {
        throw const SyncAuthenticationException(reason: 'access_token_missing');
      }
    } on SyncAuthenticationException {
      rethrow;
    } on Object {
      throw const SyncAuthenticationException(
        reason: 'session_storage_unavailable',
      );
    }
    final normalized = token?.trim();
    if (normalized == null || normalized.isEmpty) {
      throw const SyncAuthenticationException(reason: 'access_token_missing');
    }
    return normalized;
  }

  Future<_TimedSyncHttpResponse> _sendSyncRequest(
    SyncRequest request,
    String token,
  ) async {
    final sentAt = _now().toUtc();
    final SyncHttpResponse response;
    try {
      response = await _sender.send(
        method: 'POST',
        uri: _endpoint,
        headers: <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: utf8.encode(request.toJsonString()),
      );
    } on SyncTransportException {
      rethrow;
    } on Object {
      throw const SyncNetworkException();
    }
    return _TimedSyncHttpResponse(
      response: response,
      sentAt: sentAt,
      receivedAt: _now().toUtc(),
    );
  }

  SyncHttpException _httpException(SyncHttpResponse response) {
    return _httpExceptionFor(response, _endpoint);
  }
}

final class _TimedSyncHttpResponse {
  const _TimedSyncHttpResponse({
    required this.response,
    required this.sentAt,
    required this.receivedAt,
  });

  final SyncHttpResponse response;
  final DateTime sentAt;
  final DateTime receivedAt;
}

SyncHttpException _httpExceptionFor(SyncHttpResponse response, Uri endpoint) {
  SyncErrorEnvelope? envelope;
  if (response.body.isNotEmpty) {
    try {
      envelope = SyncErrorEnvelope.fromJsonString(
        _decodeUtf8(response.body, 'error'),
      );
    } on SyncProtocolException {
      // HTTP status remains the reliable classification. Do not expose the
      // raw body because it may contain credentials or sensitive payloads.
    } on FormatException {
      // Same redaction rule for invalid UTF-8 error bodies.
    }
  }
  return SyncHttpException(
    statusCode: response.statusCode,
    kind: _classifyStatus(response.statusCode),
    errorCode: envelope?.error,
    minimumSupportedVersion: envelope?.minimumSupportedVersion,
    endpoint: _redactedUri(endpoint),
  );
}

bool _isRefreshAuthenticationRejection(int statusCode) {
  return statusCode >= 400 &&
      statusCode <= 499 &&
      statusCode != 408 &&
      statusCode != 429;
}

String _decodeUtf8(List<int> body, String field) {
  try {
    return utf8.decode(body, allowMalformed: false);
  } on FormatException {
    throw SyncProtocolException(
      SyncProtocolErrorKind.malformedJson,
      'contains invalid UTF-8',
      field: field,
    );
  }
}

SyncHttpErrorKind _classifyStatus(int statusCode) {
  return switch (statusCode) {
    401 => SyncHttpErrorKind.unauthorized,
    403 => SyncHttpErrorKind.forbidden,
    408 => SyncHttpErrorKind.requestTimeout,
    429 => SyncHttpErrorKind.rateLimited,
    >= 500 && <= 599 => SyncHttpErrorKind.server,
    >= 400 && <= 499 => SyncHttpErrorKind.client,
    _ => SyncHttpErrorKind.unexpected,
  };
}

Uri _resolveEndpoint(Uri baseUri) {
  if (baseUri.scheme != 'http' && baseUri.scheme != 'https') {
    throw ArgumentError.value(baseUri, 'baseUri', 'must use HTTP or HTTPS');
  }
  if (baseUri.host.isEmpty) {
    throw ArgumentError.value(baseUri, 'baseUri', 'must include a host');
  }
  final path = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  final endpointPath = path.endsWith('/v1/sync')
      ? path
      : path.endsWith('/v1')
      ? '$path/sync'
      : '${path.isEmpty ? '' : path}/v1/sync';
  return baseUri.replace(
    path: endpointPath,
    queryParameters: const <String, String>{},
    fragment: '',
    userInfo: '',
  );
}

Uri _resolveRefreshEndpoint(Uri baseUri) {
  if (baseUri.scheme != 'http' && baseUri.scheme != 'https') {
    throw ArgumentError.value(baseUri, 'baseUri', 'must use HTTP or HTTPS');
  }
  if (baseUri.host.isEmpty) {
    throw ArgumentError.value(baseUri, 'baseUri', 'must include a host');
  }
  var rootPath = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  for (final suffix in const ['/v1/sync', '/v1/health', '/v1']) {
    if (rootPath.endsWith(suffix)) {
      rootPath = rootPath.substring(0, rootPath.length - suffix.length);
      break;
    }
  }
  return baseUri.replace(
    path: '${rootPath.isEmpty ? '' : rootPath}/v1/auth/refresh',
    queryParameters: const <String, String>{},
    fragment: '',
    userInfo: '',
  );
}

String _redactedUri(Uri uri) {
  return uri
      .replace(
        queryParameters: const <String, String>{},
        fragment: '',
        userInfo: '',
      )
      .toString();
}

DateTime _utcNow() => DateTime.now().toUtc();
