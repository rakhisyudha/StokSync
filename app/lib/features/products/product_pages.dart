import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/local/local_mutation_repositories.dart';
import '../../data/local/local_query_providers.dart';
import '../../data/local/stoksync_database.dart';
import '../movements/movement_pages.dart';
import '../sync/sync_status_widgets.dart';
import 'barcode_scanner_page.dart';
import 'product_providers.dart';
import 'product_search.dart';

/// Local-only product catalog browse and search screen.
class ProductBrowsePage extends ConsumerStatefulWidget {
  const ProductBrowsePage({super.key});

  @override
  ConsumerState<ProductBrowsePage> createState() => _ProductBrowsePageState();
}

class _ProductBrowsePageState extends ConsumerState<ProductBrowsePage> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(activeProductsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Products'),
            Text(
              'Local inventory workspace',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('scan-product-button'),
            tooltip: 'Scan barcode',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanProduct,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-product-button'),
        heroTag: 'add-product-fab',
        onPressed: _createProduct,
        icon: const Icon(Icons.add),
        label: const Text('Add product'),
      ),
      body: Column(
        children: [
          const LocalSyncStatusCard(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: TextField(
              key: const Key('product-search-field'),
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Search products',
                hintText: 'Name, barcode, or SKU',
                prefixIcon: Icon(Icons.search),
                filled: true,
              ),
            ),
          ),
          Expanded(
            child: products.when(
              loading: () => const _ProductStateMessage(
                key: Key('product-catalog-loading-state'),
                icon: Icons.inventory_2_outlined,
                message: 'Loading local catalog…',
                loading: true,
              ),
              error: (_, _) => const _ProductStateMessage(
                key: Key('product-catalog-error-state'),
                icon: Icons.error_outline,
                message: 'Local catalog is unavailable.',
                isError: true,
              ),
              data: _buildProductList,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductList(List<ProductInventory> products) {
    final filteredProducts = searchActiveProducts(
      products,
      _searchController.text,
    );
    if (filteredProducts.isEmpty) {
      final query = _searchController.text.trim();
      return _ProductEmptyState(query: query);
    }

    final lowStockCount = filteredProducts.where(_isLowStock).length;
    final hasLowStockSummary = lowStockCount > 0;

    return ListView.separated(
      key: const Key('product-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 112),
      itemCount: filteredProducts.length + (hasLowStockSummary ? 1 : 0),
      separatorBuilder: (_, index) {
        if (hasLowStockSummary && index == 0) {
          return const SizedBox(height: 12);
        }
        return const SizedBox(height: 8);
      },
      itemBuilder: (context, index) {
        if (hasLowStockSummary && index == 0) {
          return _LowStockSummary(count: lowStockCount);
        }
        final productIndex = hasLowStockSummary ? index - 1 : index;
        final inventory = filteredProducts[productIndex];
        return _ProductCard(
          key: Key('product-row-${inventory.product.id}'),
          inventory: inventory,
          onTap: () => _openProduct(inventory.product.id),
        );
      },
    );
  }

  Future<void> _scanProduct() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BarcodeScannerPage(
          matchedProductPageBuilder: (productId) =>
              ProductDetailPage(productId: productId),
          createProductPageBuilder: (barcode) =>
              ProductFormPage(initialBarcode: barcode),
        ),
      ),
    );
  }

  Future<void> _createProduct() async {
    final productId = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ProductFormPage()));
    if (!mounted || productId == null) {
      return;
    }
    await _openProduct(productId);
  }

  Future<void> _openProduct(String productId) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProductDetailPage(productId: productId),
      ),
    );
  }
}

