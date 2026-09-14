import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/features/sync/sync_status_widgets.dart';
import 'package:stoksync/features/sync/sync_reachability.dart';
import 'package:stoksync/features/sync/sync_trigger_coordinator.dart';
import 'package:stoksync/features/sync/sync_trigger_providers.dart';

void main() {
  group('local sync status presentation', () {
    test('describes the empty initial state as local only', () {
      const summary = SyncSummary(
        cursor: 0,
        bootstrapped: false,
        lastSyncedAt: null,
        lastError: null,
        pendingOperationCount: 0,
        unresolvedConflictCount: 0,
      );

      expect(localSyncStatusLabel(summary), 'Local only');
      expect(
        localSyncLastKnownStatus(summary),
        'Not synced yet. Local changes stay on this device.',
      );
    });

    test(
      'keeps queued offline work distinct from completed synchronization',
      () {
        const summary = SyncSummary(
          cursor: 0,
          bootstrapped: false,
          lastSyncedAt: null,
          lastError: null,
          pendingOperationCount: 2,
          unresolvedConflictCount: 1,
        );

        expect(localSyncStatusLabel(summary), 'Queued locally');
        expect(
          localSyncLastKnownStatus(summary),
          'Not synced yet. Local changes stay on this device.',
        );
      },
    );

    test('surfaces a stored error and successful sync timestamp', () {
      final lastSyncedAt = DateTime.utc(2026, 9, 13, 10, 2);
      final successfulSummary = SyncSummary(
        cursor: 8,
        bootstrapped: true,
        lastSyncedAt: lastSyncedAt,
        lastError: null,
        pendingOperationCount: 0,
        unresolvedConflictCount: 0,
      );
      final failedSummary = SyncSummary(
        cursor: 8,
        bootstrapped: true,
        lastSyncedAt: lastSyncedAt,
        lastError: 'network timeout',
        pendingOperationCount: 1,
        unresolvedConflictCount: 0,
      );

      expect(localSyncStatusLabel(successfulSummary), 'Last synced');
      expect(
        localSyncLastKnownStatus(successfulSummary),
        'Last successful sync: 2026-09-13 10:02 UTC',
      );
      expect(localSyncStatusLabel(failedSummary), 'Needs attention');
      expect(
        localSyncLastKnownStatus(failedSummary),
        'Last attempt failed: network timeout',
      );
    });

    test(
      'labels a durable authentication blocker without hiding local work',
      () {
        const summary = SyncSummary(
          cursor: 8,
          bootstrapped: true,
          status: 'blocked',
          lastSyncedAt: null,
          lastError: 'SyncAuthenticationException(reason: refresh_rejected)',
          pendingOperationCount: 2,
          unresolvedConflictCount: 1,
        );

        expect(localSyncStatusLabel(summary), 'Sync blocked');
        expect(
          localSyncLastKnownStatus(summary),
          'Sync blocked: SyncAuthenticationException(reason: refresh_rejected)',
        );
      },
    );

    testWidgets('shows empty local counts and offline-first copy', (
      tester,
    ) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });

      await tester.pumpWidget(
        _statusTestApp(
          Stream.value(
            const SyncSummary(
              cursor: 0,
              bootstrapped: false,
              lastSyncedAt: null,
              lastError: null,
              pendingOperationCount: 0,
              unresolvedConflictCount: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-status-card')), findsOneWidget);
      expect(find.text('Local only'), findsOneWidget);
      expect(find.text('0 queued operations'), findsOneWidget);
      expect(find.text('0 unresolved conflicts'), findsOneWidget);
      expect(
        find.text('Not synced yet. Local changes stay on this device.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Status counts are local; sync checks reachability before sending work.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'reactively reflects queue, conflict, and stored status changes',
      (tester) async {
        final summaries = StreamController<SyncSummary>.broadcast();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await summaries.close();
        });

        await tester.pumpWidget(_statusTestApp(summaries.stream));
        await tester.pump();
        summaries.add(
          const SyncSummary(
            cursor: 0,
            bootstrapped: false,
            lastSyncedAt: null,
            lastError: null,
            pendingOperationCount: 0,
            unresolvedConflictCount: 0,
          ),
        );
        await tester.pump();
        expect(find.text('0 queued operations'), findsOneWidget);
        expect(find.text('0 unresolved conflicts'), findsOneWidget);

        summaries.add(
          SyncSummary(
            cursor: 8,
            bootstrapped: true,
            lastSyncedAt: DateTime.utc(2026, 9, 13, 10, 2),
            lastError: null,
            pendingOperationCount: 1,
            unresolvedConflictCount: 1,
          ),
        );
        await _waitFor(
          tester,
          () =>
              find.text('1 queued operations').evaluate().isNotEmpty &&
              find.text('1 unresolved conflicts').evaluate().isNotEmpty &&
              find
                  .text('Last successful sync: 2026-09-13 10:02 UTC')
                  .evaluate()
                  .isNotEmpty,
          description: 'local queue and conflict status update',
        );
        expect(find.text('Queued locally'), findsOneWidget);

        summaries.add(
          SyncSummary(
            cursor: 8,
            bootstrapped: true,
            lastSyncedAt: DateTime.utc(2026, 9, 13, 10, 2),
            lastError: 'network timeout',
            pendingOperationCount: 1,
            unresolvedConflictCount: 1,
          ),
        );
        await _waitFor(
          tester,
          () => find
              .text('Last attempt failed: network timeout')
              .evaluate()
              .isNotEmpty,
          description: 'stored local sync error update',
        );
        expect(find.text('Needs attention'), findsOneWidget);
      },
    );
    test(
      'maps every persisted state to an explicit user-facing state label',
      () {
        expect(syncStatusStateLabel('idle'), 'Idle');
        expect(syncStatusStateLabel('syncing'), 'Syncing');
        expect(syncStatusStateLabel('backing_off'), 'Backing off');
        expect(syncStatusStateLabel('blocked'), 'Blocked');
      },
    );

    testWidgets('detail screen shows the complete local sync summary', (
      tester,
    ) async {
      final summary = SyncSummary(
        cursor: 8,
        bootstrapped: true,
        status: 'syncing',
        lastSyncedAt: DateTime.utc(2026, 9, 13, 10, 2),
        lastError: 'network timeout',
        pendingOperationCount: 3,
        unresolvedConflictCount: 2,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncSummaryProvider.overrideWith((_) => Stream.value(summary)),
          ],
          child: const MaterialApp(home: SyncStatusDetailPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sync-status-state')), findsOneWidget);
      expect(find.text('Syncing'), findsAtLeastNWidgets(1));
      expect(
        find.descendant(
          of: find.byKey(const Key('sync-status-pending-count')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('sync-status-conflict-count')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('sync-status-last-successful-sync')),
          matching: find.text('2026-09-13 10:02 UTC'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('sync-status-error-summary')),
          matching: find.text('network timeout'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('status chip navigates to the local detail screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncSummaryProvider.overrideWith(
              (_) => Stream.value(
                const SyncSummary(
                  cursor: 0,
                  bootstrapped: false,
                  lastSyncedAt: null,
                  lastError: null,
                  pendingOperationCount: 0,
                  unresolvedConflictCount: 0,
                ),
              ),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: SyncStatusChip())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sync-status-chip')));
      await tester.pumpAndSettle();

      expect(find.text('Sync status'), findsOneWidget);
      expect(
        find.byKey(const Key('sync-status-detail-content')),
        findsOneWidget,
      );
    });

    testWidgets('detail screen offers manual sync when runtime is available', (
      tester,
    ) async {
      var synchronizeCalls = 0;
      final coordinator = SyncTriggerCoordinator(
        synchronize: () async {
          synchronizeCalls++;
          return null;
        },
        reachability: _ReachableProbe(),
      )..start(initiallyForeground: false);
      addTearDown(coordinator.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncSummaryProvider.overrideWith(
              (_) => Stream.value(
                const SyncSummary(
                  cursor: 0,
                  bootstrapped: false,
                  lastSyncedAt: null,
                  lastError: null,
                  pendingOperationCount: 0,
                  unresolvedConflictCount: 0,
                ),
              ),
            ),
            syncTriggerCoordinatorProvider.overrideWithValue(coordinator),
          ],
          child: const MaterialApp(home: SyncStatusDetailPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('manual-sync-detail-button')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('manual-sync-detail-button')));
      await tester.pumpAndSettle();
      expect(synchronizeCalls, 1);
    });
  });
}

Widget _statusTestApp(Stream<SyncSummary> summaries) {
  return ProviderScope(
    overrides: [syncSummaryProvider.overrideWith((_) => summaries)],
    child: const MaterialApp(home: Scaffold(body: LocalSyncStatusCard())),
  );
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  required String description,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $description.');
}

final class _ReachableProbe implements SyncReachabilityProbe {
  @override
  Future<bool> check() async => true;
}
