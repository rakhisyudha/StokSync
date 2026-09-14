import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/main.dart';

void main() {
  testWidgets('boots to the local product catalog', (tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeProductsProvider.overrideWith(
            (_) => Stream.value(const <ProductInventory>[]),
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
        ],
        child: const StokSyncApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Products'), findsOneWidget);
    expect(find.byKey(const Key('sync-status-card')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('sync-status-card')),
        matching: find.text('Local only'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('No products yet. Add one to start your local catalog.'),
      findsOneWidget,
    );
  });

  testWidgets('uses the system theme mode with light and dark app themes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const StokSyncApp(authenticatedHome: SizedBox.shrink()),
    );

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));

    expect(app.themeMode, ThemeMode.system);
    expect(app.theme?.useMaterial3, isTrue);
    expect(app.darkTheme?.useMaterial3, isTrue);
    expect(app.theme?.colorScheme.brightness, Brightness.light);
    expect(app.darkTheme?.colorScheme.brightness, Brightness.dark);
    expect(app.theme?.textTheme.bodyMedium?.fontFamily, startsWith('Inter'));
    expect(
      app.darkTheme?.textTheme.bodyMedium?.fontFamily,
      startsWith('Inter'),
    );
  });
}
