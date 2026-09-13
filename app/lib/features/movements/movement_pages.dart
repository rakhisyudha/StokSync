import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/local_mutation_repositories.dart';
import '../../data/local/local_query_providers.dart';
import '../../data/local/stoksync_database.dart';
import 'movement_providers.dart';

/// The local entry forms supported by the product movement workflow.
enum MovementEntryMode { receive, issue, adjustment, stocktake }

extension MovementEntryModeLabels on MovementEntryMode {
  String get title {
    return switch (this) {
      MovementEntryMode.receive => 'Receive stock',
      MovementEntryMode.issue => 'Issue stock',
      MovementEntryMode.adjustment => 'Adjust stock',
      MovementEntryMode.stocktake => 'Record stocktake',
    };
  }

  String get actionLabel {
    return switch (this) {
      MovementEntryMode.receive => 'Receive',
      MovementEntryMode.issue => 'Issue',
      MovementEntryMode.adjustment => 'Adjust',
      MovementEntryMode.stocktake => 'Record stocktake',
    };
  }
}

/// Local-first form for appending one receive, issue, adjustment, or stocktake.
class MovementEntryPage extends ConsumerStatefulWidget {
  const MovementEntryPage({
    super.key,
    required this.productId,
    required this.mode,
  });

  final String productId;
  final MovementEntryMode mode;

  @override
  ConsumerState<MovementEntryPage> createState() => _MovementEntryPageState();
}

