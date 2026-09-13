import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/movements/movement_providers.dart';
import 'package:stoksync/features/products/product_pages.dart';
import 'package:stoksync/features/products/product_providers.dart';

void main() {
  group('local movement entry flows', () {
    testWidgets(
      'submits receive and issue notes, updates balance/history, and validates adjustment input',
      (tester) async {
        final harness = _MovementFlowHarness();
        ProviderContainer? container;
        addTearDown(() async {
          container?.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.pump();
          await harness.close();
        });
        final product = await harness.productRepository.create(
          const ProductDraft(name: 'Coffee beans'),
        );

        container = await _pumpProductDetail(
          tester,
          harness,
          product.productId,
        );
        expect(find.text('Quantity: 0 pcs'), findsOneWidget);
        expect(find.text('No stock movements recorded yet.'), findsOneWidget);

        await tester.tap(find.byKey(const Key('receive-stock-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('movement-quantity-field')),
          '5',
        );
        await tester.enterText(
          find.byKey(const Key('movement-note-field')),
          'Inbound delivery',
        );
        await tester.tap(find.byKey(const Key('save-movement-button')));
        await tester.pumpAndSettle();

        expect(find.text('Quantity: 5 pcs'), findsOneWidget);
        expect(find.textContaining('Inbound delivery'), findsOneWidget);
        expect(find.text('Received stock'), findsOneWidget);

        await tester.ensureVisible(find.byKey(const Key('issue-stock-button')));
        await tester.tap(find.byKey(const Key('issue-stock-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('movement-quantity-field')),
          '0',
        );
        await tester.tap(find.byKey(const Key('save-movement-button')));
        await tester.pumpAndSettle();
        expect(
          find.text('Quantity must be greater than zero.'),
          findsOneWidget,
        );
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          hasLength(1),
        );
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('adjust-stock-button')),
        );
        await tester.tap(find.byKey(const Key('adjust-stock-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('movement-delta-field')),
          '-2',
        );
        await tester.enterText(
          find.byKey(const Key('movement-note-field')),
          'Damaged beans',
        );
        await tester.tap(find.byKey(const Key('save-movement-button')));
        await tester.pumpAndSettle();

        expect(find.text('Quantity: 3 pcs'), findsOneWidget);
        expect(find.textContaining('Damaged beans'), findsOneWidget);
        final movements = await (harness.database.select(
          harness.database.stockMovements,
        )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
        expect(movements, hasLength(2));
        expect(movements.map((movement) => movement.delta), [5, -2]);
        expect(
          (await harness.database
                  .select(harness.database.productBalances)
                  .getSingle())
              .qty,
          3,
        );
      },
    );

    testWidgets(
      'reverses an immutable movement and records stocktake count and delta',
      (tester) async {
        final harness = _MovementFlowHarness();
        ProviderContainer? container;
        addTearDown(() async {
          container?.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.pump();
          await harness.close();
        });
        final product = await harness.productRepository.create(
          const ProductDraft(name: 'Rice'),
        );
        final original = await harness.movementRepository.receive(
          productId: product.productId,
          quantity: 10,
          note: 'Opening delivery',
        );

        container = await _pumpProductDetail(
          tester,
          harness,
          product.productId,
        );
        final reverseButton = find.byKey(
          Key('reverse-movement-button-${original.movementId}'),
        );
        await tester.ensureVisible(reverseButton);
        await tester.tap(reverseButton);
        await tester.pumpAndSettle();
        expect(find.text('Original delta: +10'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('movement-reversal-note-field')),
          'Undo opening delivery',
        );
        await tester.tap(find.byKey(const Key('save-reversal-button')));
        await tester.pumpAndSettle();

        expect(find.text('Quantity: 0 pcs'), findsOneWidget);
        expect(find.textContaining('Undo opening delivery'), findsOneWidget);
        var movements = await (harness.database.select(
          harness.database.stockMovements,
        )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
        expect(movements, hasLength(2));
        final reversal = movements.singleWhere(
          (movement) => movement.id == original.movementId,
          orElse: () => throw StateError('Original movement was not retained.'),
        );
        final reversalRow = movements.singleWhere(
          (movement) => movement.reversesId == original.movementId,
        );
        expect(reversal.delta, 10);
        expect(reversalRow.delta, -10);
        expect(reversalRow.kind, 'adjust');

        await tester.ensureVisible(find.byKey(const Key('stocktake-button')));
        await tester.tap(find.byKey(const Key('stocktake-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('movement-counted-quantity-field')),
          '4',
        );
        await tester.enterText(
          find.byKey(const Key('movement-note-field')),
          'Physical count',
        );
        await tester.tap(find.byKey(const Key('save-movement-button')));
        await tester.pumpAndSettle();

        expect(find.text('Quantity: 4 pcs'), findsOneWidget);
        expect(find.textContaining('Counted 4'), findsOneWidget);
        expect(find.textContaining('Physical count'), findsOneWidget);
        movements = await harness.database
            .select(harness.database.stockMovements)
            .get();
        final stocktake = movements.singleWhere(
          (movement) => movement.kind == 'stocktake',
        );
        expect(stocktake.countedQty, 4);
        expect(stocktake.delta, 4);
        expect(stocktake.reversesId, isNull);

        await tester.ensureVisible(find.byKey(const Key('stocktake-button')));
        await tester.tap(find.byKey(const Key('stocktake-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('movement-counted-quantity-field')),
          '4',
        );
        await tester.tap(find.byKey(const Key('save-movement-button')));
        await tester.pumpAndSettle();
        expect(
          find.text('Counted quantity must differ from the current balance.'),
          findsOneWidget,
        );
        expect(
          await harness.database.select(harness.database.stockMovements).get(),
          hasLength(3),
        );
      },
    );
  });
}

Future<ProviderContainer> _pumpProductDetail(
  WidgetTester tester,
  _MovementFlowHarness harness,
  String productId,
) async {
  final container = ProviderContainer(
    overrides: [
      stoksyncDatabaseProvider.overrideWithValue(harness.database),
      localProductRepositoryProvider.overrideWithValue(
        harness.productRepository,
      ),
      localStockMovementRepositoryProvider.overrideWithValue(
        harness.movementRepository,
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: ProductDetailPage(productId: productId)),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

final class _MovementFlowHarness {
  _MovementFlowHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()) {
    productRepository = LocalProductRepository(
      database: database,
      identifierGenerator: _SequenceIdentifierGenerator(
        List<String>.generate(10, _uuid),
      ),
      deviceIdentity: DeviceIdentity(
        secureStore: _MemorySecureStore(),
        identifierGenerator: _SequenceIdentifierGenerator([_uuid(900)]),
      ),
    );
    movementRepository = LocalStockMovementRepository(
      database: database,
      identifierGenerator: _SequenceIdentifierGenerator(
        List<String>.generate(40, (index) => _uuid(index + 100)),
      ),
      deviceIdentity: DeviceIdentity(
        secureStore: _MemorySecureStore(),
        identifierGenerator: _SequenceIdentifierGenerator([_uuid(900)]),
      ),
    );
  }

  final StokSyncDatabase database;
  late LocalProductRepository productRepository;
  late LocalStockMovementRepository movementRepository;

  Future<void> close() async {
    await database.close();
  }
}

final class _SequenceIdentifierGenerator implements IdentifierGenerator {
  _SequenceIdentifierGenerator(this._identifiers);

  final List<String> _identifiers;

  @override
  String generate() {
    if (_identifiers.isEmpty) {
      throw StateError('No test identifiers remain.');
    }
    return _identifiers.removeAt(0);
  }
}

final class _MemorySecureStore implements SecureKeyValueStore {
  String? _value;

  @override
  Future<String?> read(String key) => Future.value(_value);

  @override
  Future<void> write({required String key, required String value}) async {
    _value = value;
  }
}

String _uuid(int index) {
  return '0192f200-${index.toRadixString(16).padLeft(4, '0')}-7000-8000-'
      '${index.toRadixString(16).padLeft(12, '0')}';
}
