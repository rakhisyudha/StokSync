import 'dart:async';

import 'package:sync_engine/sync_engine.dart';

import 'sync_reachability.dart';

/// Runs one complete push-then-pull cycle through the existing sync engine.
typedef SyncCycleRunner = Future<SyncCycleResult?> Function();

/// Creates either a one-shot or periodic timer.
typedef SyncTimerFactory =
    SyncTimerHandle Function(
      Duration duration,
      void Function() callback, {
      required bool periodic,
    });

/// Narrow timer seam used to make trigger scheduling deterministic in tests.
abstract interface class SyncTimerHandle {
  void cancel();
}

final class _DartSyncTimer implements SyncTimerHandle {
  _DartSyncTimer(
    Duration duration,
    void Function() callback, {
    required bool periodic,
  }) : _timer = periodic
           ? Timer.periodic(duration, (_) => callback())
           : Timer(duration, callback);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

SyncTimerHandle _defaultSyncTimerFactory(
  Duration duration,
  void Function() callback, {
  required bool periodic,
}) {
  return _DartSyncTimer(duration, callback, periodic: periodic);
}

/// The sources that are allowed to wake the foreground sync coordinator.
enum SyncTriggerReason {
  appForeground,
  localWrite,
  manualRefresh,
  foregroundInterval,
  connectivityHint,
}

/// The outcome of one coalesced trigger batch.
enum SyncTriggerStatus { completed, unreachable, failed, stopped }

/// A non-sensitive result returned to callers of explicit triggers.
final class SyncTriggerResult {
  SyncTriggerResult({
    required this.status,
    required Iterable<SyncTriggerReason> reasons,
  }) : reasons = List<SyncTriggerReason>.unmodifiable(reasons);

  final SyncTriggerStatus status;
  final List<SyncTriggerReason> reasons;

  bool get didSynchronize => status == SyncTriggerStatus.completed;
}

/// Coordinates app-side wakeups without allowing overlapping sync cycles.
///
/// The coordinator is deliberately independent of Flutter lifecycle APIs. The
/// Flutter adapter maps lifecycle states to [enterForeground] and
/// [leaveForeground], while Riverpod supplies local-write and connectivity
/// streams. Every accepted trigger first performs an actual reachability
/// probe and only then invokes the existing mutex-protected sync engine.
final class SyncTriggerCoordinator {
  SyncTriggerCoordinator({
    required SyncCycleRunner synchronize,
    required SyncReachabilityProbe reachability,
    Stream<void>? localWriteEvents,
    Stream<Object?>? connectivityHints,
    this.localWriteDebounce = const Duration(seconds: 2),
    this.foregroundInterval = const Duration(minutes: 1),
    SyncTimerFactory? timerFactory,
  }) : _synchronize = synchronize,
       _reachability = reachability,
       _localWriteEvents = localWriteEvents,
       _connectivityHints = connectivityHints,
       _timerFactory = timerFactory ?? _defaultSyncTimerFactory {
    if (localWriteDebounce < Duration.zero) {
      throw ArgumentError.value(
        localWriteDebounce,
        'localWriteDebounce',
        'must not be negative',
      );
    }
    if (foregroundInterval <= Duration.zero) {
      throw ArgumentError.value(
        foregroundInterval,
        'foregroundInterval',
        'must be greater than zero',
      );
    }
  }

  /// Convenience constructor that binds directly to the existing engine.
  factory SyncTriggerCoordinator.fromEngine({
    required SyncEngine engine,
    required SyncReachabilityProbe reachability,
    Stream<void>? localWriteEvents,
    Stream<Object?>? connectivityHints,
    Duration localWriteDebounce = const Duration(seconds: 2),
    Duration foregroundInterval = const Duration(minutes: 1),
    SyncTimerFactory? timerFactory,
  }) {
    return SyncTriggerCoordinator(
      synchronize: engine.synchronize,
      reachability: reachability,
      localWriteEvents: localWriteEvents,
      connectivityHints: connectivityHints,
      localWriteDebounce: localWriteDebounce,
      foregroundInterval: foregroundInterval,
      timerFactory: timerFactory,
    );
  }

  final SyncCycleRunner _synchronize;
  final SyncReachabilityProbe _reachability;
  final Stream<void>? _localWriteEvents;
  final Stream<Object?>? _connectivityHints;
  final SyncTimerFactory _timerFactory;

  StreamSubscription<void>? _localWriteSubscription;
  StreamSubscription<Object?>? _connectivitySubscription;
  SyncTimerHandle? _debounceTimer;
  SyncTimerHandle? _intervalTimer;
  final List<_PendingTrigger> _pendingTriggers = <_PendingTrigger>[];
  Future<void>? _pumpFuture;
  var _started = false;
  var _foreground = false;
  var _disposed = false;

  final Duration localWriteDebounce;
  final Duration foregroundInterval;

  bool get isStarted => _started;
  bool get isForeground => _foreground;
  bool get isRunning => _pumpFuture != null;

  /// Starts listening for app-side hints.
  ///
  /// The default assumes the host is already visible and schedules one
  /// foreground attempt. A lifecycle adapter can pass `false` when the
  /// current application state is paused or inactive.
  void start({bool initiallyForeground = true}) {
    if (_disposed) {
      throw StateError('sync trigger coordinator has been disposed');
    }
    if (_started) {
      return;
    }
    _started = true;
    _localWriteSubscription = _localWriteEvents?.listen((_) {
      _scheduleDebouncedLocalWrite();
    });
    _connectivitySubscription = _connectivityHints?.listen((_) {
      unawaited(
        _request(SyncTriggerReason.connectivityHint, foregroundOnly: true),
      );
    });
    if (initiallyForeground) {
      unawaited(enterForeground());
    }
  }