class _MovementEntryPageState extends ConsumerState<MovementEntryPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _valueController;
  late final TextEditingController _noteController;
  var _isSaving = false;

  @override
  void initState() {
    super.initState();
    _valueController = TextEditingController();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _valueController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(productDetailProvider(widget.productId));
    return Scaffold(
      appBar: AppBar(title: Text(widget.mode.title)),
      body: inventory.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Local product details are unavailable.')),
        data: (productInventory) {
          if (productInventory == null) {
            return const Center(child: Text('Product was not found locally.'));
          }
          if (productInventory.product.deletedAt != null) {
            return const Center(
              child: Text('Deleted products cannot receive stock changes.'),
            );
          }
          return _buildForm(context, productInventory);
        },
      ),
    );
  }

  Widget _buildForm(BuildContext context, ProductInventory inventory) {
    final valueLabel = switch (widget.mode) {
      MovementEntryMode.receive || MovementEntryMode.issue => 'Quantity',
      MovementEntryMode.adjustment => 'Adjustment delta',
      MovementEntryMode.stocktake => 'Counted quantity',
    };
    final valueHint = switch (widget.mode) {
      MovementEntryMode.receive ||
      MovementEntryMode.issue => 'Enter a whole number',
      MovementEntryMode.adjustment => 'Use a positive or negative whole number',
      MovementEntryMode.stocktake => 'Enter the physical count',
    };
    final valueKey = switch (widget.mode) {
      MovementEntryMode.receive ||
      MovementEntryMode.issue => const Key('movement-quantity-field'),
      MovementEntryMode.adjustment => const Key('movement-delta-field'),
      MovementEntryMode.stocktake => const Key(
        'movement-counted-quantity-field',
      ),
    };

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              key: const Key('movement-current-balance'),
              title: const Text('Current balance'),
              subtitle: Text('${inventory.quantity} ${inventory.product.unit}'),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: valueKey,
            controller: _valueController,
            keyboardType: const TextInputType.numberWithOptions(
              signed: true,
              decimal: false,
            ),
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: valueLabel,
              hintText: valueHint,
              border: const OutlineInputBorder(),
            ),
            validator: (value) => _validateValue(value, inventory.quantity),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('movement-note-field'),
            controller: _noteController,
            textInputAction: TextInputAction.done,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'Explain this stock change',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('save-movement-button'),
            onPressed: _isSaving ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(_isSaving ? 'Saving…' : widget.mode.actionLabel),
          ),
        ],
      ),
    );
  }

  String? _validateValue(String? value, int currentBalance) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) {
      return switch (widget.mode) {
        MovementEntryMode.stocktake => 'Counted quantity is required.',
        MovementEntryMode.adjustment => 'Adjustment delta is required.',
        _ => 'Quantity is required.',
      };
    }
    final parsed = int.tryParse(normalized);
    if (parsed == null) {
      return 'Enter a whole number.';
    }
    return switch (widget.mode) {
      MovementEntryMode.receive || MovementEntryMode.issue =>
        parsed <= 0 ? 'Quantity must be greater than zero.' : null,
      MovementEntryMode.adjustment =>
        parsed == 0 ? 'Adjustment delta must not be zero.' : null,
      MovementEntryMode.stocktake =>
        parsed < 0
            ? 'Counted quantity must be zero or greater.'
            : parsed == currentBalance
            ? 'Counted quantity must differ from the current balance.'
            : null,
    };
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final value = int.parse(_valueController.text.trim());
    final note = _noteController.text;
    setState(() => _isSaving = true);
    try {
      final repository = ref.read(localStockMovementRepositoryProvider);
      final result = switch (widget.mode) {
        MovementEntryMode.receive => await repository.receive(
          productId: widget.productId,
          quantity: value,
          note: note,
        ),
        MovementEntryMode.issue => await repository.issue(
          productId: widget.productId,
          quantity: value,
          note: note,
        ),
        MovementEntryMode.adjustment => await repository.adjust(
          productId: widget.productId,
          delta: value,
          note: note,
        ),
        MovementEntryMode.stocktake => await repository.stocktake(
          productId: widget.productId,
          countedQuantity: value,
          note: note,
        ),
      };
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } on LocalMutationValidationException catch (error) {
      if (mounted) {
        _showMovementError(context, error.message);
      }
    } on LocalProductNotFoundException {
      if (mounted) {
        _showMovementError(
          context,
          'The product is no longer available locally.',
        );
      }
    } on LocalProductDeletedException {
      if (mounted) {
        _showMovementError(
          context,
          'Deleted products cannot receive stock changes.',
        );
      }
    } on Exception {
      if (mounted) {
        _showMovementError(
          context,
          'Could not save the stock movement locally.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}

/// Local-first form for appending an adjustment that reverses an existing row.
class MovementReversalPage extends ConsumerStatefulWidget {
  const MovementReversalPage({super.key, required this.movement});

  final StockMovement movement;

  @override
  ConsumerState<MovementReversalPage> createState() =>
      _MovementReversalPageState();
}

class _MovementReversalPageState extends ConsumerState<MovementReversalPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _noteController;
  var _isSaving = false;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final movement = widget.movement;
    return Scaffold(
      appBar: AppBar(title: const Text('Reverse movement')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                title: Text(_movementTitle(movement.kind)),
                subtitle: Text(
                  'Original delta: ${_signedQuantity(movement.delta)}',
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'A new adjustment will be appended with the opposite delta. The original movement will remain unchanged.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('movement-reversal-note-field'),
              controller: _noteController,
              textInputAction: TextInputAction.done,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Reversal note (optional)',
                hintText: 'Explain why this movement is being reversed',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('save-reversal-button'),
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.undo),
              label: Text(_isSaving ? 'Saving…' : 'Reverse movement'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result = await ref
          .read(localStockMovementRepositoryProvider)
          .reverse(
            originalMovementId: widget.movement.id,
            note: _noteController.text,
          );
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } on LocalMovementNotFoundException {
      if (mounted) {
        _showMovementError(
          context,
          'The original movement is no longer local.',
        );
      }
    } on LocalProductDeletedException {
      if (mounted) {
        _showMovementError(
          context,
          'The product is deleted locally and cannot receive a reversal.',
        );
      }
    } on LocalMutationValidationException catch (error) {
      if (mounted) {
        _showMovementError(context, error.message);
      }
    } on Exception {
      if (mounted) {
        _showMovementError(context, 'Could not save the reversal locally.');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }
}

String _movementTitle(String kind) {
  return switch (kind) {
    'receive' => 'Received stock',
    'issue' => 'Issued stock',
    'adjust' => 'Stock adjustment',
    'stocktake' => 'Stocktake',
    _ => 'Stock movement',
  };
}

String _signedQuantity(int value) => value > 0 ? '+$value' : '$value';

void _showMovementError(BuildContext context, String message) {
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
