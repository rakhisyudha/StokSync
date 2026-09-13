import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/local_mutation_repositories.dart';
import '../../data/local/local_query_providers.dart';
import '../../data/local/stoksync_database.dart';
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
      appBar: AppBar(title: const Text('Products')),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            key: const Key('scan-product-button'),
            heroTag: 'scan-product-fab',
            onPressed: _scanProduct,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan barcode'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            key: const Key('add-product-button'),
            heroTag: 'add-product-fab',
            onPressed: _createProduct,
            icon: const Icon(Icons.add),
            label: const Text('Add product'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const Key('product-search-field'),
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Search products',
                hintText: 'Name, barcode, or SKU',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: products.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) =>
                  const Center(child: Text('Local catalog is unavailable.')),
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
      final hasSearchQuery = _searchController.text.trim().isNotEmpty;
      return Center(
        child: Text(
          hasSearchQuery
              ? 'No products match “${_searchController.text.trim()}”.'
              : 'No products yet. Add one to start your local catalog.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.separated(
      itemCount: filteredProducts.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final inventory = filteredProducts[index];
        final product = inventory.product;
        final identifiers = [
          if (product.sku != null) 'SKU ${product.sku}',
          if (product.barcode != null) product.barcode!,
        ];
        return ListTile(
          key: Key('product-row-${product.id}'),
          title: Text(product.name),
          subtitle: Text(
            [
              '${inventory.quantity} ${product.unit}',
              ...identifiers,
            ].join(' · '),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openProduct(product.id),
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

/// Local product details, including the local derived balance and metadata.
class ProductDetailPage extends ConsumerWidget {
  const ProductDetailPage({super.key, required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(productDetailProvider(productId));
    return detail.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => const Scaffold(
        body: Center(child: Text('Local product details are unavailable.')),
      ),
      data: (inventory) {
        if (inventory == null) {
          return const Scaffold(
            body: Center(child: Text('Product was not found locally.')),
          );
        }
        final product = inventory.product;
        final isDeleted = product.deletedAt != null;
        return Scaffold(
          appBar: AppBar(
            title: Text(product.name),
            actions: [
              if (!isDeleted)
                IconButton(
                  key: const Key('edit-product-button'),
                  tooltip: 'Edit product',
                  icon: const Icon(Icons.edit),
                  onPressed: () => _editProduct(context, product),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Quantity: ${inventory.quantity} ${product.unit}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              if (isDeleted)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('This product is deleted locally.'),
                  ),
                ),
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
              if (!isDeleted) ...[
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  key: const Key('delete-product-button'),
                  onPressed: () => _confirmDelete(context, ref),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete product'),
                ),
              ],
            ],
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
          Text(value!),
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
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const Key('product-name-field'),
              controller: _nameController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: _requiredTextValidator('Name'),
            ),
            TextFormField(
              key: const Key('product-barcode-field'),
              controller: _barcodeController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Barcode'),
            ),
            TextFormField(
              key: const Key('product-sku-field'),
              controller: _skuController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'SKU'),
            ),
            TextFormField(
              key: const Key('product-description-field'),
              controller: _descriptionController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 3,
            ),
            TextFormField(
              key: const Key('product-unit-field'),
              controller: _unitController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Unit'),
              validator: _requiredTextValidator('Unit'),
            ),
            TextFormField(
              key: const Key('product-category-field'),
              controller: _categoryController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Category'),
            ),
            TextFormField(
              key: const Key('product-min-stock-field'),
              controller: _minStockController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Minimum stock'),
              validator: _minStockValidator,
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('save-product-button'),
              onPressed: _isSaving ? null : _save,
              child: Text(_isSaving ? 'Saving…' : 'Save product'),
            ),
          ],
        ),
      ),
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
