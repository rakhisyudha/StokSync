import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/movements/movement_destination_page.dart';

void main() {
  testWidgets(
    'shows a useful empty state for a local ledger with no movements',
    (tester) async {
      await tester.pumpWidget(_destinationApp(const []));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('movements-empty-state')), findsOneWidget);
      expect(find.text('No movements yet'), findsOneWidget);
      expect(
        find.text(
          'Stock changes from every product will appear here, newest first.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'shows newest cross-product rows with product identity and movement details',
    (tester) async {
      final older = _movement(
        id: 'older-movement',
        productId: 'coffee',
        occurredAt: DateTime.utc(2026, 9, 13, 9),
        delta: 2,
        note: 'Opening stock',
      );
      final newer = _movement(
        id: 'newer-movement',
        productId: 'tea',
        occurredAt: DateTime.utc(2026, 9, 13, 10),
        delta: -4,
        kind: 'stocktake',
        countedQty: 6,
        note: 'Cycle count',
      );
      await tester.pumpWidget(
        _destinationApp([
          MovementWithProduct(
            movement: newer,
            product: _product(
              id: 'tea',
              name: 'Tea',
              deletedAt: DateTime.utc(2026, 9, 13),
            ),
          ),
          MovementWithProduct(
            movement: older,
            product: _product(id: 'coffee', name: 'Coffee'),
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('all-movements-list')), findsOneWidget);
      expect(find.text('Tea'), findsOneWidget);
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.text('Stocktake'), findsOneWidget);
      expect(find.text('Delta: -4 pcs'), findsOneWidget);
      expect(find.text('Counted: 6 pcs'), findsOneWidget);
      expect(find.text('Note: Cycle count'), findsOneWidget);
      expect(find.text('Product ID: tea'), findsOneWidget);
      expect(find.text('Deleted product'), findsOneWidget);
      expect(
        find.byKey(const Key('reverse-all-movement-button-newer-movement')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.text('Tea')).dy,
        lessThan(tester.getTopLeft(find.text('Coffee')).dy),
      );
    },
  );
}

Widget _destinationApp(List<MovementWithProduct> movements) {
  return ProviderScope(
    overrides: [
      allMovementHistoryProvider.overrideWith((_) => Stream.value(movements)),
    ],
    child: const MaterialApp(home: MovementDestinationPage()),
  );
}

Product _product({
  required String id,
  required String name,
  DateTime? deletedAt,
}) {
  final now = DateTime.utc(2026, 9, 13);
  return Product(
    id: id,
    name: name,
    unit: 'pcs',
    version: 0,
    updatedAt: now,
    updatedBy: 'device-1',
    createdAt: now,
    syncStatus: 'synced',
    deletedAt: deletedAt,
  );
}

StockMovement _movement({
  required String id,
  required String productId,
  required DateTime occurredAt,
  required int delta,
  String kind = 'receive',
  String? note,
  int? countedQty,
}) {
  return StockMovement(
    id: id,
    productId: productId,
    delta: delta,
    kind: kind,
    note: note,
    occurredAt: occurredAt,
    rawOccurredAt: occurredAt,
    clockOffsetMs: 0,
    countedQty: countedQty,
    deviceId: 'device-1',
    syncStatus: 'synced',
  );
}
