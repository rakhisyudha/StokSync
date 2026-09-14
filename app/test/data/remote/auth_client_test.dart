import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/diagnostics/diagnostics.dart';
import 'package:stoksync/data/remote/auth_client.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('HttpAuthClient', () {
    test('posts login credentials and decodes the returned session', () async {
      final diagnosticLines = <String>[];
      final sender = _RecordingSender(_successResponse(statusCode: 200));
      final client = HttpAuthClient(
        baseUri: Uri.parse(
          'https://example.test/api/v1/sync?secret=must-not-be-retained',
        ),
        sender: sender,
        diagnostics: AppDiagnostics(writer: diagnosticLines.add),
        now: () => DateTime.utc(2026, 9, 13, 10, 2, 14),
      );

      final session = await client.login(
        email: 'owner@example.test',
        password: 'correct horse battery staple',
        deviceId: _deviceId,
        deviceName: 'Test phone',
        platform: 'android',
      );

      expect(
        client.endpoint,
        Uri.parse('https://example.test/api/v1/auth/login'),
      );
      expect(sender.method, 'POST');
      expect(sender.uri, client.endpoint);
      expect(sender.headers?['Authorization'], isNull);
      expect(jsonDecode(utf8.decode(sender.body!)), <String, String>{
        'email': 'owner@example.test',
        'password': 'correct horse battery staple',
        'device_id': _deviceId,
        'device_name': 'Test phone',
        'platform': 'android',
      });
      expect(session.accessToken, 'access-token');
      expect(
        session.accessTokenExpiresAt,
        DateTime.utc(2026, 9, 13, 10, 17, 14),
      );
      expect(diagnosticLines.single, contains('"event":"auth.login"'));
      expect(diagnosticLines.single, contains('"outcome":"succeeded"'));
      expect(diagnosticLines.single, isNot(contains('correct horse')));
      expect(diagnosticLines.single, isNot(contains('access-token')));
      expect(diagnosticLines.single, isNot(contains('refresh-token')));
    });

    test(
      'posts registration credentials and decodes a created session',
      () async {
        final diagnosticLines = <String>[];
        final sender = _RecordingSender(_successResponse(statusCode: 201));
        final client = HttpAuthClient(
          baseUri: Uri.parse('https://example.test/v1/auth/login'),
          sender: sender,
          diagnostics: AppDiagnostics(writer: diagnosticLines.add),
          now: () => DateTime.utc(2026, 9, 13, 10, 2, 14),
        );

        final session = await client.register(
          email: 'new.owner@example.test',
          password: 'correct horse battery staple',
          deviceId: _deviceId,
          deviceName: 'Test phone',
          platform: 'android',
        );

        expect(
          client.registerEndpoint,
          Uri.parse('https://example.test/v1/auth/register'),
        );
        expect(sender.method, 'POST');
        expect(sender.uri, client.registerEndpoint);
        expect(jsonDecode(utf8.decode(sender.body!)), <String, String>{
          'email': 'new.owner@example.test',
          'password': 'correct horse battery staple',
          'device_id': _deviceId,
          'device_name': 'Test phone',
          'platform': 'android',
        });
        expect(session.accessToken, 'access-token');
        expect(diagnosticLines.single, contains('"event":"auth.register"'));
        expect(diagnosticLines.single, isNot(contains('correct horse')));
        expect(diagnosticLines.single, isNot(contains('access-token')));
      },
    );

    test(
      'maps a server credential rejection without exposing response data',
      () async {
        final sender = _RecordingSender(
          SyncHttpResponse(
            statusCode: 401,
            body: utf8.encode(
              '{"error":"invalid_credentials","token":"do-not-expose"}',
            ),
          ),
        );
        final client = HttpAuthClient(
          baseUri: Uri.parse('https://example.test'),
          sender: sender,
        );

        await expectLater(
          client.login(
            email: 'owner@example.test',
            password: 'wrong',
            deviceId: _deviceId,
          ),
          throwsA(
            isA<AuthClientException>()
                .having(
                  (error) => error.reason,
                  'reason',
                  'invalid_credentials',
                )
                .having(
                  (error) => error.toString(),
                  'safe text',
                  isNot(contains('do-not-expose')),
                ),
          ),
        );
      },
    );
  });

  test(
    'AuthSessionController stores only after a successful login response',
    () async {
      final store = _MemorySessionStore();
      final controller = _controllerFor(
        store: store,
        sender: _RecordingSender(_successResponse(statusCode: 200)),
      );

      final session = await controller.login(
        email: 'owner@example.test',
        password: 'password',
        deviceId: _deviceId,
      );

      expect(store.session, same(session));
    },
  );

  test(
    'AuthSessionController stores only after a successful registration response',
    () async {
      final store = _MemorySessionStore();
      final controller = _controllerFor(
        store: store,
        sender: _RecordingSender(_successResponse(statusCode: 201)),
      );

      final session = await controller.register(
        email: 'new.owner@example.test',
        password: 'password',
        deviceId: _deviceId,
      );

      expect(store.session, same(session));
    },
  );
}

const _deviceId = '0192f200-0000-7000-8000-000000000002';

AuthSessionController _controllerFor({
  required _MemorySessionStore store,
  required SyncHttpRequestSender sender,
}) {
  return AuthSessionController(
    client: HttpAuthClient(
      baseUri: Uri.parse('https://example.test'),
      sender: sender,
    ),
    sessionStore: store,
  );
}

SyncHttpResponse _successResponse({required int statusCode}) {
  return SyncHttpResponse(
    statusCode: statusCode,
    body: utf8.encode(
      jsonEncode(<String, Object?>{
        'access_token': 'access-token',
        'token_type': 'Bearer',
        'expires_in': 900,
        'refresh_token': 'refresh-token',
        'user_id': '0192f200-0000-7000-8000-000000000001',
        'device_id': _deviceId,
      }),
    ),
  );
}

final class _RecordingSender implements SyncHttpRequestSender {
  _RecordingSender(this.response);

  final SyncHttpResponse response;
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
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    this.body = body;
    return response;
  }
}

final class _MemorySessionStore implements SyncSessionStore {
  SyncSession? session;

  @override
  Future<SyncSession?> readSession() async => session;

  @override
  Future<void> writeSession(SyncSession session) async {
    this.session = session;
  }
}
