import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sync_engine/sync_engine.dart';

import '../../data/remote/auth_client.dart';

/// Restores a secure session before exposing the local-first inventory UI.
///
/// No network request is made while the authentication form is displayed. Once
/// sign-in or registration succeeds, [AuthSessionController] has already
/// persisted the session and the authenticated child can safely start the
/// normal sync trigger host.
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
  var _showRegistration = false;

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
        if (_showRegistration) {
          return RegistrationPage(
            controller: widget.controller,
            deviceId: widget.deviceId,
            deviceName: widget.deviceName,
            platform: widget.platform,
            onRegistered: _completeAuthentication,
            onSignIn: () => setState(() => _showRegistration = false),
          );
        }
        return LoginPage(
          controller: widget.controller,
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
          platform: widget.platform,
          onLoggedIn: _completeAuthentication,
          onCreateAccount: () => setState(() => _showRegistration = true),
        );
      },
    );
  }

  void _completeAuthentication(SyncSession session) {
    if (mounted) {
      setState(() => _session = session);
    }
  }

  Future<SyncSession?> _restoreSession() async {
    try {
      return await widget.sessionStore.readSession();
    } on SyncAuthenticationException {
      // Invalid or unavailable secure session data is treated as signed out;
      // a new authentication flow can replace it without exposing credentials.
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
    this.onCreateAccount,
  });

  final AuthSessionController controller;
  final String deviceId;
  final ValueChanged<SyncSession> onLoggedIn;
  final String deviceName;
  final String platform;
  final VoidCallback? onCreateAccount;

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
    final inputDecoration = _authInputDecoration(theme);
    final inputStyle = _authInputTextStyle(theme);

    return _AuthPageFrame(
      formKey: _formKey,
      semanticsLabel: 'Sign-in form',
      title: 'Welcome back',
      titleKey: const Key('login-title'),
      description:
          'Sign in to synchronize this device while keeping inventory available offline.',
      children: [
        TextFormField(
          key: const Key('login-email-field'),
          controller: _emailController,
          style: inputStyle,
          cursorColor: theme.colorScheme.primary,
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
          validator: _requiredEmail,
        ),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('login-password-field'),
          controller: _passwordController,
          style: inputStyle,
          cursorColor: theme.colorScheme.primary,
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
          validator: _requiredPassword,
        ),
        if (_error != null) ...[
          const SizedBox(height: 20),
          _AuthErrorBanner(
            bannerKey: const Key('login-error-banner'),
            errorKey: const Key('login-error'),
            semanticLabel: 'Sign-in error: ${_error!}',
            message: _error!,
          ),
        ],
        const SizedBox(height: 28),
        _AuthSubmitButton(
          buttonKey: const Key('login-submit-button'),
          loadingKey: const Key('login-loading'),
          indicatorKey: const Key('login-loading-indicator'),
          isSubmitting: _isSubmitting,
          onPressed: _submit,
          idleLabel: 'Sign in',
          loadingLabel: 'Signing in…',
          semanticsLabel: 'Signing in',
        ),
        if (widget.onCreateAccount != null) ...[
          const SizedBox(height: 16),
          _AuthSwitchPrompt(
            prompt: "Don't have an account?",
            actionLabel: 'Create account',
            actionKey: const Key('login-create-account-link'),
            onPressed: widget.onCreateAccount!,
          ),
        ],
      ],
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

/// Creates an account and persists the returned session before opening the app.
final class RegistrationPage extends StatefulWidget {
  const RegistrationPage({
    super.key,
    required this.controller,
    required this.deviceId,
    required this.onRegistered,
    required this.onSignIn,
    this.deviceName = 'StokSync device',
    this.platform = 'unknown',
  });

  final AuthSessionController controller;
  final String deviceId;
  final ValueChanged<SyncSession> onRegistered;
  final VoidCallback onSignIn;
  final String deviceName;
  final String platform;

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

final class _RegistrationPageState extends State<RegistrationPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  String? _error;
  var _isSubmitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inputDecoration = _authInputDecoration(theme);
    final inputStyle = _authInputTextStyle(theme);

