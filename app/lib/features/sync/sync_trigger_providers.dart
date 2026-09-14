import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_engine/sync_engine.dart';

import '../../core/diagnostics/diagnostics.dart';
import '../../data/local/local_write_notifier.dart';
import 'connectivity_hint_source.dart';
import 'sync_lifecycle_adapter.dart';
import 'sync_reachability.dart';
import 'sync_trigger_coordinator.dart';

/// Runtime binding supplied by an authenticated app session.
///
/// Authentication/token refresh remains outside Task 4.6. Until a session
/// supplies this binding, the local-first app continues to work without any
/// remote request or sync side effect.
final class SyncRuntimeBinding {
  const SyncRuntimeBinding({
    required this.synchronize,
    required this.reachability,
  });

  factory SyncRuntimeBinding.fromEngine({
    required SyncEngine engine,
    required SyncReachabilityProbe reachability,
  }) {
    return SyncRuntimeBinding(
      synchronize: engine.synchronize,
      reachability: reachability,
    );
  }

  final SyncCycleRunner synchronize;
  final SyncReachabilityProbe reachability;
}

/// Client-side structured diagnostics. The default writer is debug-only and
/// tests can override it with an in-memory writer.
final appDiagnosticsProvider = Provider<AppDiagnostics>((ref) {
  return const AppDiagnostics();
});

/// Overridden by the authenticated composition root when sync is available.
final syncRuntimeProvider = Provider<SyncRuntimeBinding?>((ref) => null);

/// OS connectivity values are only wakeup hints for the coordinator.
final connectivityHintSourceProvider = Provider<ConnectivityHintSource>((ref) {
  return ConnectivityPlusHintSource();
});

/// App-scoped coordinator that is active only when an authenticated runtime is
/// supplied. The lifecycle host owns start/stop and foreground transitions.
final syncTriggerCoordinatorProvider = Provider<SyncTriggerCoordinator?>((ref) {
  final runtime = ref.watch(syncRuntimeProvider);
  if (runtime == null) {
    return null;
  }

  final localWriteNotifier = ref.watch(localWriteNotifierProvider);
  final connectivity = ref.watch(connectivityHintSourceProvider);
  final diagnostics = ref.watch(appDiagnosticsProvider);
  final coordinator = SyncTriggerCoordinator(
    synchronize: runtime.synchronize,
    reachability: runtime.reachability,
    localWriteEvents: localWriteNotifier.events,
    connectivityHints: connectivity.hints,
    diagnostics: diagnostics,
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

/// Root widget adapter that keeps trigger orchestration outside feature pages.
final class SyncTriggerHost extends ConsumerStatefulWidget {
  const SyncTriggerHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SyncTriggerHost> createState() => _SyncTriggerHostState();
}

final class _SyncTriggerHostState extends ConsumerState<SyncTriggerHost> {
  SyncLifecycleAdapter? _lifecycleAdapter;

  @override
  void initState() {
    super.initState();
    ref.listenManual<SyncTriggerCoordinator?>(
      syncTriggerCoordinatorProvider,
      (_, coordinator) => _replaceCoordinator(coordinator),
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    _lifecycleAdapter?.detach();
    _lifecycleAdapter = null;
    super.dispose();
  }

  void _replaceCoordinator(SyncTriggerCoordinator? coordinator) {
    if (identical(_lifecycleAdapter?.coordinator, coordinator)) {
      return;
    }
    _lifecycleAdapter?.detach();
    _lifecycleAdapter = coordinator == null
        ? null
        : (SyncLifecycleAdapter(coordinator)..attach());
  }
}
