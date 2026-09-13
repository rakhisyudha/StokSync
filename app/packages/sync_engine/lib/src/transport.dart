import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'clock.dart';
import 'errors.dart';
import 'protocol.dart';

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

/// JSON HTTP implementation of [SyncTransport] for Android and iOS.
final class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport({
    required Uri baseUri,
    required SyncAccessTokenProvider accessTokenProvider,
    SyncHttpRequestSender? sender,
    ServerClockOffsetStore? clockOffsetStore,
    SyncNow? now,
  }) : _endpoint = _resolveEndpoint(baseUri),
       _accessTokenProvider = accessTokenProvider,
       _sender = sender ?? IoSyncHttpRequestSender(),
       _clockOffsetStore = clockOffsetStore,
       _now = now ?? _utcNow;

  final Uri _endpoint;
  final SyncAccessTokenProvider _accessTokenProvider;
  final SyncHttpRequestSender _sender;
  final ServerClockOffsetStore? _clockOffsetStore;
  final SyncNow _now;

  Uri get endpoint => _endpoint;

  @override
  Future<SyncResponse> synchronize(SyncRequest request) async {
    final String? token;
    try {
      token = (await _accessTokenProvider())?.trim();
    } on Object {
      throw const SyncAuthenticationException();
    }
    if (token == null || token.isEmpty) {
      throw const SyncAuthenticationException();
    }

    final requestBody = utf8.encode(request.toJsonString());
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
        body: requestBody,
      );
    } on SyncTransportException {
      rethrow;
    } on Object {
      throw const SyncNetworkException();
    }
    final receivedAt = _now().toUtc();

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
        requestSentAt: sentAt,
        responseReceivedAt: receivedAt,
      );
      try {
        await store.writeOffsetMs(offsetMs);
      } on Object {
        throw const SyncClockOffsetException();
      }
    }
    return decoded;
  }

  SyncHttpException _httpException(SyncHttpResponse response) {
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
      endpoint: _redactedUri(_endpoint),
    );
  }
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
      : '${path.isEmpty ? '' : path}/v1/sync';
  return baseUri.replace(
    path: endpointPath,
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
