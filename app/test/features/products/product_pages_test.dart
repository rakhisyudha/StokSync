import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/products/product_pages.dart';
import 'package:stoksync/features/products/product_providers.dart';

void main() {
  testWidgets(
    'browses, searches, creates, edits, details, and soft-deletes locally',
    (tester) async {
      final harness = _ProductFlowHarness();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        await harness.close();
        await tester.pump(const Duration(milliseconds: 1));
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stoksyncDatabaseProvider.overrideWithValue(harness.database),
            localProductRepositoryProvider.overrideWithValue(
              harness.productRepository,
            ),
          ],
          child: const MaterialApp(home: ProductBrowsePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('No products yet. Add one to start your local catalog.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('add-product-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'Coffee beans',
      );
      await tester.enterText(
        find.byKey(const Key('product-barcode-field')),
        '899100000001',
      );
      await tester.enterText(
        find.byKey(const Key('product-sku-field')),
        'COF-01',
      );
      await tester.ensureVisible(find.byKey(const Key('save-product-button')));
      await tester.tap(find.byKey(const Key('save-product-button')));
      await tester.pumpAndSettle();

      expect(find.text('Quantity: 0 pcs'), findsOneWidget);
      expect(
        await harness.database.select(harness.database.products).get(),
        hasLength(1),
      );

      await tester.tap(find.byKey(const Key('edit-product-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'Premium coffee beans',
      );
      await tester.ensureVisible(find.byKey(const Key('save-product-button')));
      await tester.tap(find.byKey(const Key('save-product-button')));
      await tester.pumpAndSettle();
      expect(find.text('Premium coffee beans'), findsWidgets);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('product-search-field')),
        '899100000001',
      );
      await tester.pumpAndSettle();
      expect(find.text('Premium coffee beans'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('product-search-field')),
        'tea',
      );
      await tester.pumpAndSettle();
      expect(find.text('No products match “tea”.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('product-search-field')),
        'coffee',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Premium coffee beans'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-product-button')));
      await tester.pumpAndSettle();
      expect(find.text('Delete product?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-delete-product-button')));
      await tester.pumpAndSettle();

      expect(find.text('No products match “coffee”.'), findsOneWidget);
      final product = await harness.database
          .select(harness.database.products)
          .getSingle();
      expect(product.deletedAt, isNotNull);
      final pendingOperations = await harness.database
          .select(harness.database.pendingOperations)
          .get();
      expect(pendingOperations.map((operation) => operation.operation), [
        'upsert_product',
        'upsert_product',
        'delete_product',
      ]);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

final class _ProductFlowHarness {
  _ProductFlowHarness() : database = StokSyncDatabase(NativeDatabase.memory()) {
    productRepository = LocalProductRepository(
      database: database,
      identifierGenerator: _SequenceIdentifierGenerator(
        List<String>.generate(10, _uuid),
      ),
      deviceIdentity: DeviceIdentity(
        secureStore: _MemorySecureStore(),
        identifierGenerator: _SequenceIdentifierGenerator([_uuid(100)]),
      ),
    );
  }

  final StokSyncDatabase database;
  late final LocalProductRepository productRepository;

  Future<void> close() => database.close();
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
