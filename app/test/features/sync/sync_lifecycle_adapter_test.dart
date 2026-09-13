import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/features/sync/sync_lifecycle_adapter.dart';
import 'package:stoksync/features/sync/sync_reachability.dart';
import 'package:stoksync/features/sync/sync_trigger_coordinator.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'maps resumed and paused lifecycle states to foreground control',
    () async {
      final runner = _Runner();
      final coordinator = SyncTriggerCoordinator(
        synchronize: runner.run,
        reachability: _Reachability(),
        foregroundInterval: const Duration(minutes: 1),
      );
      final adapter = SyncLifecycleAdapter(coordinator);
      addTearDown(() {
        adapter.detach();
        coordinator.dispose();
      });

      // Calling the observer directly keeps this test independent of platform
      // lifecycle state while exercising the adapter's mapping behavior.
      adapter.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(runner.calls, 0);

      adapter.attach();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.isStarted, isTrue);

      adapter.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(coordinator.isForeground, isFalse);
      adapter.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.isForeground, isTrue);
      expect(runner.calls, greaterThanOrEqualTo(1));
    },
  );
}

final class _Reachability implements SyncReachabilityProbe {
  @override
  Future<bool> check() async => true;
}

final class _Runner {
  var calls = 0;

  Future<SyncCycleResult?> run() async {
    calls++;
    return null;
  }
}
