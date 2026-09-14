import 'dart:convert';

import 'package:drift/drift.dart';
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
    expect(find.textContaining('Base value'), findsOneWidget);
    expect(find.textContaining('Local value'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Canonical server state'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Canonical server state'), findsOneWidget);
    expect(find.textContaining('Server value'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('resolve-use-local-button')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('resolve-use-local-button')), findsOneWidget);
    expect(find.byKey(const Key('resolve-use-server-button')), findsOneWidget);
  });

  testWidgets(
    'conflict payloads render all fields with known labels and raw fallback keys',
    (tester) async {
      final conflict = _fieldRichConflict();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conflictDetailProvider(
              conflict.opId,
            ).overrideWith((_) => Stream.value(conflict)),
          ],
          child: const MaterialApp(
            home: ConflictDetailPage(operationId: _fieldRichOperationId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final expectedFields = <String, (String, String)>{
        'id': ('ID', 'movement-1'),
        'product_id': ('Product ID', 'product-1'),
        'name': ('Name', 'Local name'),
        'barcode': ('Barcode', '0123456789'),
        'sku': ('SKU', 'SKU-1'),
        'description': ('Description', 'A local description'),
        'category': ('Category', 'Beverage'),
        'unit': ('Unit', 'pcs'),
        'min_stock': ('Minimum stock', '4'),
        'version': ('Version', '7'),
        'delta': ('Quantity change', '-3'),
        'kind': ('Movement type', 'issue'),
        'note': ('Note', 'Sold at the counter'),
        'occurred_at': ('Occurred at', '2026-09-13T09:41:02Z'),
        'raw_occurred_at': ('Original occurred at', '2026-09-13T09:40:00Z'),
        'clock_offset_ms': ('Clock offset (ms)', '120'),
        'counted_qty': ('Counted quantity', '12'),
        'reverses_id': ('Reverses movement ID', 'movement-0'),
        'device_id': ('Originating device ID', 'device-1'),
        'server_created_at': ('Server received at', '2026-09-13T10:00:00Z'),
      };

      for (final entry in expectedFields.entries) {
        final fieldKey = Key('local-payload-field-${entry.key}');
        await tester.scrollUntilVisible(
          find.byKey(fieldKey),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byKey(fieldKey), findsOneWidget);
        expect(find.text(entry.value.$1), findsAtLeastNWidgets(1));
        expect(find.text(entry.value.$2), findsOneWidget);
      }

      expect(
        find.byKey(const Key('local-payload-field-unknown_field')),
        findsOneWidget,
      );
      expect(find.text('unknown_field'), findsOneWidget);
      expect(find.text('Forward-compatible value'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('base-payload-field-base_only')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('base_only'), findsOneWidget);
      expect(find.text('Base-only value'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('server-payload-field-server_only')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('server_only'), findsOneWidget);
      expect(find.text('Server-only value'), findsOneWidget);
    },
  );

  testWidgets(
    'conflict payloads keep scalar, list, and invalid JSON readable',
    (tester) async {
      final conflict = _versionConflict().copyWith(
        basePayload: const Value('not-valid-json'),
        localPayload: '42',
        serverPayload: const Value('["one","two"]'),
      );
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

      expect(
        find.byKey(const Key('base-payload-field-payload')),
        findsOneWidget,
      );
      expect(find.text('not-valid-json'), findsOneWidget);
      expect(
        find.byKey(const Key('local-payload-field-payload')),
        findsOneWidget,
      );
      expect(find.text('42'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('server-payload-field-payload')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const Key('server-payload-field-payload')),
        findsOneWidget,
      );
      expect(find.textContaining('"one"'), findsOneWidget);
      expect(find.textContaining('"two"'), findsOneWidget);
    },
  );

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
    expect(find.byKey(Key('conflict-timestamp-$_operationId')), findsOneWidget);
  });
}

const _operationId = '0192f3a1-0000-7000-8000-000000000001';
const _fieldRichOperationId = '0192f3a1-0000-7000-8000-000000000002';

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

Conflict _fieldRichConflict() {
  return Conflict(
    opId: _fieldRichOperationId,
    entity: 'stock_movement',
    entityId: 'movement-1',
    localPayload: jsonEncode({
      'id': 'movement-1',
      'product_id': 'product-1',
      'name': 'Local name',
      'barcode': '0123456789',
      'sku': 'SKU-1',
      'description': 'A local description',
      'category': 'Beverage',
      'unit': 'pcs',
      'min_stock': 4,
      'version': 7,
      'deleted_at': null,
      'delta': -3,
      'kind': 'issue',
      'note': 'Sold at the counter',
      'occurred_at': '2026-09-13T09:41:02Z',
      'raw_occurred_at': '2026-09-13T09:40:00Z',
      'clock_offset_ms': 120,
      'counted_qty': 12,
      'reverses_id': 'movement-0',
      'device_id': 'device-1',
      'server_created_at': '2026-09-13T10:00:00Z',
      'unknown_field': 'Forward-compatible value',
    }),
    basePayload: jsonEncode({
      'name': 'Base value',
      'base_only': 'Base-only value',
    }),
    serverPayload: jsonEncode({
      'version': 8,
      'server_only': 'Server-only value',
    }),
    reason: 'version_conflict',
    createdAt: DateTime.utc(2026, 9, 13, 10),
    resolutionStatus: 'unresolved',
  );
}