    return _AuthPageFrame(
      formKey: _formKey,
      semanticsLabel: 'Create-account form',
      title: 'Create your account',
      titleKey: const Key('register-title'),
      description:
          'Create an account to keep this device synchronized with your inventory.',
      children: [
        TextFormField(
          key: const Key('register-email-field'),
          controller: _emailController,
          style: inputStyle,
          cursorColor: theme.colorScheme.primary,
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
          validator: _requiredEmail,
        ),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('register-password-field'),
          controller: _passwordController,
          style: inputStyle,
          cursorColor: theme.colorScheme.primary,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.next,
          scrollPadding: const EdgeInsets.only(bottom: 120),
          decoration: inputDecoration.copyWith(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline),
          ),
          validator: _requiredPassword,
        ),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('register-confirm-password-field'),
          controller: _confirmationController,
          style: inputStyle,
          cursorColor: theme.colorScheme.primary,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.done,
          scrollPadding: const EdgeInsets.only(bottom: 120),
          decoration: inputDecoration.copyWith(
            labelText: 'Confirm password',
            prefixIcon: const Icon(Icons.lock_outline),
          ),
          onFieldSubmitted: (_) => _submit(),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Confirm your password.';
            }
            if (value != _passwordController.text) {
              return 'Passwords do not match.';
            }
            return null;
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: 20),
          _AuthErrorBanner(
            bannerKey: const Key('register-error-banner'),
            errorKey: const Key('register-error'),
            semanticLabel: 'Registration error: ${_error!}',
            message: _error!,
          ),
        ],
        const SizedBox(height: 28),
        _AuthSubmitButton(
          buttonKey: const Key('register-submit-button'),
          loadingKey: const Key('register-loading'),
          indicatorKey: const Key('register-loading-indicator'),
          isSubmitting: _isSubmitting,
          onPressed: _submit,
          idleLabel: 'Create account',
          loadingLabel: 'Creating account…',
          semanticsLabel: 'Creating account',
        ),
        const SizedBox(height: 16),
        _AuthSwitchPrompt(
          prompt: 'Already have an account?',
          actionLabel: 'Sign in',
          actionKey: const Key('register-sign-in-link'),
          onPressed: _isSubmitting ? null : widget.onSignIn,
        ),
      ],
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
      final session = await widget.controller.register(
        email: _emailController.text,
        password: _passwordController.text,
        deviceId: widget.deviceId,
        deviceName: widget.deviceName,
        platform: widget.platform,
      );
      if (mounted) {
        widget.onRegistered(session);
      }
    } on AuthClientException catch (error) {
      if (mounted) {
        setState(() => _error = error.userMessage);
      }
    } on Object {
      if (mounted) {
        setState(
          () => _error = 'Could not create the account. Please try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }
}

final class _AuthPageFrame extends StatelessWidget {
  const _AuthPageFrame({
    required this.formKey,
    required this.semanticsLabel,
    required this.title,
    required this.titleKey,
    required this.description,
    required this.children,
  });

  final GlobalKey<FormState> formKey;
  final String semanticsLabel;
  final String title;
  final Key titleKey;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('StokSync'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: AutofillGroup(
              child: Semantics(
                container: true,
                label: semanticsLabel,
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                  children: [
                    Row(
                      children: [
                        DecoratedBox(
                          key: const Key('login-brand-mark'),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Icon(
                              Icons.inventory_2_outlined,
                              size: 28,
                              color: colorScheme.onPrimaryContainer,
                              semanticLabel: 'StokSync inventory',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'STOKSYNC',
                              style: textTheme.labelLarge?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.4,
                              ),
                            ),
                            Text(
                              'LOCAL-FIRST INVENTORY',
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Text(
                      title,
                      key: titleKey,
                      style: textTheme.headlineSmall?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      style: textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Card(
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Form(
                          key: formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: children,
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
    );
  }
}

InputDecoration _authInputDecoration(ThemeData theme) {
  final colorScheme = theme.colorScheme;
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
  return InputDecoration(
    filled: true,
    fillColor: colorScheme.surfaceContainerHighest,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: inputBorder,
    enabledBorder: inputBorder,
    focusedBorder: focusedInputBorder,
    errorBorder: errorInputBorder,
    focusedErrorBorder: errorInputBorder,
    labelStyle: theme.textTheme.bodyLarge?.copyWith(
      color: colorScheme.onSurfaceVariant,
    ),
    floatingLabelStyle: theme.textTheme.bodyLarge?.copyWith(
      color: colorScheme.primary,
      fontWeight: FontWeight.w700,
    ),
    hintStyle: theme.textTheme.bodyLarge?.copyWith(
      color: colorScheme.onSurfaceVariant,
    ),
    errorStyle: theme.textTheme.bodySmall?.copyWith(color: colorScheme.error),
    prefixIconColor: colorScheme.onSurfaceVariant,
  );
}

TextStyle? _authInputTextStyle(ThemeData theme) {
  return theme.textTheme.bodyLarge?.copyWith(
    color: theme.colorScheme.onSurface,
  );
}

String? _requiredEmail(String? value) {
  return value == null || value.trim().isEmpty ? 'Email is required.' : null;
}

String? _requiredPassword(String? value) {
  return value == null || value.isEmpty ? 'Password is required.' : null;
}

final class _AuthErrorBanner extends StatelessWidget {
  const _AuthErrorBanner({
    required this.bannerKey,
    required this.errorKey,
    required this.semanticLabel,
    required this.message,
  });

  final Key bannerKey;
  final Key errorKey;
  final String semanticLabel;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Container(
          key: bannerKey,
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
                  message,
                  key: errorKey,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _AuthSubmitButton extends StatelessWidget {
  const _AuthSubmitButton({
    required this.buttonKey,
    required this.loadingKey,
    required this.indicatorKey,
    required this.isSubmitting,
    required this.onPressed,
    required this.idleLabel,
    required this.loadingLabel,
    required this.semanticsLabel,
  });

  final Key buttonKey;
  final Key loadingKey;
  final Key indicatorKey;
  final bool isSubmitting;
  final VoidCallback onPressed;
  final String idleLabel;
  final String loadingLabel;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Semantics(
      liveRegion: isSubmitting,
      label: isSubmitting ? semanticsLabel : null,
      child: FilledButton(
        key: buttonKey,
        onPressed: isSubmitting ? null : onPressed,
        style:
            FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ).copyWith(
              backgroundColor: WidgetStateProperty.resolveWith<Color?>(
                (states) =>
                    isSubmitting && states.contains(WidgetState.disabled)
                    ? colorScheme.primary
                    : null,
              ),
              foregroundColor: WidgetStateProperty.resolveWith<Color?>(
                (states) =>
                    isSubmitting && states.contains(WidgetState.disabled)
                    ? colorScheme.onPrimary
                    : null,
              ),
            ),
        child: AnimatedSwitcher(
          duration: Durations.short4,
          child: isSubmitting
              ? Row(
                  key: loadingKey,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        key: indicatorKey,
                        strokeWidth: 2,
                        color: colorScheme.onPrimary,
                        semanticsLabel: semanticsLabel,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(loadingLabel),
                  ],
                )
              : Text(idleLabel, key: ValueKey('$idleLabel-idle')),
        ),
      ),
    );
  }
}

final class _AuthSwitchPrompt extends StatelessWidget {
  const _AuthSwitchPrompt({
    required this.prompt,
    required this.actionLabel,
    required this.actionKey,
    required this.onPressed,
  });

  final String prompt;
  final String actionLabel;
  final Key actionKey;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(prompt, style: Theme.of(context).textTheme.bodyMedium),
        TextButton(
          key: actionKey,
          onPressed: onPressed,
          child: Text(actionLabel),
        ),
      ],
    );
  }
}
