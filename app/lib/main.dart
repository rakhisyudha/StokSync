import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_engine/sync_engine.dart';

import 'core/config/app_config.dart';
import 'core/diagnostics/diagnostics.dart';
import 'core/identity/device_identity.dart';
import 'core/theme/appearance_controller.dart';
import 'core/theme/app_theme.dart';
import 'data/local/local_database.dart';
import 'data/local/local_query_providers.dart';
import 'data/remote/auth_client.dart';
import 'data/remote/sync_session_store.dart';
import 'features/auth/auth_pages.dart';
import 'features/navigation/authenticated_root_shell.dart';
import 'features/sync/sync_runtime_composition.dart';
import 'features/sync/sync_trigger_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appearanceController = await AppearanceController.load();
  final diagnostics = const AppDiagnostics();
  final database = await openLocalDatabase();
  final baseUri = StokSyncAppConfig.apiBaseUri;
  final sessionStore = SecureSyncSessionStore();
  final deviceId = await DeviceIdentity.platform().getDeviceId();
  final httpSender = IoSyncHttpRequestSender();
  final runtime = AuthenticatedSyncRuntime(
    database: database,
    baseUri: baseUri,
    deviceId: deviceId,
    sessionStore: sessionStore,
    sender: httpSender,
  );
  final authController = AuthSessionController(
    client: HttpAuthClient(
      baseUri: baseUri,
      sender: httpSender,
      diagnostics: diagnostics,
    ),
    sessionStore: sessionStore,
  );
  final runtimeBinding = SyncRuntimeBinding.fromEngine(
    engine: runtime.engine,
    reachability: runtime.reachability,
  );

  runApp(
    ProviderScope(
      overrides: [
        stoksyncDatabaseProvider.overrideWithValue(database),
        syncRuntimeProvider.overrideWithValue(runtimeBinding),
        appDiagnosticsProvider.overrideWithValue(diagnostics),
      ],
      child: StokSyncApp(
        appearanceController: appearanceController,
        authenticatedHome: AuthenticatedSessionGate(
          sessionStore: sessionStore,
          controller: authController,
          deviceId: deviceId,
          deviceName: 'StokSync device',
          platform: defaultTargetPlatform.name,
          authenticatedChild: SyncTriggerHost(
            child: AuthenticatedRootShell(
              appearanceController: appearanceController,
            ),
          ),
        ),
      ),
    ),
  );
}

class StokSyncApp extends StatefulWidget {
  const StokSyncApp({
    super.key,
    this.authenticatedHome,
    this.appearanceController,
  });

  /// The production composition root supplies a login/session gate here.
  /// Keeping this optional preserves a local-only widget entry point for
  /// feature tests and for callers that intentionally run without a server.
  final Widget? authenticatedHome;
  final AppearanceController? appearanceController;

  @override
  State<StokSyncApp> createState() => _StokSyncAppState();
}

final class _StokSyncAppState extends State<StokSyncApp> {
  late final AppearanceController _appearanceController;
  var _ownsAppearanceController = false;

  @override
  void initState() {
    super.initState();
    final controller = widget.appearanceController;
    if (controller == null) {
      _appearanceController = AppearanceController.inMemory();
      _ownsAppearanceController = true;
    } else {
      _appearanceController = controller;
    }
  }

  @override
  void dispose() {
    if (_ownsAppearanceController) {
      _appearanceController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appearanceController,
      builder: (context, _) {
        return MaterialApp(
          title: 'StokSync',
          theme: buildStokSyncTheme(Brightness.light),
          darkTheme: buildStokSyncTheme(Brightness.dark),
          themeMode: _appearanceController.themeMode,
          home:
              widget.authenticatedHome ??
              SyncTriggerHost(
                child: AuthenticatedRootShell(
                  appearanceController: _appearanceController,
                ),
              ),
        );
      },
    );
  }
}
