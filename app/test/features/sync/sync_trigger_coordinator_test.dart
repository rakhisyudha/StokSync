import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/diagnostics/diagnostics.dart';
import 'package:stoksync/features/sync/sync_reachability.dart';
import 'package:stoksync/features/sync/sync_trigger_coordinator.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('SyncTriggerCoordinator', () {
    test('debounces repeated local-write notifications', () async {
      final writes = StreamController<void>.broadcast();
      final timers = _ManualTimerFactory();
      final probe = _FakeReachability();
      final runner = _FakeRunner();
      final coordinator = _coordinator(
        probe: probe,
        runner: runner,
        timers: timers,
        localWriteEvents: writes.stream,
      );
      addTearDown(() async {
        coordinator.dispose();
        await writes.close();
      });

      coordinator.start(initiallyForeground: false);
      await coordinator.enterForeground();
      runner.calls = 0;
      probe.calls = 0;

      writes.add(null);
      writes.add(null);
      await _flushMicrotasks();

      final debounceTimers = timers.timers
          .where((timer) => !timer.periodic && timer.isActive)
          .toList(growable: false);
      expect(debounceTimers, hasLength(1));
      expect(runner.calls, 0);

      debounceTimers.single.fire();
      await _flushMicrotasks();

      expect(runner.calls, 1);
      expect(probe.calls, 1);
    });

    test(
      'runs the interval only while foreground and restarts it on resume',
      () async {
        final timers = _ManualTimerFactory();
        final runner = _FakeRunner();
        final coordinator = _coordinator(runner: runner, timers: timers);
        addTearDown(coordinator.dispose);

        coordinator.start(initiallyForeground: false);
        await coordinator.enterForeground();
        expect(runner.calls, 1);
        final firstInterval = timers.timers.singleWhere(
          (timer) => timer.periodic,
        );
        expect(firstInterval.duration, const Duration(minutes: 1));

        firstInterval.fire();
        await _flushMicrotasks();
        expect(runner.calls, 2);

        coordinator.leaveForeground();
        expect(firstInterval.isActive, isFalse);
        firstInterval.fire();
        await _flushMicrotasks();
        expect(runner.calls, 2);

        await coordinator.enterForeground();
        expect(runner.calls, 3);
        final intervals = timers.timers.where((timer) => timer.periodic);
        expect(intervals, hasLength(2));
        expect(intervals.last.isActive, isTrue);
      },
    );

    test(
      'manual refresh and resumed foreground trigger use real reachability',
      () async {
        final timers = _ManualTimerFactory();
        final probe = _FakeReachability();
        final runner = _FakeRunner();
        final diagnosticLines = <String>[];
        final hints = StreamController<Object?>.broadcast();
        final coordinator = _coordinator(
          probe: probe,
          runner: runner,
          timers: timers,
          connectivityHints: hints.stream,
          diagnostics: AppDiagnostics(writer: diagnosticLines.add),
        );
        addTearDown(() async {
          coordinator.dispose();
          await hints.close();
        });

        coordinator.start(initiallyForeground: false);
        final manual = await coordinator.manualRefresh();
        expect(manual.status, SyncTriggerStatus.completed);
        expect(manual.reasons, [SyncTriggerReason.manualRefresh]);
        expect(diagnosticLines.single, contains('"event":"sync.trigger"'));
        expect(diagnosticLines.single, contains('"outcome":"completed"'));
        expect(probe.calls, 1);
        expect(runner.calls, 1);

        probe.reachable = false;
        final unreachable = await coordinator.manualRefresh();
        expect(unreachable.status, SyncTriggerStatus.unreachable);
        expect(runner.calls, 1);

        probe.reachable = true;
        await coordinator.enterForeground();
        runner.calls = 0;
        probe.calls = 0;
        hints.add('wifi');
        await _flushMicrotasks();
        expect(probe.calls, 1);
        expect(runner.calls, 1);
      },
    );

    test('coalesces triggers while never overlapping engine calls', () async {
      final timers = _ManualTimerFactory();
      final runner = _FakeRunner(blockFirstCall: true);
      final coordinator = _coordinator(runner: runner, timers: timers);
      addTearDown(coordinator.dispose);
      coordinator.start(initiallyForeground: false);

      final first = coordinator.manualRefresh();
      await _waitUntil(() => runner.calls == 1);
      final second = coordinator.manualRefresh();
      final third = coordinator.manualRefresh();
      expect(runner.concurrentCalls, 1);

      runner.releaseFirstCall();
      final results = await Future.wait([first, second, third]);

      expect(runner.calls, 2);
      expect(runner.maxConcurrentCalls, 1);
      expect(results.map((result) => result.status), [
        SyncTriggerStatus.completed,
        SyncTriggerStatus.completed,
        SyncTriggerStatus.completed,
      ]);
    });

    test(
      'stops pending and future triggers without affecting local work',
      () async {
        final writes = StreamController<void>.broadcast();
        final timers = _ManualTimerFactory();
        final runner = _FakeRunner();
        final coordinator = _coordinator(
          runner: runner,
          timers: timers,
          localWriteEvents: writes.stream,
        );
        addTearDown(() async {
          coordinator.dispose();
          await writes.close();
        });

        coordinator.start(initiallyForeground: true);
        await _flushMicrotasks();
        coordinator.stop();
        writes.add(null);
        await _flushMicrotasks();

        expect(coordinator.isStarted, isFalse);
        expect(runner.calls, 1);
        expect(
          await coordinator.manualRefresh().then((result) => result.status),
          SyncTriggerStatus.stopped,
        );
      },
    );
  });
}