  /// Stops timers and hint subscriptions, but does not cancel an in-flight
  /// HTTP exchange. A later start can safely resume through the engine mutex.
  void stop() {
    if (!_started) {
      return;
    }
    _started = false;
    _foreground = false;
    _cancelDebounceTimer();
    _cancelIntervalTimer();
    unawaited(_localWriteSubscription?.cancel());
    unawaited(_connectivitySubscription?.cancel());
    _localWriteSubscription = null;
    _connectivitySubscription = null;

    final stopped = _result(
      SyncTriggerStatus.stopped,
      const <SyncTriggerReason>[],
    );
    final pending = List<_PendingTrigger>.from(_pendingTriggers);
    _pendingTriggers.clear();
    for (final request in pending) {
      request.complete(stopped);
    }
  }

  /// Releases subscriptions and timers. An active engine call is allowed to
  /// finish because the engine owns durable interruption/retry behavior.
  void dispose() {
    if (_disposed) {
      return;
    }
    stop();
    _disposed = true;
  }

  /// Marks the app as foreground and requests an immediate synchronization.
  Future<SyncTriggerResult> enterForeground() {
    if (!_started) {
      return Future<SyncTriggerResult>.value(
        _result(SyncTriggerStatus.stopped, const [
          SyncTriggerReason.appForeground,
        ]),
      );
    }
    _foreground = true;
    _startIntervalTimer();
    return _request(SyncTriggerReason.appForeground, foregroundOnly: true);
  }

  /// Marks the app as not foreground. No interval or debounced write can
  /// initiate network work while the app is in this state.
  void leaveForeground() {
    if (!_started) {
      return;
    }
    _foreground = false;
    _cancelDebounceTimer();
    _cancelIntervalTimer();
  }

  /// Explicit refresh entry point for a status screen or pull-to-refresh UI.
  Future<SyncTriggerResult> manualRefresh() {
    return _request(SyncTriggerReason.manualRefresh, foregroundOnly: false);
  }

  void _scheduleDebouncedLocalWrite() {
    if (!_started || !_foreground) {
      return;
    }
    _cancelDebounceTimer();
    _debounceTimer = _timerFactory(localWriteDebounce, () {
      _debounceTimer = null;
      unawaited(_request(SyncTriggerReason.localWrite, foregroundOnly: true));
    }, periodic: false);
  }

  void _startIntervalTimer() {
    if (_intervalTimer != null) {
      return;
    }
    _intervalTimer = _timerFactory(foregroundInterval, () {
      if (!_started || !_foreground) {
        return;
      }
      unawaited(
        _request(SyncTriggerReason.foregroundInterval, foregroundOnly: true),
      );
    }, periodic: true);
  }

  void _cancelDebounceTimer() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  void _cancelIntervalTimer() {
    _intervalTimer?.cancel();
    _intervalTimer = null;
  }

  Future<SyncTriggerResult> _request(
    SyncTriggerReason reason, {
    required bool foregroundOnly,
  }) {
    if (_disposed || !_started || (foregroundOnly && !_foreground)) {
      return Future<SyncTriggerResult>.value(
        _result(SyncTriggerStatus.stopped, [reason]),
      );
    }

    final completer = Completer<SyncTriggerResult>();
    _pendingTriggers.add(_PendingTrigger(reason, completer));
    _ensurePump();
    return completer.future;
  }

  void _ensurePump() {
    if (_pumpFuture != null || _pendingTriggers.isEmpty) {
      return;
    }
    final pump = _drainPendingTriggers();
    _pumpFuture = pump;
    unawaited(_observePump(pump));
  }

  Future<void> _observePump(Future<void> pump) async {
    try {
      await pump;
    } on Object {
      // _drainPendingTriggers converts transport/probe failures to a result.
      // This guard keeps a timer or stream callback from becoming an
      // unhandled asynchronous error if an injected dependency misbehaves.
    } finally {
      if (identical(_pumpFuture, pump)) {
        _pumpFuture = null;
      }
      if (_pendingTriggers.isNotEmpty) {
        _ensurePump();
      }
    }
  }

  Future<void> _drainPendingTriggers() async {
    while (_pendingTriggers.isNotEmpty) {
      final batch = List<_PendingTrigger>.from(_pendingTriggers);
      _pendingTriggers.clear();
      final result = _started
          ? await _attempt(batch)
          : _result(SyncTriggerStatus.stopped, _reasons(batch));
      for (final request in batch) {
        request.complete(result);
      }
    }
  }

  Future<SyncTriggerResult> _attempt(List<_PendingTrigger> batch) async {
    final reasons = _reasons(batch);
    try {
      final reachable = await _reachability.check();
      if (!reachable) {
        return _result(SyncTriggerStatus.unreachable, reasons);
      }
      await _synchronize();
      return _result(SyncTriggerStatus.completed, reasons);
    } on Object {
      return _result(SyncTriggerStatus.failed, reasons);
    }
  }

  List<SyncTriggerReason> _reasons(List<_PendingTrigger> batch) {
    return batch.map((request) => request.reason).toSet().toList();
  }

  SyncTriggerResult _result(
    SyncTriggerStatus status,
    Iterable<SyncTriggerReason> reasons,
  ) {
    return SyncTriggerResult(status: status, reasons: reasons);
  }
}

final class _PendingTrigger {
  _PendingTrigger(this.reason, this._completer);

  final SyncTriggerReason reason;
  final Completer<SyncTriggerResult> _completer;

  void complete(SyncTriggerResult result) {
    if (!_completer.isCompleted) {
      _completer.complete(result);
    }
  }
}
