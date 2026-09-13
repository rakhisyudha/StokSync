import 'dart:async';
import 'dart:convert';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  group('HttpSyncTransport session refresh', () {
    test(
      'refreshes once, persists the replacement, and retries the request',
      () async {
        final oldSession = _session('old-access', 'old-refresh');
        final replacement = _session('new-access', 'new-refresh');
        final store = _MemorySessionStore(oldSession);
        final refresher = _FakeRefresher(replacement);
        final sender = _ScriptedSender([
          SyncHttpResponse(statusCode: 401, body: <int>[]),
          _successResponse(),
        ]);
        final transport = _transport(
          store: store,
          refresher: refresher,
          sender: sender,
        );

        final response = await transport.synchronize(_request());

        expect(response.nextCursor, 0);
        expect(sender.calls, 2);
        expect(sender.headersAt(0)['Authorization'], 'Bearer old-access');
        expect(sender.headersAt(1)['Authorization'], 'Bearer new-access');
        expect(refresher.calls, 1);
        expect(refresher.tokens, ['old-refresh']);
        expect(store.session?.accessToken, 'new-access');
        expect(store.session?.refreshToken, 'new-refresh');
        expect(sender.uris.every((uri) => uri.path == '/api/v1/sync'), isTrue);
      },
    );

    test(
      'does not recurse when the retried request is still unauthorized',
      () async {
        final store = _MemorySessionStore(
          _session('old-access', 'old-refresh'),
        );
        final refresher = _FakeRefresher(_session('new-access', 'new-refresh'));
        final sender = _ScriptedSender([
          SyncHttpResponse(statusCode: 401, body: <int>[]),
          SyncHttpResponse(statusCode: 401, body: <int>[]),
        ]);
        final transport = _transport(
          store: store,
          refresher: refresher,
          sender: sender,
        );

        await expectLater(
          transport.synchronize(_request()),
          throwsA(
            isA<SyncAuthenticationException>().having(
              (error) => error.reason,
              'reason',
              'access_token_rejected_after_refresh',
            ),
          ),
        );

        expect(sender.calls, 2);
        expect(refresher.calls, 1);
      },
    );

    test(
      'concurrent unauthorized requests share one refresh exchange',
      () async {
        final store = _MemorySessionStore(
          _session('old-access', 'old-refresh'),
        );
        final refresher = _BlockingRefresher(
          _session('new-access', 'new-refresh'),
        );
        final sender = _ScriptedSender([
          SyncHttpResponse(statusCode: 401, body: <int>[]),
          SyncHttpResponse(statusCode: 401, body: <int>[]),
          _successResponse(),
          _successResponse(),
        ]);
        final transport = _transport(
          store: store,
          refresher: refresher,
          sender: sender,
        );

        final first = transport.synchronize(_request());
        await _waitUntil(() => refresher.calls == 1);
        final second = transport.synchronize(_request());
        await _waitUntil(() => sender.calls >= 2);

        refresher.release();
        await Future.wait([first, second]);

        expect(refresher.calls, 1);
        expect(sender.calls, 4);
        expect(sender.headersAt(2)['Authorization'], 'Bearer new-access');
        expect(sender.headersAt(3)['Authorization'], 'Bearer new-access');
      },
    );

    test(
      'missing or rejected refresh credentials block without another retry',
      () async {
        final missingSender = _ScriptedSender(const []);
        final missingTransport = HttpSyncTransport(
          baseUri: Uri.parse('https://example.test/api/v1'),
          sessionManager: SyncSessionManager(
            store: _MemorySessionStore(null),
            refresher: _FakeRefresher(_session('unused', 'unused')),
          ),
          sender: missingSender,
        );

        await expectLater(
          missingTransport.synchronize(_request()),
          throwsA(
            isA<SyncAuthenticationException>().having(
              (error) => error.reason,
              'reason',
              'session_missing',
            ),
          ),
        );
        expect(missingSender.calls, 0);

        final rejectedSender = _ScriptedSender([
          SyncHttpResponse(statusCode: 401, body: <int>[]),
        ]);
        final rejectedTransport = _transport(
          store: _MemorySessionStore(_session('old-access', 'old-refresh')),
          refresher: _RejectingRefresher(),
          sender: rejectedSender,
        );

        await expectLater(
          rejectedTransport.synchronize(_request()),
          throwsA(
            isA<SyncAuthenticationException>().having(
              (error) => error.reason,
              'reason',
              'refresh_rejected',
            ),
          ),
        );
        expect(rejectedSender.calls, 1);
      },
    );
  });

  group('HttpSyncSessionRefresher', () {
    test(
      'posts the opaque refresh token and decodes the replacement session',
      () async {
        final sender = _ScriptedSender([
          SyncHttpResponse(
            statusCode: 200,
            body: utf8.encode(
              jsonEncode(<String, Object?>{
                'access_token': 'new-access',
                'token_type': 'Bearer',
                'expires_in': 900,
                'refresh_token': 'new-refresh',
                'user_id': _userId,
                'device_id': _deviceId,
              }),
            ),
          ),
        ]);
        final refresher = HttpSyncSessionRefresher(
          baseUri: Uri.parse('https://example.test/api/v1/sync?token=ignored'),
          sender: sender,
          now: () => DateTime.utc(2026, 9, 13, 10, 2),
        );

        final session = await refresher.refresh('old-refresh');
        final body = jsonDecode(utf8.decode(sender.bodies.single)) as Map;

        expect(refresher.endpoint.path, '/api/v1/auth/refresh');
        expect(sender.methods.single, 'POST');
        expect(sender.headersAt(0)['Authorization'], isNull);
        expect(body, {'refresh_token': 'old-refresh'});
        expect(session.accessToken, 'new-access');
        expect(session.accessTokenExpiresAt, DateTime.utc(2026, 9, 13, 10, 17));
      },
    );
  });
}

