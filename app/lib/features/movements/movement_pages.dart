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
        loading: () => const _MovementStateMessage(
          key: Key('movement-entry-loading-state'),
          icon: Icons.hourglass_top,
          message: 'Loading product details…',
          loading: true,
        ),
        error: (_, _) => const _MovementStateMessage(
          key: Key('movement-entry-error-state'),
          icon: Icons.error_outline,
          message: 'Local product details are unavailable.',
        ),
        data: (productInventory) {
          if (productInventory == null) {
            return const _MovementStateMessage(
              icon: Icons.search_off,
              message: 'Product was not found locally.',
            );
          }
          if (productInventory.product.deletedAt != null) {
            return const _MovementStateMessage(
              icon: Icons.delete_outline,
              message: 'Deleted products cannot receive stock changes.',
            );
          }
          return _buildForm(context, productInventory);
        },
      ),
    );
  }

  Widget _buildForm(BuildContext context, ProductInventory inventory) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
      child: Column(
        children: [
          Expanded(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              children: [
                Text(widget.mode.title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(
                  _movementGuidance(widget.mode),
                  key: const Key('movement-entry-guidance'),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  key: const Key('movement-current-balance'),
                  color: colors.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          color: colors.onPrimaryContainer,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Current balance',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${inventory.quantity} ${inventory.product.unit}',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          _movementModeIcon(widget.mode),
                          color: colors.onPrimaryContainer,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  key: const Key('movement-entry-form-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Movement details',
                          style: theme.textTheme.titleMedium,
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
                          decoration: _movementFieldDecoration(
                            context,
                            label: valueLabel,
                            hint: valueHint,
                          ),
                          validator: (value) =>
                              _validateValue(value, inventory.quantity),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('movement-note-field'),
                          controller: _noteController,
                          textInputAction: TextInputAction.done,
                          maxLines: 3,
                          maxLength: 500,
                          decoration: _movementFieldDecoration(
                            context,
                            label: 'Note (optional)',
                            hint: 'Explain this stock change',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('save-movement-button'),
                style:
                    FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                    ).copyWith(
                      backgroundColor: WidgetStateProperty.resolveWith<Color?>(
                        (states) =>
                            _isSaving && states.contains(WidgetState.disabled)
                            ? colors.primary
                            : null,
                      ),
                      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
                        (states) =>
                            _isSaving && states.contains(WidgetState.disabled)
                            ? colors.onPrimary
                            : null,
                      ),
                    ),
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
                label: Text(_isSaving ? 'Saving…' : widget.mode.actionLabel),
              ),
            ),
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Reverse movement')),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                children: [
                  Text('Review reversal', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    'Append a correction without changing the original ledger entry.',
                    key: const Key('movement-reversal-guidance'),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Card(
                    key: const Key('movement-reversal-summary-card'),
                    color: colors.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.history,
                            color: colors.onSecondaryContainer,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Original movement',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: colors.onSecondaryContainer,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _movementTitle(movement.kind),
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: colors.onSecondaryContainer,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Original delta: ${_signedQuantity(movement.delta)}',
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: colors.onSecondaryContainer,
                                  ),
                                ),
                                if (movement.note != null &&
                                    movement.note!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Note: ${movement.note}',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSecondaryContainer,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    key: const Key('movement-reversal-form-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextFormField(
                        key: const Key('movement-reversal-note-field'),
                        controller: _noteController,
                        textInputAction: TextInputAction.done,
                        maxLines: 3,
                        maxLength: 500,
                        decoration: _movementFieldDecoration(
                          context,
                          label: 'Reversal note (optional)',
                          hint: 'Explain why this movement is being reversed',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('save-reversal-button'),
                  style:
                      FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
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
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            color: colors.onPrimary,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.undo),
                  label: Text(_isSaving ? 'Saving…' : 'Reverse movement'),
                ),
              ),
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

class _MovementStateMessage extends StatelessWidget {
  const _MovementStateMessage({
    super.key,
    required this.icon,
    required this.message,
    this.loading = false,
  });

  final IconData icon;
  final String message;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const CircularProgressIndicator()
            else
              Icon(icon, size: 48, color: colors.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

String _movementGuidance(MovementEntryMode mode) {
  return switch (mode) {
    MovementEntryMode.receive =>
      'Add incoming stock to the current balance. Use a note for the source or delivery reference.',
    MovementEntryMode.issue =>
      'Record stock leaving inventory. Enter the quantity to subtract from the current balance.',
    MovementEntryMode.adjustment =>
      'Apply a signed correction when the ledger needs an explicit increase or decrease.',
    MovementEntryMode.stocktake =>
      'Enter the physical count. StokSync records only the delta needed to reach it.',
  };
}

IconData _movementModeIcon(MovementEntryMode mode) {
  return switch (mode) {
    MovementEntryMode.receive => Icons.add_box_outlined,
    MovementEntryMode.issue => Icons.outbox_outlined,
    MovementEntryMode.adjustment => Icons.tune,
    MovementEntryMode.stocktake => Icons.fact_check_outlined,
  };
}

InputDecoration _movementFieldDecoration(
  BuildContext context, {
  required String label,
  required String hint,
}) {
  final colors = Theme.of(context).colorScheme;
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: colors.outlineVariant),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    filled: true,
    fillColor: colors.surfaceContainerHighest,
    border: border,
    enabledBorder: border,
    focusedBorder: border.copyWith(
      borderSide: BorderSide(color: colors.primary, width: 2),
    ),
    errorBorder: border.copyWith(borderSide: BorderSide(color: colors.error)),
    focusedErrorBorder: border.copyWith(
      borderSide: BorderSide(color: colors.error, width: 2),
    ),
  );
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
