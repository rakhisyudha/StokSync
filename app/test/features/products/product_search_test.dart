import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/local_query_providers.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/products/product_search.dart';

void main() {
  test('searches active local catalog entries by name, barcode, and SKU', () {
    final products = [
      _inventory(
        id: 'coffee',
        name: 'Coffee beans',
        barcode: '899100000001',
        sku: 'COF-01',
      ),
      _inventory(
        id: 'tea',
        name: 'Green tea',
        barcode: '899100000002',
        sku: 'TEA-02',
      ),
    ];

    expect(searchActiveProducts(products, 'coffee'), [products[0]]);
    expect(searchActiveProducts(products, '000002'), [products[1]]);
    expect(searchActiveProducts(products, 'cof-01'), [products[0]]);
    expect(searchActiveProducts(products, '   '), products);
    expect(searchActiveProducts(products, 'unknown'), isEmpty);
  });
}

ProductInventory _inventory({
  required String id,
  required String name,
  required String barcode,
  required String sku,
}) {
  final now = DateTime.utc(2026, 9, 13);
  return ProductInventory(
    product: Product(
      id: id,
      barcode: barcode,
      sku: sku,
      name: name,
      description: null,
      unit: 'pcs',
      category: null,
      minStock: null,
      version: 0,
      updatedAt: now,
      updatedBy: 'device-1',
      deletedAt: null,
      createdAt: now,
      syncStatus: 'pending',
    ),
    quantity: 0,
  );
}
