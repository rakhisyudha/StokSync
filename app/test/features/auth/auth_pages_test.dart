import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/remote/auth_client.dart';
import 'package:stoksync/features/auth/auth_pages.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  testWidgets('login gate stores the session before showing the app', (
    tester,
  ) async {
    final store = _MemorySessionStore();
    final controller = AuthSessionController(
      client: HttpAuthClient(
        baseUri: Uri.parse('https://example.test'),
        sender: _LoginSender(),
        now: () => DateTime.utc(2026, 9, 13, 10, 2, 14),
      ),
      sessionStore: store,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: AuthenticatedSessionGate(
          sessionStore: store,
          controller: controller,
          deviceId: _deviceId,
          authenticatedChild: const Text('Inventory'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login-email-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('login-email-field')),
      'owner@example.test',
    );
    await tester.enterText(
      find.byKey(const Key('login-password-field')),
      'password',
    );
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Inventory'), findsOneWidget);
    expect(store.session?.accessToken, 'access-token');
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000002';

final class _MemorySessionStore implements SyncSessionStore {
  SyncSession? session;

  @override
  Future<SyncSession?> readSession() async => session;

  @override
  Future<void> writeSession(SyncSession session) async {
    this.session = session;
  }
}

final class _LoginSender implements SyncHttpRequestSender {
  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    return SyncHttpResponse(
      statusCode: 200,
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
}
