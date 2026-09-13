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
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to StokSync')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Sign in to synchronize this device while keeping inventory available offline.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            TextFormField(
              key: const Key('login-email-field'),
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Email is required.'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('login-password-field'),
              controller: _passwordController,
              obscureText: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
              onFieldSubmitted: (_) => _submit(),
              validator: (value) => value == null || value.isEmpty
                  ? 'Password is required.'
                  : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                key: const Key('login-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('login-submit-button'),
              onPressed: _isSubmitting ? null : _submit,
              child: Text(_isSubmitting ? 'Signing in…' : 'Sign in'),
            ),
          ],
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