SyncTriggerCoordinator _coordinator({
  _FakeReachability? probe,
  required _FakeRunner runner,
  required _ManualTimerFactory timers,
  Stream<void>? localWriteEvents,
  Stream<Object?>? connectivityHints,
  AppDiagnostics? diagnostics,
}) {
  return SyncTriggerCoordinator(
    synchronize: runner.run,
    reachability: probe ?? _FakeReachability(),
    localWriteEvents: localWriteEvents,
    connectivityHints: connectivityHints,
    timerFactory: timers.create,
    diagnostics: diagnostics,
  );
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for the condition.');
}

final class _FakeReachability implements SyncReachabilityProbe {
  var reachable = true;
  var calls = 0;

  @override
  Future<bool> check() async {
    calls++;
    return reachable;
  }
}

final class _FakeRunner {
  _FakeRunner({this.blockFirstCall = false});

  final bool blockFirstCall;
  var calls = 0;
  var concurrentCalls = 0;
  var maxConcurrentCalls = 0;
  Completer<void>? _firstCallRelease;

  Future<SyncCycleResult?> run() async {
    calls++;
    concurrentCalls++;
    maxConcurrentCalls = concurrentCalls > maxConcurrentCalls
        ? concurrentCalls
        : maxConcurrentCalls;
    try {
      if (blockFirstCall && calls == 1) {
        _firstCallRelease = Completer<void>();
        await _firstCallRelease!.future;
      }
      return null;
    } finally {
      concurrentCalls--;
    }
  }

  void releaseFirstCall() {
    final release = _firstCallRelease;
    if (release != null && !release.isCompleted) {
      release.complete();
    }
  }
}

final class _ManualTimerFactory {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  SyncTimerHandle create(
    Duration duration,
    void Function() callback, {
    required bool periodic,
  }) {
    final timer = _ManualTimer(duration, callback, periodic: periodic);
    timers.add(timer);
    return timer;
  }
}

final class _ManualTimer implements SyncTimerHandle {
  _ManualTimer(this.duration, this.callback, {required this.periodic});

  final Duration duration;
  final void Function() callback;
  final bool periodic;
  var isActive = true;

  @override
  void cancel() {
    isActive = false;
  }

  void fire() {
    if (!isActive) {
      return;
    }
    if (!periodic) {
      isActive = false;
    }
    callback();
  }
}
