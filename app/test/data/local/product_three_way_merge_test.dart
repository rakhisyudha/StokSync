import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/product_three_way_merge.dart';

void main() {
  group('ProductThreeWayMerge', () {
    test('merges disjoint local and server field edits', () {
      final result = ProductThreeWayMerge.compare(
        base: _product(name: 'Base product', minStock: 5),
        local: _product(name: 'Local name', minStock: 5),
        server: _product(name: 'Base product', minStock: 12),
      );

      expect(result, isNotNull);
      expect(result!.canAutoMerge, isTrue);
      expect(result.localChangedFields, {'name'});
      expect(result.serverChangedFields, {'min_stock'});
      expect(result.overlappingFields, isEmpty);
      expect(result.mergedPayload, {
        ..._product(name: 'Local name', minStock: 12),
      });
    });

    test('does not merge overlapping edits even when values match', () {
      final result = ProductThreeWayMerge.compare(
        base: _product(name: 'Base product', minStock: 5),
        local: _product(name: 'Same replacement', minStock: 5),
        server: _product(name: 'Same replacement', minStock: 5),
      );

      expect(result, isNotNull);
      expect(result!.canAutoMerge, isFalse);
      expect(result.overlappingFields, {'name'});
      expect(result.mergedPayload, isNull);
    });

    test('returns unavailable when a complete base is not present', () {
      final result = ProductThreeWayMerge.compare(
        base: <String, Object?>{'id': _productId, 'name': 'Base product'},
        local: _product(name: 'Local name', minStock: 5),
        server: _product(name: 'Base product', minStock: 12),
      );

      expect(result, isNull);
    });
  });
}

const _productId = '0192e1aa-0000-7000-8000-000000000001';

Map<String, Object?> _product({required String name, required int minStock}) {
  return <String, Object?>{
    'id': _productId,
    'barcode': 'barcode-1',
    'sku': 'sku-1',
    'name': name,
    'description': 'Description',
    'unit': 'pcs',
    'category': 'Food',
    'min_stock': minStock,
  };
}