class _ProductStateMessage extends StatelessWidget {
  const _ProductStateMessage({
    super.key,
    required this.icon,
    required this.message,
    this.loading = false,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final bool loading;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final foreground = isError ? colorScheme.error : colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              CircularProgressIndicator(color: colorScheme.primary)
            else
              Icon(icon, size: 48, color: foreground),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductEmptyState extends StatelessWidget {
  const _ProductEmptyState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final hasQuery = query.isNotEmpty;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView(
      key: const Key('product-empty-state'),
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 112),
      children: [
        Icon(
          hasQuery ? Icons.search_off : Icons.inventory_2_outlined,
          size: 64,
          color: colorScheme.primary,
        ),
        const SizedBox(height: 20),
        Text(
          hasQuery
              ? 'No products match “$query”.'
              : 'No products yet. Add one to start your local catalog.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          hasQuery
              ? 'Try a different name, barcode, or SKU.'
              : 'Products created here are available immediately, even offline.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _LowStockSummary extends StatelessWidget {
  const _LowStockSummary({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      key: const Key('low-stock-summary'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: colorScheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Low stock', style: theme.textTheme.titleSmall),
                  Text(
                    '$count ${count == 1 ? 'product is' : 'products are'} at or below the minimum.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({super.key, required this.inventory, required this.onTap});

  final ProductInventory inventory;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final product = inventory.product;
    final isLowStock = _isLowStock(inventory);
    final identifiers = [
      if (product.sku != null) 'SKU ${product.sku}',
      if (product.barcode != null) product.barcode!,
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: isLowStock
                      ? colorScheme.errorContainer
                      : colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Icon(
                    isLowStock
                        ? Icons.inventory_2_outlined
                        : Icons.inventory_2_outlined,
                    color: isLowStock
                        ? colorScheme.onErrorContainer
                        : colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      identifiers.isEmpty
                          ? 'No barcode or SKU'
                          : identifiers.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isLowStock) ...[
                      const SizedBox(height: 8),
                      const _LowStockChip(),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${inventory.quantity}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: isLowStock
                          ? colorScheme.error
                          : colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.end,
                  ),
                  Text(
                    product.unit,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Icon(
                    Icons.chevron_right,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LowStockChip extends StatelessWidget {
  const _LowStockChip();

  @override
  Widget build(BuildContext context) {
    final semantic = semanticColorsOf(context);
    return Chip(
      avatar: Icon(
        Icons.warning_amber_rounded,
        size: 16,
        color: semantic.onWarningContainer,
      ),
      label: const Text('Low stock'),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      backgroundColor: semantic.warningContainer,
      side: BorderSide(color: semantic.warning),
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: semantic.onWarningContainer,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

bool _isLowStock(ProductInventory inventory) {
  final minimum = inventory.product.minStock;
  return minimum != null && inventory.quantity <= minimum;
}

/// Local product details, including the local derived balance and metadata.
class ProductDetailPage extends ConsumerWidget {
  const ProductDetailPage({super.key, required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(productDetailProvider(productId));
    return detail.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Product details')),
        body: const _ProductStateMessage(
          key: Key('product-detail-loading-state'),
          icon: Icons.inventory_2_outlined,
          message: 'Loading product details…',
          loading: true,
        ),
      ),
      error: (_, _) => Scaffold(
        appBar: AppBar(title: const Text('Product details')),
        body: const _ProductStateMessage(
          key: Key('product-detail-error-state'),
          icon: Icons.error_outline,
          message: 'Local product details are unavailable.',
          isError: true,
        ),
      ),
      data: (inventory) {
        if (inventory == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Product details')),
            body: const _ProductStateMessage(
              key: Key('product-detail-not-found-state'),
              icon: Icons.search_off,
              message: 'Product was not found locally.',
              isError: true,
            ),
          );
        }
        final product = inventory.product;
        final isDeleted = product.deletedAt != null;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              product.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (!isDeleted)
                IconButton(
                  key: const Key('delete-product-button'),
                  tooltip: 'Delete product',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(context, ref),
                ),
              if (!isDeleted)
                IconButton(
                  key: const Key('edit-product-button'),
                  tooltip: 'Edit product',
                  icon: const Icon(Icons.edit),
                  onPressed: () => _editProduct(context, product),
                ),
            ],
          ),
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ProductStockSummary(inventory: inventory),
                  const SizedBox(height: 16),
                  if (isDeleted)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_outline,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text('This product is deleted locally.'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    _MovementActionBar(productId: product.id),
                  const SizedBox(height: 16),
                  _ProductInformationCard(product: product),
                  const SizedBox(height: 16),
                  _MovementHistorySection(
                    history: ref.watch(movementHistoryProvider(productId)),
                    canReverse: !isDeleted,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _editProduct(BuildContext context, Product product) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ProductFormPage(productId: product.id, initial: product),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete product?'),
        content: const Text(
          'The product will be hidden from the active catalog. Its stock history remains available locally.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete-product-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }

    try {
      await ref.read(localProductRepositoryProvider).softDelete(productId);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    } on LocalMutationValidationException catch (error) {
      if (!context.mounted) {
        return;
      }
      _showLocalError(context, error.message);
    } on Exception {
      if (!context.mounted) {
        return;
      }
      _showLocalError(context, 'Could not delete the product locally.');
    }
  }
}

class _ProductStockSummary extends StatelessWidget {
  const _ProductStockSummary({required this.inventory});

  final ProductInventory inventory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final product = inventory.product;
    final isLowStock = _isLowStock(inventory);
    return Card(
      key: const Key('product-stock-summary'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Icon(
                  Icons.inventory_2_outlined,
                  size: 28,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Current stock', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Quantity: ${inventory.quantity} ${product.unit}',
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (product.minStock != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Minimum ${product.minStock} ${product.unit}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (isLowStock) const _LowStockChip(),
          ],
        ),
      ),
    );
  }
}

class _ProductInformationCard extends StatelessWidget {
  const _ProductInformationCard({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('product-information-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Product details',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _ProductDetailField(label: 'Name', value: product.name),
            _ProductDetailField(label: 'Barcode', value: product.barcode),
            _ProductDetailField(label: 'SKU', value: product.sku),
            _ProductDetailField(
              label: 'Description',
              value: product.description,
            ),
            _ProductDetailField(label: 'Category', value: product.category),
            _ProductDetailField(
              label: 'Minimum stock',
              value: product.minStock?.toString(),
            ),
            _ProductDetailField(label: 'Unit', value: product.unit),
          ],
        ),
      ),
    );
  }
}

class _MovementActionBar extends StatelessWidget {
  const _MovementActionBar({required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          key: const Key('movement-action-bar'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Stock actions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('receive-stock-button'),
                  onPressed: () => _openMovement(
                    context,
                    productId,
                    MovementEntryMode.receive,
                  ),
                  icon: const Icon(Icons.add_box_outlined),
                  label: const Text('Receive'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('issue-stock-button'),
                  onPressed: () => _openMovement(
                    context,
                    productId,
                    MovementEntryMode.issue,
                  ),
                  icon: const Icon(Icons.outbox_outlined),
                  label: const Text('Issue'),
                ),
                OutlinedButton.icon(
                  key: const Key('adjust-stock-button'),
                  onPressed: () => _openMovement(
                    context,
                    productId,
                    MovementEntryMode.adjustment,
                  ),
                  icon: const Icon(Icons.tune),
                  label: const Text('Adjust'),
                ),
                OutlinedButton.icon(
                  key: const Key('stocktake-button'),
                  onPressed: () => _openMovement(
                    context,
                    productId,
                    MovementEntryMode.stocktake,
                  ),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Stocktake'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMovement(
    BuildContext context,
    String productId,
    MovementEntryMode mode,
  ) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MovementEntryPage(productId: productId, mode: mode),
      ),
    );
  }
}

class _MovementHistorySection extends StatelessWidget {
  const _MovementHistorySection({
    required this.history,
    required this.canReverse,
  });

  final AsyncValue<List<StockMovement>> history;
  final bool canReverse;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          key: const Key('movement-history-section'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Movement history',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            history.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, _) => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Movement history is unavailable.'),
              ),
              data: (movements) {
                if (movements.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No stock movements recorded yet.'),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: movements.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _MovementHistoryRow(
                    movement: movements[index],
                    canReverse: canReverse,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MovementHistoryRow extends StatelessWidget {
  const _MovementHistoryRow({required this.movement, required this.canReverse});

  final StockMovement movement;
  final bool canReverse;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      'Delta ${_signedMovementDelta(movement.delta)}',
      if (movement.countedQty != null) 'Counted ${movement.countedQty}',
      if (movement.note != null) movement.note!,
    ];
    return ListTile(
      key: Key('movement-row-${movement.id}'),
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
        child: Icon(_movementKindIcon(movement.kind)),
      ),
      title: Text(_movementKindLabel(movement.kind)),
      subtitle: Text(details.join(' · ')),
      trailing: canReverse
          ? IconButton(
              key: Key('reverse-movement-button-${movement.id}'),
              tooltip: 'Reverse movement',
              icon: const Icon(Icons.undo),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => MovementReversalPage(movement: movement),
                ),
              ),
            )
          : null,
    );
  }
}

IconData _movementKindIcon(String kind) {
  return switch (kind) {
    'receive' => Icons.add_box_outlined,
    'issue' => Icons.outbox_outlined,
    'adjust' => Icons.tune,
    'stocktake' => Icons.fact_check_outlined,
    _ => Icons.swap_horiz,
  };
}

String _movementKindLabel(String kind) {
  return switch (kind) {
    'receive' => 'Received stock',
    'issue' => 'Issued stock',
    'adjust' => 'Stock adjustment',
    'stocktake' => 'Stocktake',
    _ => 'Stock movement',
  };
}

String _signedMovementDelta(int delta) => delta > 0 ? '+$delta' : '$delta';

class _ProductDetailField extends StatelessWidget {
  const _ProductDetailField({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 2),
          Text(value!, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

/// Form for creating or editing a product through the local repository.
class ProductFormPage extends ConsumerStatefulWidget {
  const ProductFormPage({
    super.key,
    this.productId,
    this.initial,
    this.initialBarcode,
  }) : assert(
         (productId == null && initial == null) ||
             (productId != null && initial != null),
       ),
       assert(productId == null || initialBarcode == null);

  final String? productId;
  final Product? initial;
  final String? initialBarcode;

  bool get isEditing => productId != null;

  @override
  ConsumerState<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends ConsumerState<ProductFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _barcodeController;
  late final TextEditingController _skuController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _unitController;
  late final TextEditingController _categoryController;
  late final TextEditingController _minStockController;
  var _isSaving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _barcodeController = TextEditingController(
      text: initial?.barcode ?? widget.initialBarcode ?? '',
    );
    _skuController = TextEditingController(text: initial?.sku ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _unitController = TextEditingController(text: initial?.unit ?? 'pcs');
    _categoryController = TextEditingController(text: initial?.category ?? '');
    _minStockController = TextEditingController(
      text: initial?.minStock?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _barcodeController.dispose();
    _skuController.dispose();
    _descriptionController.dispose();
    _unitController.dispose();
    _categoryController.dispose();
    _minStockController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isEditing ? 'Edit product' : 'Add product';
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            Text(
              widget.isEditing
                  ? 'Update local catalog details'
                  : 'Add to local catalog',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.isEditing
                      ? 'Update the details for this product.'
                      : 'Create a product for your local catalog.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  key: const Key('product-form-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Product information',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Identity and lookup details',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('product-name-field'),
                          controller: _nameController,
                          textInputAction: TextInputAction.next,
                          decoration: _productFieldDecoration(
                            label: 'Name',
                            icon: Icons.inventory_2_outlined,
                          ),
                          validator: _requiredTextValidator('Name'),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('product-barcode-field'),
                          controller: _barcodeController,
                          textInputAction: TextInputAction.next,
                          decoration: _productFieldDecoration(
                            label: 'Barcode',
                            icon: Icons.qr_code_2,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('product-sku-field'),
                          controller: _skuController,
                          textInputAction: TextInputAction.next,
                          decoration: _productFieldDecoration(
                            label: 'SKU',
                            icon: Icons.tag_outlined,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('product-description-field'),
                          controller: _descriptionController,
                          textInputAction: TextInputAction.next,
                          decoration: _productFieldDecoration(
                            label: 'Description',
                            icon: Icons.notes_outlined,
                          ).copyWith(alignLabelWithHint: true),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('product-category-field'),
                          controller: _categoryController,
                          textInputAction: TextInputAction.next,
                          decoration: _productFieldDecoration(
                            label: 'Category',
                            icon: Icons.category_outlined,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  key: const Key('product-form-stock-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Stock settings',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Define how inventory should be monitored',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('product-unit-field'),
                          controller: _unitController,
                          textInputAction: TextInputAction.next,
                          decoration: _productFieldDecoration(
                            label: 'Unit',
                            icon: Icons.straighten_outlined,
                          ),
                          validator: _requiredTextValidator('Unit'),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('product-min-stock-field'),
                          controller: _minStockController,
                          keyboardType: TextInputType.number,
                          decoration: _productFieldDecoration(
                            label: 'Minimum stock',
                            icon: Icons.warning_amber_outlined,
                            helperText:
                                'Show a low-stock warning at or below this quantity.',
                          ),
                          validator: _minStockValidator,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('save-product-button'),
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            color: colors.onPrimary,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.check),
                  label: Text(_isSaving ? 'Saving…' : 'Save product'),
                  style:
                      FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ).copyWith(
                        backgroundColor:
                            WidgetStateProperty.resolveWith<Color?>(
                              (states) =>
                                  _isSaving &&
                                      states.contains(WidgetState.disabled)
                                  ? colors.primary
                                  : null,
                            ),
                        foregroundColor:
                            WidgetStateProperty.resolveWith<Color?>(
                              (states) =>
                                  _isSaving &&
                                      states.contains(WidgetState.disabled)
                                  ? colors.onPrimary
                                  : null,
                            ),
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _productFieldDecoration({
    required String label,
    required IconData icon,
    String? helperText,
  }) {
    return InputDecoration(
      labelText: label,
      helperText: helperText,
      prefixIcon: Icon(icon),
      filled: true,
    );
  }

  String? Function(String?) _requiredTextValidator(String field) {
    return (value) =>
        value == null || value.trim().isEmpty ? '$field is required.' : null;
  }

  String? _minStockValidator(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) {
      return null;
    }
    final minStock = int.tryParse(normalized);
    if (minStock == null || minStock < 0) {
      return 'Minimum stock must be zero or greater.';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final minStockText = _minStockController.text.trim();
    final draft = ProductDraft(
      name: _nameController.text,
      barcode: _barcodeController.text,
      sku: _skuController.text,
      description: _descriptionController.text,
      unit: _unitController.text,
      category: _categoryController.text,
      minStock: minStockText.isEmpty ? null : int.parse(minStockText),
    );

    setState(() => _isSaving = true);
    try {
      final repository = ref.read(localProductRepositoryProvider);
      final result = widget.isEditing
          ? await repository.update(productId: widget.productId!, draft: draft)
          : await repository.create(draft);
      if (mounted) {
        Navigator.of(context).pop(result.productId);
      }
    } on LocalMutationValidationException catch (error) {
      if (!mounted) {
        return;
      }
      _showLocalError(context, error.message);
    } on Exception {
      if (!mounted) {
        return;
      }
      _showLocalError(context, 'Could not save the product locally.');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}

void _showLocalError(BuildContext context, String message) {
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
