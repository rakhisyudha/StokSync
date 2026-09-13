import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/features/sync/sync_reachability.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('AuthenticatedHealthReachability', () {
    test('sends an authenticated health request and accepts 2xx', () async {
      final sender = _RecordingSender(
        SyncHttpResponse(statusCode: 200, body: <int>[]),
      );
      final probe = AuthenticatedHealthReachability(
        baseUri: Uri.parse(
          'https://example.test/api/v1/sync?token=must-not-be-retained',
        ),
        accessTokenProvider: () async => 'access-token',
        sender: sender,
      );

      expect(await probe.check(), isTrue);
      expect(sender.method, 'GET');
      expect(sender.uri?.path, '/api/v1/health');
      expect(sender.uri?.query, isEmpty);
      expect(sender.headers?['Accept'], 'application/json');
      expect(sender.headers?['Authorization'], 'Bearer access-token');
      expect(sender.body, isEmpty);
    });

    test(
      'treats a 401 as reachable when session-aware sync can refresh',
      () async {
        final session = SyncSession(
          accessToken: 'access-token',
          refreshToken: 'refresh-token',
          userId: '0192f1a0-0000-7000-8000-000000000001',
          deviceId: '0192f200-0000-7000-8000-000000000001',
          accessTokenExpiresAt: DateTime.utc(2026, 9, 13, 10, 17),
        );
        final probe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          sessionManager: SyncSessionManager(
            store: _SessionStore(session),
            refresher: _SessionRefresher(session),
          ),
          sender: _RecordingSender(
            SyncHttpResponse(statusCode: 401, body: <int>[]),
          ),
        );

        expect(await probe.check(), isTrue);
      },
    );

    test(
      'lets a missing session reach the engine so it can persist blocked state',
      () async {
        final sender = _RecordingSender(
          SyncHttpResponse(statusCode: 200, body: <int>[]),
        );
        final probe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          sessionManager: SyncSessionManager(
            store: _SessionStore(null),
            refresher: _SessionRefresher(_sessionForTest()),
          ),
          sender: sender,
        );

        expect(await probe.check(), isTrue);
        expect(sender.called, isFalse);
      },
    );

    test(
      'treats missing token, failures, and non-2xx as unreachable',
      () async {
        final missingTokenSender = _RecordingSender(
          SyncHttpResponse(statusCode: 200, body: <int>[]),
        );
        final missingTokenProbe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => null,
          sender: missingTokenSender,
        );
        expect(await missingTokenProbe.check(), isFalse);
        expect(missingTokenSender.called, isFalse);

        final serverFailureProbe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => 'token',
          sender: _RecordingSender(
            SyncHttpResponse(statusCode: 503, body: <int>[]),
          ),
        );
        expect(await serverFailureProbe.check(), isFalse);

        final networkFailureProbe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => 'token',
          sender: _ThrowingSender(),
        );
        expect(await networkFailureProbe.check(), isFalse);
      },
    );
  });
}

final class _RecordingSender implements SyncHttpRequestSender {
  _RecordingSender(this.response);

  final SyncHttpResponse response;
  var called = false;
  String? method;
  Uri? uri;
  Map<String, String>? headers;
  List<int>? body;

  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    called = true;
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    this.body = body;
    return response;
  }
}

final class _ThrowingSender implements SyncHttpRequestSender {
  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) {
    throw const SyncNetworkException();
  }
}

SyncSession _sessionForTest() {
  return SyncSession(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    userId: '0192f1a0-0000-7000-8000-000000000001',
    deviceId: '0192f200-0000-7000-8000-000000000001',
    accessTokenExpiresAt: DateTime.utc(2026, 9, 13, 10, 17),
  );
}

final class _SessionStore implements SyncSessionStore {
  _SessionStore(this.session);

  final SyncSession? session;

  @override
  Future<SyncSession?> readSession() async => session;

  @override
  Future<void> writeSession(SyncSession value) async {}
}

final class _SessionRefresher implements SyncSessionRefresher {
  _SessionRefresher(this.session);

  final SyncSession session;

  @override
  Future<SyncSession> refresh(String refreshToken) async => session;
}
