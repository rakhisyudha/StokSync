import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';
import 'package:stoksync/core/identity/device_identity.dart';
import 'package:stoksync/core/theme/app_theme.dart';
import 'package:stoksync/data/local/local_mutation_repositories.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/products/barcode_scanner_page.dart';
import 'package:stoksync/features/products/product_pages.dart';
import 'package:stoksync/features/products/product_providers.dart';

void main() {
  test('configures explicit product barcode and QR formats', () {
    expect(
      allowedProductBarcodeFormats,
      containsAll([
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.code128,
        BarcodeFormat.qrCode,
      ]),
    );
    expect(allowedProductBarcodeFormats, isNot(contains(BarcodeFormat.all)));
    expect(
      allowedProductBarcodeFormats.length,
      allowedProductBarcodeFormats.toSet().length,
    );
  });

  test('debounces the same normalized barcode within the read window', () {
    var now = DateTime.utc(2026, 9, 13, 10);
    final debouncer = BarcodeReadDebouncer(
      window: const Duration(seconds: 1),
      clock: () => now,
    );

    expect(debouncer.shouldAccept('  ABC-123  '), isTrue);
    expect(debouncer.shouldAccept('ABC-123'), isFalse);
    expect(debouncer.shouldAccept('OTHER-123'), isTrue);

    now = now.add(const Duration(milliseconds: 999));
    expect(debouncer.shouldAccept('OTHER-123'), isFalse);
    now = now.add(const Duration(milliseconds: 1));
    expect(debouncer.shouldAccept('OTHER-123'), isTrue);

    debouncer.reset();
    expect(debouncer.shouldAccept('ABC-123'), isTrue);
  });

  test(
    'matches only active local products by the exact normalized barcode',
    () {
      final active = _inventory(
        id: 'active-product',
        barcode: '899100000001',
        deletedAt: null,
      );
      final deleted = _inventory(
        id: 'deleted-product',
        barcode: '899100000002',
        deletedAt: DateTime.utc(2026, 9, 13),
      );

      expect(
        findActiveProductByBarcode([active, deleted], ' 899100000001 '),
        same(active),
      );
      expect(
        findActiveProductByBarcode([active, deleted], '899100000002'),
        isNull,
      );
      expect(findActiveProductByBarcode([active], '899100000099'), isNull);
    },
  );

  testWidgets('uses theme roles for the camera permission error and retry', (
    tester,
  ) async {
    var retried = false;
    final theme = buildStokSyncTheme(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: BarcodeScannerErrorView(
          error: const MobileScannerException(
            errorCode: MobileScannerErrorCode.permissionDenied,
          ),
          onRetry: () => retried = true,
        ),
      ),
    );

    expect(find.text('Camera permission required'), findsOneWidget);
    expect(
      find.text('Allow camera access in device settings, then try again.'),
      findsOneWidget,
    );
    final panel = tester.widget<Card>(
      find.byKey(const Key('scanner-error-panel')),
    );
    expect(panel.color, theme.colorScheme.errorContainer);
    final title = tester.widget<Text>(find.text('Camera permission required'));
    expect(title.style?.color, theme.colorScheme.onErrorContainer);

    await tester.tap(find.byKey(const Key('scanner-retry-button')));
    expect(retried, isTrue);
  });

  testWidgets('uses themed app bar, frame, and scanner guidance overlay', (
    tester,
  ) async {
    final theme = buildStokSyncTheme(Brightness.light);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeProductsProvider.overrideWith(
            (ref) => Stream<List<ProductInventory>>.value(
              const <ProductInventory>[],
            ),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: BarcodeScannerPage(
            matchedProductPageBuilder: (_) => const SizedBox.shrink(),
            createProductPageBuilder: (_) => const SizedBox.shrink(),
            scannerBuilder: (_, _) => const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scanner-overlay')), findsOneWidget);
    expect(find.byKey(const Key('scanner-frame')), findsOneWidget);
    expect(find.byKey(const Key('scanner-instructions')), findsOneWidget);
    expect(
      find.text('Point the camera at a product barcode or QR code.'),
      findsOneWidget,
    );

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, theme.colorScheme.surface);
    expect(appBar.foregroundColor, theme.colorScheme.onSurface);

    final frame = tester.widget<DecoratedBox>(
      find.byKey(const Key('scanner-frame')),
    );
    final frameDecoration = frame.decoration as BoxDecoration;
    expect(frameDecoration.border?.top.color, theme.colorScheme.primary);

    final instructionPanel = find.byKey(const Key('scanner-instructions'));
    final instructions = tester.widget<DecoratedBox>(
      find.descendant(
        of: instructionPanel,
        matching: find.byType(DecoratedBox),
      ),
    );
    final instructionDecoration = instructions.decoration as BoxDecoration;
    expect(
      instructionDecoration.color,
      theme.colorScheme.surface.withValues(alpha: 0.94),
    );
  });

  testWidgets('navigates to the matching product from the local catalog', (
    tester,
  ) async {
    final harness = _ProductScannerHarness();
    addTearDown(harness.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
    final created = await harness.productRepository.create(
      const ProductDraft(name: 'Coffee beans', barcode: '899100000001'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stoksyncDatabaseProvider.overrideWithValue(harness.database),
        ],
        child: MaterialApp(
          home: BarcodeScannerPage(
            matchedProductPageBuilder: (productId) =>
                Scaffold(body: Text('Matched $productId')),
            createProductPageBuilder: (_) => const SizedBox.shrink(),
            scannerBuilder: (_, onDetect) =>
                _FakeScanner(value: '899100000001', onDetect: onDetect),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('emit-barcode-button')));
    await tester.pumpAndSettle();

    expect(find.text('Matched ${created.productId}'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'offers unknown barcode creation with a prefilled local product form',
    (tester) async {
      final harness = _ProductScannerHarness();
      addTearDown(harness.close);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      });
      const scannedBarcode = '899100000099';

      final scannerPage = BarcodeScannerPage(
        matchedProductPageBuilder: (_) => const SizedBox.shrink(),
        createProductPageBuilder: (barcode) =>
            ProductFormPage(initialBarcode: barcode),
        scannerBuilder: (_, onDetect) =>
            _FakeScanner(value: scannedBarcode, onDetect: onDetect),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stoksyncDatabaseProvider.overrideWithValue(harness.database),
            localProductRepositoryProvider.overrideWithValue(
              harness.productRepository,
            ),
          ],
          child: MaterialApp(home: _ScannerHost(page: scannerPage)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open-scanner-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('emit-barcode-button')));
      await tester.pumpAndSettle();

      expect(find.text('Product not found'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('create-product-from-barcode-button')),
      );
      await tester.pumpAndSettle();

      final barcodeField = tester.widget<TextFormField>(
        find.byKey(const Key('product-barcode-field')),
      );
      expect(barcodeField.controller?.text, scannedBarcode);

      await tester.enterText(
        find.byKey(const Key('product-name-field')),
        'Unknown item',
      );
      await tester.ensureVisible(find.byKey(const Key('save-product-button')));
      await tester.tap(find.byKey(const Key('save-product-button')));
      await tester.pumpAndSettle();

      final products = await harness.database
          .select(harness.database.products)
          .get();
      expect(products, hasLength(1));
      expect(products.single.name, 'Unknown item');
      expect(products.single.barcode, scannedBarcode);
      expect(
        (await harness.database
                .select(harness.database.pendingOperations)
                .get())
            .single
            .operation,
        'upsert_product',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

final class _FakeScanner extends StatelessWidget {
  const _FakeScanner({required this.value, required this.onDetect});

  final String value;
  final ValueChanged<BarcodeCapture> onDetect;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton(
        key: const Key('emit-barcode-button'),
        onPressed: () =>
            onDetect(BarcodeCapture(barcodes: [Barcode(rawValue: value)])),
        child: const Text('Emit barcode'),
      ),
    );
  }
}

final class _ScannerHost extends StatelessWidget {
  const _ScannerHost({required this.page});

  final Widget page;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open-scanner-button'),
          onPressed: () => Navigator.of(
            context,
          ).push<void>(MaterialPageRoute(builder: (_) => page)),
          child: const Text('Open scanner'),
        ),
      ),
    );
  }
}

final class _ProductScannerHarness {
  _ProductScannerHarness()
    : database = StokSyncDatabase(NativeDatabase.memory()) {
    productRepository = LocalProductRepository(
      database: database,
      identifierGenerator: _SequenceIdentifierGenerator(
        List<String>.generate(20, _uuid),
      ),
      deviceIdentity: DeviceIdentity(
        secureStore: _MemorySecureStore(),
        identifierGenerator: _SequenceIdentifierGenerator([_uuid(900)]),
      ),
    );
  }

  final StokSyncDatabase database;
  late final LocalProductRepository productRepository;

  Future<void> close() => database.close();
}

ProductInventory _inventory({
  required String id,
  required String barcode,
  required DateTime? deletedAt,
}) {
  final now = DateTime.utc(2026, 9, 13);
  return ProductInventory(
    product: Product(
      id: id,
      barcode: barcode,
      sku: null,
      name: 'Product $id',
      description: null,
      unit: 'pcs',
      category: null,
      minStock: null,
      version: 0,
      updatedAt: now,
      updatedBy: 'device-1',
      deletedAt: deletedAt,
      createdAt: now,
      syncStatus: 'pending',
    ),
    quantity: 0,
  );
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
