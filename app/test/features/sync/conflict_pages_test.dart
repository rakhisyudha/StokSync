import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/sync/conflict_pages.dart';

void main() {
  testWidgets('conflict detail shows reason and all retained payloads', (
    tester,
  ) async {
    final conflict = _versionConflict();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conflictDetailProvider(
            conflict.opId,
          ).overrideWith((_) => Stream.value(conflict)),
        ],
        child: const MaterialApp(
          home: ConflictDetailPage(operationId: _operationId),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conflict-reason')), findsOneWidget);
    expect(find.text('Product edit conflict'), findsOneWidget);
    expect(find.text('Base snapshot'), findsOneWidget);
    expect(find.text('Local intent'), findsOneWidget);
    expect(find.text('Canonical server state'), findsOneWidget);
    expect(find.textContaining('Base value'), findsOneWidget);
    expect(find.textContaining('Local value'), findsOneWidget);
    expect(find.textContaining('Server value'), findsOneWidget);
    expect(find.byKey(const Key('resolve-use-local-button')), findsOneWidget);
    expect(find.byKey(const Key('resolve-use-server-button')), findsOneWidget);
  });

  testWidgets('conflict list keeps resolved rows visible with their status', (
    tester,
  ) async {
    final conflict = _versionConflict().copyWith(resolutionStatus: 'resolved');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conflictsProvider.overrideWith((_) => Stream.value([conflict])),
        ],
        child: const MaterialApp(home: ConflictListPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(Key('conflict-row-$_operationId')), findsOneWidget);
    expect(find.text('0 unresolved conflicts'), findsOneWidget);
    expect(find.textContaining('Resolved'), findsOneWidget);
  });
}

const _operationId = '0192f3a1-0000-7000-8000-000000000001';

Conflict _versionConflict() {
  return Conflict(
    opId: _operationId,
    entity: 'product',
    entityId: '0192e1aa-0000-7000-8000-000000000001',
    localPayload: '{"name":"Local value"}',
    basePayload: '{"name":"Base value"}',
    serverPayload: '{"name":"Server value","version":2}',
    reason: 'version_conflict',
    createdAt: DateTime.utc(2026, 9, 13, 10),
    resolutionStatus: 'unresolved',
  );
}
