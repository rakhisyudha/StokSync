import 'package:sync_engine/sync_engine.dart';

/// Performs a real service check before a trigger is allowed to sync.
abstract interface class SyncReachabilityProbe {
  Future<bool> check();
}

/// Authenticated, lightweight health check for the app-side coordinator.
///
/// The access token is sent in the same header used by sync. The server health
/// route may be lightweight, but interface state alone never marks the service
/// reachable. Missing tokens, transport failures, and non-2xx responses all
/// return `false` without exposing the underlying error to the UI.
final class AuthenticatedHealthReachability implements SyncReachabilityProbe {
  AuthenticatedHealthReachability({
    required Uri baseUri,
    required SyncAccessTokenProvider accessTokenProvider,
    SyncHttpRequestSender? sender,
  }) : _endpoint = _resolveHealthEndpoint(baseUri),
       _accessTokenProvider = accessTokenProvider,
       _sender = sender ?? IoSyncHttpRequestSender();

  final Uri _endpoint;
  final SyncAccessTokenProvider _accessTokenProvider;
  final SyncHttpRequestSender _sender;

  Uri get endpoint => _endpoint;

  @override
  Future<bool> check() async {
    final String? token;
    try {
      token = (await _accessTokenProvider())?.trim();
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
