import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/navigation/authenticated_root_shell.dart';

void main() {
  testWidgets('renders the four authenticated destinations in order', (
    tester,
  ) async {
    await tester.pumpWidget(_shellTestApp());
    await tester.pumpAndSettle();

    final navigationBar = tester.widget<NavigationBar>(
      find.byKey(const Key('authenticated-navigation-bar')),
    );
    expect(
      navigationBar.destinations.cast<NavigationDestination>().map(
        (destination) => destination.label,
      ),
      ['Products', 'Movements', 'Sync', 'Conflicts'],
    );
    expect(navigationBar.selectedIndex, 0);
    final destinationStack = tester.widget<IndexedStack>(
      find.byKey(const Key('authenticated-destination-stack')),
    );
    expect(destinationStack.index, 0);
    expect(destinationStack.children, hasLength(4));
    expect(destinationStack.children, everyElement(isA<KeyedSubtree>()));

    expect(
      find.text('No products yet. Add one to start your local catalog.'),
      findsOneWidget,
    );
  });

  testWidgets('opens Settings from the shell action without adding a tab', (
    tester,
  ) async {
    await tester.pumpWidget(_shellTestApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-settings-button')));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('appearance-settings-card')), findsOneWidget);
  });

  testWidgets(
    'switches the selected destination without rebuilding the shell',
    (tester) async {
      await tester.pumpWidget(_shellTestApp());
      await tester.pumpAndSettle();

      for (final destination in [
        ('movements-navigation-destination', 1),
        ('sync-navigation-destination', 2),
        ('conflicts-navigation-destination', 3),
        ('products-navigation-destination', 0),
      ]) {
        await tester.tap(find.byKey(Key(destination.$1)));
        await tester.pumpAndSettle();

        final navigationBar = tester.widget<NavigationBar>(
          find.byKey(const Key('authenticated-navigation-bar')),
        );
        final stack = tester.widget<IndexedStack>(
          find.byKey(const Key('authenticated-destination-stack')),
        );
        expect(navigationBar.selectedIndex, destination.$2);
        expect(stack.index, destination.$2);
        switch (destination.$2) {
          case 0:
            expect(
              find.text(
                'No products yet. Add one to start your local catalog.',
              ),
              findsOneWidget,
            );
          case 1:
            expect(
              find.byKey(const Key('movements-empty-state')),
              findsOneWidget,
            );
          case 2:
            expect(
              find.byKey(const Key('sync-destination-page')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('sync-status-detail-content')),
              findsOneWidget,
            );
            expect(find.text('Sync status'), findsOneWidget);
          case 3:
            expect(
              find.byKey(const Key('conflicts-destination')),
              findsOneWidget,
            );
            expect(
              find.text('No conflicts recorded on this device.'),
              findsOneWidget,
            );
        }
      }
    },
  );
}

Widget _shellTestApp() {
  return ProviderScope(
    overrides: [
      activeProductsProvider.overrideWith(
        (_) => Stream.value(const <ProductInventory>[]),
      ),
      allMovementHistoryProvider.overrideWith(
        (_) => Stream.value(const <MovementWithProduct>[]),
      ),
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
      conflictsProvider.overrideWith((_) => Stream.value(const <Conflict>[])),
    ],
    child: const MaterialApp(home: AuthenticatedRootShell()),
  );
}
