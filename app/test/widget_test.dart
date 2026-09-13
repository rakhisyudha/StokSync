import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/main.dart';

void main() {
  testWidgets('boots to the local product catalog', (tester) async {
    final database = StokSyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [stoksyncDatabaseProvider.overrideWithValue(database)],
        child: const StokSyncApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Products'), findsOneWidget);
    expect(
      find.text('No products yet. Add one to start your local catalog.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
