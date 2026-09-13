import 'package:sync_engine/sync_engine.dart';

/// Performs a real service check before a trigger is allowed to sync.
abstract interface class SyncReachabilityProbe {
  Future<bool> check();
}

/// Authenticated, lightweight health check for the app-side coordinator.
///
/// The access token is sent in the same header used by sync. The server health
/// route may be lightweight, but interface state alone never marks the service
/// reachable. A legacy token provider treats missing tokens, transport
/// failures, and non-2xx responses as unreachable. A session-aware probe lets
/// authentication failures enter the sync engine so refresh and durable
/// blocked-state handling cannot be bypassed.
final class AuthenticatedHealthReachability implements SyncReachabilityProbe {
  AuthenticatedHealthReachability({
    required Uri baseUri,
    SyncAccessTokenProvider? accessTokenProvider,
    SyncSessionManager? sessionManager,
    SyncHttpRequestSender? sender,
  }) : _endpoint = _resolveHealthEndpoint(baseUri),
       _accessTokenProvider = accessTokenProvider,
       _sessionManager = sessionManager,
       _sender = sender ?? IoSyncHttpRequestSender() {
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

  Uri get endpoint => _endpoint;

  @override
  Future<bool> check() async {
    final String? token;
    final manager = _sessionManager;
    final provider = _accessTokenProvider;
    try {
      if (manager != null) {
        token = (await manager.accessToken())?.trim();
      } else if (provider != null) {
        token = (await provider())?.trim();
      } else {
        return false;
      }
    } on SyncAuthenticationException {
      // With a session manager, authentication failure is still a reason to
      // enter the sync engine: it records durable blocked state without
      // touching local data. A legacy token provider has no refresh path and
      // retains the old unreachable behavior.
      return _sessionManager != null;
    } on Object {
      return false;
    }
    if (token == null || token.isEmpty) {
      return false;
    }

    try {
      final response = await _sender.send(
        method: 'GET',
        uri: _endpoint,
        headers: <String, String>{
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: const <int>[],
      );
      // A 401 proves that the service is reachable. When a session manager
      // is present, let the sync transport perform its single refresh/retry
      // flow instead of hiding the opportunity behind a false reachability
      // result.
      if (response.statusCode == 401 && _sessionManager != null) {
        return true;
      }
      return response.statusCode >= 200 && response.statusCode < 300;
    } on Object {
      return false;
    }
  }
}

Uri _resolveHealthEndpoint(Uri baseUri) {
  if (baseUri.scheme != 'http' && baseUri.scheme != 'https') {
    throw ArgumentError.value(baseUri, 'baseUri', 'must use HTTP or HTTPS');
  }
  if (baseUri.host.isEmpty) {
    throw ArgumentError.value(baseUri, 'baseUri', 'must include a host');
  }

  final path = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  final rootPath = path.endsWith('/v1/sync')
      ? path.substring(0, path.length - '/v1/sync'.length)
      : path.endsWith('/v1/health')
      ? path.substring(0, path.length - '/v1/health'.length)
      : path.endsWith('/v1')
      ? path.substring(0, path.length - '/v1'.length)
      : path;
  final healthPath = '${rootPath.isEmpty ? '' : rootPath}/v1/health';
  return baseUri.replace(
    path: healthPath,
    queryParameters: const <String, String>{},
    fragment: '',
    userInfo: '',
  );
}
