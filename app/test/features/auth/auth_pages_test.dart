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
    final controller = _controller(store: store, sender: _LoginSender());

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

    await _enterLoginCredentials(tester);
    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Inventory'), findsOneWidget);
    expect(store.session?.accessToken, 'access-token');
  });

  testWidgets(
    'registration validates confirmation and opens the app with its stored session',
    (tester) async {
      final store = _MemorySessionStore();
      final sender = _RecordingSender(_successResponse(statusCode: 201));
      final controller = _controller(store: store, sender: sender);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildStokSyncTheme(Brightness.light),
          home: AuthenticatedSessionGate(
            sessionStore: store,
            controller: controller,
            deviceId: _deviceId,
            deviceName: 'Pixel 8a',
            platform: 'android',
            authenticatedChild: const Text('Inventory'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final createAccountLink = find.byKey(
        const Key('login-create-account-link'),
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(createAccountLink);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('register-title')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('register-email-field')),
        'new.owner@example.test',
      );
      await tester.enterText(
        find.byKey(const Key('register-password-field')),
        'password',
      );
      await tester.enterText(
        find.byKey(const Key('register-confirm-password-field')),
        'different',
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -250));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('register-submit-button')));
      await tester.pumpAndSettle();

      expect(find.text('Passwords do not match.'), findsOneWidget);
      expect(sender.uri, isNull);

      await tester.enterText(
        find.byKey(const Key('register-confirm-password-field')),
        'password',
      );
      await tester.tap(find.byKey(const Key('register-submit-button')));
      await tester.pumpAndSettle();

      expect(sender.uri, Uri.parse('https://example.test/v1/auth/register'));
      expect(find.text('Inventory'), findsOneWidget);
      expect(store.session?.accessToken, 'access-token');
    },
  );

  testWidgets(
    'registration page returns to sign in through its account prompt',
    (tester) async {
      var signInTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildStokSyncTheme(Brightness.light),
          home: RegistrationPage(
            controller: _controller(
              store: _MemorySessionStore(),
              sender: _LoginSender(),
            ),
            deviceId: _deviceId,
            onRegistered: (_) {},
            onSignIn: () => signInTapped = true,
          ),
        ),
      );

      await tester.pumpAndSettle();
      final signInLink = find.byKey(const Key('register-sign-in-link'));
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(signInLink);
      expect(signInTapped, isTrue);
    },
  );

  testWidgets('login page presents the themed hierarchy and input actions', (
    tester,
  ) async {
    await _pumpLoginPage(tester, sender: _LoginSender());

    expect(find.byKey(const Key('login-brand-mark')), findsOneWidget);
    expect(find.byKey(const Key('login-title')), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('you@example.com'), findsOneWidget);
    expect(find.byIcon(Icons.alternate_email), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);

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

  testWidgets(
    'login page keeps headers and editable text readable in dark mode',
    (tester) async {
      await _pumpLoginPage(
        tester,
        sender: _LoginSender(),
        brightness: Brightness.dark,
      );

      final theme = buildStokSyncTheme(Brightness.dark);
      final title = tester.widget<Text>(find.byKey(const Key('login-title')));
      final emailField = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('login-email-field')),
          matching: find.byType(TextField),
        ),
      );
      expect(title.style?.color, theme.colorScheme.onSurface);
      expect(emailField.style?.color, theme.colorScheme.onSurface);
    },
  );

  testWidgets('login page exposes a themed loading state while signing in', (
    tester,
  ) async {
    final sender = _BlockingSender();
    await _pumpLoginPage(tester, sender: sender);
    await _enterLoginCredentials(tester);

    await tester.tap(find.byKey(const Key('login-submit-button')));
    await tester.pump();

    expect(find.byKey(const Key('login-loading')), findsOneWidget);
    expect(find.byKey(const Key('login-loading-indicator')), findsOneWidget);
    expect(find.text('Signing in…'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('login-submit-button')),
    );
    expect(button.onPressed, isNull);

    sender.response.complete(_successResponse(statusCode: 200));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets(
    'login page renders authentication errors in an accessible banner',
    (tester) async {
      await _pumpLoginPage(tester, sender: _InvalidCredentialsSender());
      await _enterLoginCredentials(tester);

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

AuthSessionController _controller({
  required SyncSessionStore store,
  required SyncHttpRequestSender sender,
}) {
  return AuthSessionController(
    client: HttpAuthClient(
      baseUri: Uri.parse('https://example.test'),
      sender: sender,
      now: () => DateTime.utc(2026, 9, 13, 10, 2, 14),
    ),
    sessionStore: store,
  );
}

Future<void> _pumpLoginPage(
  WidgetTester tester, {
  required SyncHttpRequestSender sender,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildStokSyncTheme(brightness),
      home: LoginPage(
        controller: _controller(store: _MemorySessionStore(), sender: sender),
        deviceId: _deviceId,
        onLoggedIn: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _enterLoginCredentials(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('login-email-field')),
    'owner@example.test',
  );
  await tester.enterText(
    find.byKey(const Key('login-password-field')),
    'password',
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

final class _RecordingSender implements SyncHttpRequestSender {
  _RecordingSender(this.response);

  final SyncHttpResponse response;
  Uri? uri;

  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    this.uri = uri;
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

final class _LoginSender implements SyncHttpRequestSender {
  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    return _successResponse(statusCode: 200);
  }
}
