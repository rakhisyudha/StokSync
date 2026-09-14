import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_engine/sync_engine.dart';

import 'core/config/app_config.dart';
import 'core/diagnostics/diagnostics.dart';
import 'core/identity/device_identity.dart';
import 'core/theme/app_theme.dart';
import 'data/local/local_database.dart';
import 'data/local/local_query_providers.dart';
import 'data/remote/auth_client.dart';
import 'data/remote/sync_session_store.dart';
import 'features/auth/auth_pages.dart';
import 'features/products/product_pages.dart';
import 'features/sync/sync_runtime_composition.dart';
import 'features/sync/sync_trigger_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        authenticatedHome: AuthenticatedSessionGate(
          sessionStore: sessionStore,
          controller: authController,
          deviceId: deviceId,
          deviceName: 'StokSync device',
          platform: defaultTargetPlatform.name,
          authenticatedChild: const SyncTriggerHost(child: ProductBrowsePage()),
        ),
      ),
    ),
  );
}

class StokSyncApp extends StatelessWidget {
  const StokSyncApp({super.key, this.authenticatedHome});

  /// The production composition root supplies a login/session gate here.
  /// Keeping this optional preserves a local-only widget entry point for
  /// feature tests and for callers that intentionally run without a server.
  final Widget? authenticatedHome;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StokSync',
      theme: buildStokSyncTheme(Brightness.light),
      darkTheme: buildStokSyncTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home:
          authenticatedHome ??
          const SyncTriggerHost(child: ProductBrowsePage()),
    );
  }
}
