import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/local/local_query_providers.dart';
import '../../data/local/stoksync_database.dart';
import '../products/product_pages.dart';
import 'movement_pages.dart';

/// Local-first cross-product movement history.
///
/// The list is backed by one joined Drift stream so movement rows remain
/// understandable even when their product has been soft-deleted. Product
/// detail and reversal actions are pushed routes; Movements stays a shell
/// destination rather than becoming another navigation level.
class MovementDestinationPage extends ConsumerWidget {
  const MovementDestinationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movements = ref.watch(allMovementHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Movements'),
            Text(
              'Recent ledger activity',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: movements.when(
        loading: () => const _MovementLoadingState(),
        error: (_, _) => const _MovementErrorState(),
        data: (items) => _MovementList(items: items),
      ),
    );
  }
}

class _MovementList extends StatelessWidget {
  const _MovementList({required this.items});

  final List<MovementWithProduct> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _MovementEmptyState();
    }

    return ListView.separated(
      key: const Key('all-movements-list'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = items[index];
        return _MovementCard(
          key: Key('all-movement-row-${item.movement.id}'),
          item: item,
        );
      },
    );
  }
}

class _MovementCard extends StatelessWidget {
  const _MovementCard({super.key, required this.item});

  final MovementWithProduct item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final movement = item.movement;
    final product = item.product;
    final productName = product.name.trim().isEmpty
        ? 'Product ${product.id}'
        : product.name;
    final canReverse = product.deletedAt == null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openProduct(context, product.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MovementKindIcon(kind: movement.kind),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      productName,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _movementKindLabel(movement.kind),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Delta: ${_signedMovementDelta(movement.delta)} ${product.unit}',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: movement.delta >= 0
                            ? semanticColorsOf(context).success
                            : colors.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (movement.countedQty != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Counted: ${movement.countedQty} ${product.unit}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    if (movement.note != null &&
                        movement.note!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Note: ${movement.note}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      'Product ID: ${product.id}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatOccurredAt(context, movement.occurredAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (product.deletedAt != null) ...[
                      const SizedBox(height: 8),
                      const Chip(
                        label: Text('Deleted product'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
              ),
              if (canReverse)
                IconButton(
                  key: Key('reverse-all-movement-button-${movement.id}'),
                  tooltip: 'Reverse movement',
                  icon: const Icon(Icons.undo),
                  onPressed: () => _openReversal(context, movement),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openProduct(BuildContext context, String productId) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ProductDetailPage(productId: productId),
      ),
    );
  }

  Future<void> _openReversal(BuildContext context, StockMovement movement) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MovementReversalPage(movement: movement),
      ),
    );
  }
}

class _MovementKindIcon extends StatelessWidget {
  const _MovementKindIcon({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (kind) {
      'receive' => (colors.primaryContainer, colors.onPrimaryContainer),
      'issue' => (colors.errorContainer, colors.onErrorContainer),
      'adjust' => (colors.tertiaryContainer, colors.onTertiaryContainer),
      'stocktake' => (colors.secondaryContainer, colors.onSecondaryContainer),
      _ => (colors.surfaceContainerHighest, colors.onSurfaceVariant),
    };
    return DecoratedBox(
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Icon(
          _movementKindIcon(kind),
          color: foreground,
          semanticLabel: _movementKindLabel(kind),
        ),
      ),
    );
  }
}

class _MovementEmptyState extends StatelessWidget {
  const _MovementEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListView(
      key: const Key('movements-empty-state'),
      padding: const EdgeInsets.fromLTRB(32, 64, 32, 32),
      children: [
        Icon(Icons.swap_vert_circle_outlined, size: 72, color: colors.primary),
        const SizedBox(height: 20),
        Text(
          'No movements yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Stock changes from every product will appear here, newest first.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Open a product to receive, issue, adjust, or count stock.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _MovementLoadingState extends StatelessWidget {
  const _MovementLoadingState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        key: const Key('movements-loading-state'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Loading movement history…',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _MovementErrorState extends StatelessWidget {
  const _MovementErrorState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          key: const Key('movements-error-state'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.error),
            const SizedBox(height: 12),
            Text(
              'Movement history is unavailable locally.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Your local ledger was not changed.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
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

String _formatOccurredAt(BuildContext context, DateTime occurredAt) {
  final localTime = occurredAt.toLocal();
  final localizations = MaterialLocalizations.of(context);
  final date = localizations.formatMediumDate(localTime);
  final time = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(localTime));
  return '$date · $time';
}
