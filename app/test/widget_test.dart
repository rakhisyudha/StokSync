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
}
