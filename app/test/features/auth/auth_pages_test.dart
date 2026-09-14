import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/theme/app_theme.dart';
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

  testWidgets('login page presents the themed hierarchy and input actions', (
    tester,
  ) async {
    await _pumpLoginPage(tester, sender: _LoginSender());

    expect(find.byKey(const Key('login-brand-mark')), findsOneWidget);
    expect(find.byKey(const Key('login-title')), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('you@example.com'), findsOneWidget);
    expect(find.byIcon(Icons.alternate_email), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);

    final emailField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('login-email-field')),
        matching: find.byType(TextField),
      ),
    );
    expect(emailField.keyboardType, TextInputType.emailAddress);
    expect(emailField.textInputAction, TextInputAction.next);
    expect(emailField.autofillHints, contains(AutofillHints.email));
    expect(emailField.decoration?.filled, isTrue);

    final passwordField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('login-password-field')),
        matching: find.byType(TextField),
      ),
    );
    expect(passwordField.textInputAction, TextInputAction.done);
    expect(passwordField.obscureText, isTrue);
    expect(passwordField.autofillHints, contains(AutofillHints.password));

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('login-submit-button')),
    );
    expect(button.child, isA<AnimatedSwitcher>());
  });

  testWidgets('login page keeps the hierarchy readable in dark mode', (
    tester,
  ) async {
    await _pumpLoginPage(
      tester,
      sender: _LoginSender(),
      brightness: Brightness.dark,
    );

    final title = tester.widget<Text>(find.byKey(const Key('login-title')));
    expect(
      title.style?.color,
      buildStokSyncTheme(Brightness.dark).colorScheme.onSurface,
    );
  });

  testWidgets('login page exposes a themed loading state while signing in', (
    tester,
  ) async {
    final sender = _BlockingSender();
    await _pumpLoginPage(tester, sender: sender);
    await _enterCredentials(tester);

    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pump();

    expect(find.byKey(const Key('login-loading')), findsOneWidget);
    expect(find.byKey(const Key('login-loading-indicator')), findsOneWidget);
    expect(find.text('Signing in…'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('login-submit-button')),
    );
    expect(button.onPressed, isNull);

    sender.response.complete(_successResponse());
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets(
    'login page renders authentication errors in an accessible banner',
    (tester) async {
      await _pumpLoginPage(tester, sender: _InvalidCredentialsSender());
      await _enterCredentials(tester);

      await tester.tap(find.byKey(const Key('login-submit-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('login-error-banner')), findsOneWidget);
      expect(find.text('The email or password is incorrect.'), findsOneWidget);
      expect(find.byKey(const Key('login-error')), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('login-submit-button')),
      );
      expect(button.onPressed, isNotNull);
    },
  );
}

const _deviceId = '0192f200-0000-7000-8000-000000000002';

Future<void> _pumpLoginPage(
  WidgetTester tester, {
  required SyncHttpRequestSender sender,
  Brightness brightness = Brightness.light,
}) async {
  final store = _MemorySessionStore();
  final controller = AuthSessionController(
    client: HttpAuthClient(
      baseUri: Uri.parse('https://example.test'),
      sender: sender,
      now: () => DateTime.utc(2026, 9, 13, 10, 2, 14),
    ),
    sessionStore: store,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: buildStokSyncTheme(brightness),
      home: LoginPage(
        controller: controller,
        deviceId: _deviceId,
        onLoggedIn: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _enterCredentials(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('login-email-field')),
    'owner@example.test',
  );
  await tester.enterText(
    find.byKey(const Key('login-password-field')),
    'password',
  );
}

SyncHttpResponse _successResponse() {
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

final class _BlockingSender implements SyncHttpRequestSender {
  final response = Completer<SyncHttpResponse>();

  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) => response.future;
}

final class _InvalidCredentialsSender implements SyncHttpRequestSender {
  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    return SyncHttpResponse(
      statusCode: 401,
      body: utf8.encode(
        jsonEncode(<String, String>{'error': 'invalid_credentials'}),
      ),
    );
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
