import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';

void main() {
  test(
    'conflict streams include resolved history and react to status changes',
    () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: [stoksyncDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      final values = <List<Conflict>>[];
      container.listen<AsyncValue<List<Conflict>>>(conflictsProvider, (
        _,
        next,
      ) {
        if (next.hasValue) {
          values.add(next.value!);
        }
      }, fireImmediately: true);

      await _waitUntil(() => values.any((conflicts) => conflicts.isEmpty));
      await database
          .into(database.conflicts)
          .insert(
            ConflictsCompanion.insert(
              opId: 'operation-1',
              entity: 'product',
              entityId: 'product-1',
              localPayload: '{"name":"Local"}',
              basePayload: const Value('{"name":"Base"}'),
              serverPayload: const Value('{"name":"Server"}'),
              reason: 'version_conflict',
              createdAt: Value(DateTime.utc(2026, 9, 13, 10)),
            ),
          );
      await _waitUntil(
        () => values.any(
          (conflicts) =>
              conflicts.length == 1 &&
              conflicts.single.resolutionStatus == 'unresolved',
        ),
      );

      await (database.update(database.conflicts)
            ..where((row) => row.opId.equals('operation-1')))
          .write(const ConflictsCompanion(resolutionStatus: Value('resolved')));
      await _waitUntil(
        () => values.any(
          (conflicts) =>
              conflicts.length == 1 &&
              conflicts.single.resolutionStatus == 'resolved',
        ),
      );

      expect(values.last.single.reason, 'version_conflict');
      expect(values.last.single.localPayload, '{"name":"Local"}');
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for conflict provider output.');
}
