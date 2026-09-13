import 'dart:async';

import 'package:flutter/widgets.dart';

import 'sync_trigger_coordinator.dart';

/// Maps Flutter lifecycle transitions to foreground-only sync triggers.
final class SyncLifecycleAdapter with WidgetsBindingObserver {
  SyncLifecycleAdapter(this.coordinator);

  final SyncTriggerCoordinator coordinator;
  var _attached = false;

  bool get isAttached => _attached;

  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    coordinator.start(
      initiallyForeground:
          lifecycleState == null || lifecycleState == AppLifecycleState.resumed,
    );
  }

  void detach() {
    if (!_attached) {
      return;
    }
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    coordinator.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_attached) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(coordinator.enterForeground());
    } else {
      coordinator.leaveForeground();
    }
  }
}
