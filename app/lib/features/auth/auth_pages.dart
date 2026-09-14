import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sync_engine/sync_engine.dart';

import '../../data/remote/auth_client.dart';

/// Restores a secure session before exposing the local-first inventory UI.
///
/// No network request is made while the login form is displayed. Once login
/// succeeds, [AuthSessionController] has already persisted the session and the
/// authenticated child can safely start the normal sync trigger host.
final class AuthenticatedSessionGate extends StatefulWidget {
  const AuthenticatedSessionGate({
    super.key,
    required this.sessionStore,
    required this.controller,
    required this.deviceId,
    required this.authenticatedChild,
    this.deviceName = 'StokSync device',
    this.platform = 'unknown',
  });

  final SyncSessionStore sessionStore;
  final AuthSessionController controller;
  final String deviceId;
  final Widget authenticatedChild;
  final String deviceName;
  final String platform;

  @override
  State<AuthenticatedSessionGate> createState() =>
      _AuthenticatedSessionGateState();
}

final class _AuthenticatedSessionGateState
    extends State<AuthenticatedSessionGate> {
  late Future<SyncSession?> _sessionFuture;
  SyncSession? _session;

  @override
  void initState() {
    super.initState();
    _sessionFuture = _restoreSession();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session != null) {
      return widget.authenticatedChild;
    }

    return FutureBuilder<SyncSession?>(
      future: _sessionFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final restored = snapshot.data;
        if (restored != null) {
          return widget.authenticatedChild;
        }
        return LoginPage(
          controller: widget.controller,
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
          platform: widget.platform,
          onLoggedIn: (loggedIn) {
            if (mounted) {
              setState(() => _session = loggedIn);
            }
          },
        );
      },
    );
  }

  Future<SyncSession?> _restoreSession() async {
    try {
      return await widget.sessionStore.readSession();
    } on SyncAuthenticationException {
      // Invalid or unavailable secure session data is treated as signed out;
      // login can replace it without exposing credential material.
      return null;
    } on Object {
      return null;
    }
  }
}

/// Minimal online sign-in flow for establishing the session used by sync.
final class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.controller,
    required this.deviceId,
    required this.onLoggedIn,
    this.deviceName = 'StokSync device',
    this.platform = 'unknown',
  });

  final AuthSessionController controller;
  final String deviceId;
  final ValueChanged<SyncSession> onLoggedIn;
  final String deviceName;
  final String platform;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

final class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _error;
  var _isSubmitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: colorScheme.outlineVariant),
    );
    final focusedInputBorder = inputBorder.copyWith(
      borderSide: BorderSide(color: colorScheme.primary, width: 2),
    );
    final errorInputBorder = inputBorder.copyWith(
      borderSide: BorderSide(color: colorScheme.error, width: 2),
    );
    final inputDecoration = InputDecoration(
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: focusedInputBorder,
      errorBorder: errorInputBorder,
      focusedErrorBorder: errorInputBorder,
      errorStyle: textTheme.bodySmall?.copyWith(color: colorScheme.error),
      prefixIconColor: colorScheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('StokSync'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: AutofillGroup(
              child: Semantics(
                container: true,
                label: 'Sign-in form',
                child: Form(
                  key: _formKey,
                  child: ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                    children: [
                      Align(
                        alignment: Alignment.center,
                        child: DecoratedBox(
                          key: const Key('login-brand-mark'),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Icon(
                              Icons.inventory_2_outlined,
                              size: 32,
                              color: colorScheme.onPrimaryContainer,
                              semanticLabel: 'StokSync inventory',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Welcome back',
                        key: const Key('login-title'),
                        textAlign: TextAlign.center,
                        style: textTheme.headlineSmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to synchronize this device while keeping inventory available offline.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextFormField(
                        key: const Key('login-email-field'),
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.none,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        scrollPadding: const EdgeInsets.only(bottom: 120),
                        decoration: inputDecoration.copyWith(
                          labelText: 'Email',
                          hintText: 'you@example.com',
                          prefixIcon: const Icon(Icons.alternate_email),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Email is required.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('login-password-field'),
                        controller: _passwordController,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        scrollPadding: const EdgeInsets.only(bottom: 120),
                        decoration: inputDecoration.copyWith(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                        ),
                        onFieldSubmitted: (_) => _submit(),
                        validator: (value) => value == null || value.isEmpty
                            ? 'Password is required.'
                            : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 20),
                        Semantics(
                          container: true,
                          liveRegion: true,
                          label: 'Sign-in error: ${_error!}',
                          child: ExcludeSemantics(
                            child: Container(
                              key: const Key('login-error-banner'),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: colorScheme.errorContainer,
                                border: Border.all(color: colorScheme.error),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.error_outline_rounded,
                                    color: colorScheme.onErrorContainer,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      key: const Key('login-error'),
                                      style: textTheme.bodyMedium?.copyWith(
                                        color: colorScheme.onErrorContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      Semantics(
                        liveRegion: _isSubmitting,
                        label: _isSubmitting ? 'Signing in' : null,
                        child: FilledButton(
                          key: const Key('login-submit-button'),
                          onPressed: _isSubmitting ? null : _submit,
                          style:
                              FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(56),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                textStyle: textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ).copyWith(
                                backgroundColor:
                                    WidgetStateProperty.resolveWith<Color?>(
                                      (states) =>
                                          _isSubmitting &&
                                              states.contains(
                                                WidgetState.disabled,
                                              )
                                          ? colorScheme.primary
                                          : null,
                                    ),
                                foregroundColor:
                                    WidgetStateProperty.resolveWith<Color?>(
                                      (states) =>
                                          _isSubmitting &&
                                              states.contains(
                                                WidgetState.disabled,
                                              )
                                          ? colorScheme.onPrimary
                                          : null,
                                    ),
                              ),
                          child: AnimatedSwitcher(
                            duration: Durations.short4,
                            child: _isSubmitting
                                ? Row(
                                    key: const ValueKey('login-loading'),
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox.square(
                                        dimension: 20,
                                        child: CircularProgressIndicator(
                                          key: const Key(
                                            'login-loading-indicator',
                                          ),
                                          strokeWidth: 2,
                                          color: colorScheme.onPrimary,
                                          semanticsLabel: 'Signing in',
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      const Text('Signing in…'),
                                    ],
                                  )
                                : const Text(
                                    'Sign in',
                                    key: ValueKey('login-idle'),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    try {
      final session = await widget.controller.login(
        email: _emailController.text,
        password: _passwordController.text,
        deviceId: widget.deviceId,
        deviceName: widget.deviceName,
        platform: widget.platform,
      );
      if (mounted) {
        widget.onLoggedIn(session);
      }
    } on AuthClientException catch (error) {
      if (mounted) {
        setState(() => _error = error.userMessage);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not sign in. Please try again.');
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }
}
