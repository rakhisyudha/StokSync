import '../../data/local/local_query_providers.dart';

/// Filters active local catalog entries by name, barcode, or SKU.
///
/// Callers supply values from [activeProductsProvider], which already excludes
/// tombstones. An empty query preserves that local catalog order.
List<ProductInventory> searchActiveProducts(
  Iterable<ProductInventory> products,
  String query,
) {
  final normalizedQuery = query.trim().toLowerCase();
  final entries = products.toList(growable: false);
  if (normalizedQuery.isEmpty) {
    return entries;
  }

  return entries
      .where((inventory) {
        final product = inventory.product;
        return _contains(product.name, normalizedQuery) ||
            _contains(product.barcode, normalizedQuery) ||
            _contains(product.sku, normalizedQuery);
      })
      .toList(growable: false);
}

bool _contains(String? value, String query) =>
    value?.toLowerCase().contains(query) ?? false;