const _userId = '0192f1a0-0000-7000-8000-000000000001';
const _deviceId = '0192f200-0000-7000-8000-000000000001';

SyncRequest _request() {
  return SyncRequest(
    deviceId: _deviceId,
    cursor: 0,
    maxChanges: 10,
    clientTime: DateTime.utc(2026, 9, 13, 10, 2),
    operations: const [],
  );
}

SyncHttpResponse _successResponse() {
  return SyncHttpResponse(
    statusCode: 200,
    body: utf8.encode(
      jsonEncode(<String, Object?>{
        'schema_version': syncSchemaVersion,
        'results': const <Object?>[],
        'changes': const <Object?>[],
        'next_cursor': 0,
        'has_more': false,
        'server_time': '2026-09-13T10:02:01Z',
      }),
    ),
  );
}

SyncSession _session(String accessToken, String refreshToken) {
  return SyncSession(
    accessToken: accessToken,
    refreshToken: refreshToken,
    userId: _userId,
    deviceId: _deviceId,
    accessTokenExpiresAt: DateTime.utc(2026, 9, 13, 10, 17),
  );
}

HttpSyncTransport _transport({
  required _MemorySessionStore store,
  required SyncSessionRefresher refresher,
  required _ScriptedSender sender,
}) {
  return HttpSyncTransport(
    baseUri: Uri.parse('https://example.test/api/v1'),
    sessionManager: SyncSessionManager(store: store, refresher: refresher),
    sender: sender,
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for the condition.');
}

final class _MemorySessionStore implements SyncSessionStore {
  _MemorySessionStore(this.session);

  SyncSession? session;

  @override
  Future<SyncSession?> readSession() async => session;

  @override
  Future<void> writeSession(SyncSession value) async {
    session = value;
  }
}

class _FakeRefresher implements SyncSessionRefresher {
  _FakeRefresher(this.replacement);

  final SyncSession replacement;
  var calls = 0;
  final List<String> tokens = <String>[];

  @override
  Future<SyncSession> refresh(String refreshToken) async {
    calls++;
    tokens.add(refreshToken);
    return replacement;
  }
}

final class _BlockingRefresher extends _FakeRefresher {
  _BlockingRefresher(super.replacement);

  final Completer<void> _release = Completer<void>();

  @override
  Future<SyncSession> refresh(String refreshToken) async {
    calls++;
    tokens.add(refreshToken);
    await _release.future;
    return replacement;
  }

  void release() => _release.complete();
}

final class _RejectingRefresher implements SyncSessionRefresher {
  @override
  Future<SyncSession> refresh(String refreshToken) {
    throw const SyncAuthenticationException(reason: 'refresh_rejected');
  }
}

final class _ScriptedSender implements SyncHttpRequestSender {
  _ScriptedSender(Iterable<SyncHttpResponse> responses)
    : _responses = responses.toList(growable: false);

  final List<SyncHttpResponse> _responses;
  final List<String> methods = <String>[];
  final List<Uri> uris = <Uri>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];
  final List<List<int>> bodies = <List<int>>[];
  var calls = 0;

  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    final index = calls++;
    methods.add(method);
    uris.add(uri);
    this.headers.add(Map<String, String>.from(headers));
    bodies.add(List<int>.from(body));
    if (index >= _responses.length) {
      throw StateError('unexpected sender call');
    }
    return _responses[index];
  }

  Map<String, String> headersAt(int index) => headers[index];
}
