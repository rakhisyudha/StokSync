import 'package:sync_engine/sync_engine.dart';

import '../../data/local/local_mutation_repositories.dart';
import '../../data/local/server_clock_offset_store.dart';
import '../../data/local/stoksync_database.dart';
import '../../data/local/sync_page_applier.dart';
import '../../data/local/sync_response_applier.dart';
import '../../data/local/sync_response_reconciler.dart';
import '../../data/local/sync_state_store.dart';
import 'sync_reachability.dart';

/// The authenticated client-side runtime assembled at the application
/// composition root.
///
/// This object deliberately owns one [SyncSessionManager]. Both the HTTP sync
/// transport and the authenticated reachability probe receive that same
/// manager, so access-token reads and refresh-once behavior cannot diverge
/// between trigger preflight and the actual sync exchange.
final class AuthenticatedSyncRuntime {
  factory AuthenticatedSyncRuntime({
    required StokSyncDatabase database,
    required Uri baseUri,
    required String deviceId,
    required SyncSessionStore sessionStore,
    SyncHttpRequestSender? sender,
    SyncSessionRefresher? refresher,
  }) {
    final resolvedSender = sender ?? IoSyncHttpRequestSender();
    final resolvedRefresher =
        refresher ??
        HttpSyncSessionRefresher(baseUri: baseUri, sender: resolvedSender);
    final sessionManager = SyncSessionManager(
      store: sessionStore,
      refresher: resolvedRefresher,
    );
    final transport = HttpSyncTransport(
      baseUri: baseUri,
      sessionManager: sessionManager,
      sender: resolvedSender,
      clockOffsetStore: DriftServerClockOffsetStore(database),
    );
    final responseApplier = DriftSyncResponseApplier(
      responseReconciler: DriftSyncResponseReconciler(database),
      pageApplier: DriftSyncPageApplier(database),
    );
    final engine = SyncEngine(
      transport: transport,
      pendingOperations: PendingOperationDao(database),
      cursorStore: DriftSyncCursorStore(database),
      deviceId: deviceId,
      onResponse: responseApplier.call,
      statusStore: DriftSyncStatusStore(database),
    );
    final reachability = AuthenticatedHealthReachability(
      baseUri: baseUri,
      sessionManager: sessionManager,
      sender: resolvedSender,
    );
    return AuthenticatedSyncRuntime._(
      sessionManager: sessionManager,
      transport: transport,
      reachability: reachability,
      engine: engine,
    );
  }

  const AuthenticatedSyncRuntime._({
    required this.sessionManager,
    required this.transport,
    required this.reachability,
    required this.engine,
  });

  final SyncSessionManager sessionManager;
  final HttpSyncTransport transport;
  final AuthenticatedHealthReachability reachability;
  final SyncEngine engine;
}
