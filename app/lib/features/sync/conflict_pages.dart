import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/conflict_resolution_repository.dart';
import '../../data/local/local_query_providers.dart';
import '../../data/local/stoksync_database.dart';
import 'conflict_providers.dart';

/// Local-first list of retained conflict history.
class ConflictListPage extends ConsumerWidget {
  const ConflictListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(conflictsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Conflicts')),
      body: conflicts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Local conflict history is unavailable.')),
        data: (values) {
          final unresolvedCount = values
              .where((conflict) => conflict.resolutionStatus == 'unresolved')
              .length;
          if (values.isEmpty) {
            return const Center(
              child: Text('No conflicts recorded on this device.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                '$unresolvedCount unresolved conflict${unresolvedCount == 1 ? '' : 's'}',
                key: const Key('unresolved-conflict-heading'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              ...values.map(
                (conflict) => _ConflictListTile(
                  conflict: conflict,
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          ConflictDetailPage(operationId: conflict.opId),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ConflictListTile extends StatelessWidget {
  const _ConflictListTile({required this.conflict, required this.onTap});

  final Conflict conflict;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unresolved = conflict.resolutionStatus == 'unresolved';
    return Card(
      key: Key('conflict-row-${conflict.opId}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        title: Text(conflictReasonLabel(conflict.reason)),
        subtitle: Text(
          '${conflict.entity} · ${_statusLabel(conflict.resolutionStatus)}',
        ),
        trailing: unresolved
            ? const Icon(Icons.warning_amber_outlined)
            : const Icon(Icons.check_circle_outline),
      ),
    );
  }
}

/// Local-first detail view for one retained conflict and its resolution.
class ConflictDetailPage extends ConsumerWidget {
  const ConflictDetailPage({super.key, required this.operationId});

  final String operationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflict = ref.watch(conflictDetailProvider(operationId));
    return Scaffold(
      appBar: AppBar(title: const Text('Conflict details')),
      body: conflict.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(
          child: Text('Local conflict details are unavailable.'),
        ),
        data: (value) {
          if (value == null) {
            return const Center(child: Text('Conflict was not found locally.'));
          }
          return _ConflictDetailContent(conflict: value);
        },
      ),
    );
  }
}

class _ConflictDetailContent extends ConsumerWidget {
  const _ConflictDetailContent({required this.conflict});

  final Conflict conflict;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unresolved = conflict.resolutionStatus == 'unresolved';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                conflictReasonLabel(conflict.reason),
                key: const Key('conflict-reason'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            Chip(
              key: const Key('conflict-resolution-status'),
              label: Text(_statusLabel(conflict.resolutionStatus)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Reason code: ${conflict.reason}',
          key: const Key('conflict-reason-code'),
        ),
        Text('Entity: ${conflict.entity} ${conflict.entityId}'),
        Text('Recorded: ${_formatUtc(conflict.createdAt)}'),
        const SizedBox(height: 20),
        _PayloadSection(
          key: const Key('base-payload'),
          title: 'Base snapshot',
          payload: conflict.basePayload,
          emptyText: 'No base snapshot was retained for this operation.',
        ),
        _PayloadSection(
          key: const Key('local-payload'),
          title: 'Local intent',
          payload: conflict.localPayload,
        ),
        _PayloadSection(
          key: const Key('server-payload'),
          title: 'Canonical server state',
          payload: conflict.serverPayload,
          emptyText: 'The server did not return canonical payload details.',
        ),
        if (unresolved) ...[
          const SizedBox(height: 8),
          _ResolutionActions(conflict: conflict),
        ] else
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'This conflict is resolved. The original local intent and the resolution remain in local history.',
              ),
            ),
          ),
      ],
    );
  }
}

class _ResolutionActions extends ConsumerStatefulWidget {
  const _ResolutionActions({required this.conflict});

  final Conflict conflict;

  @override
  ConsumerState<_ResolutionActions> createState() => _ResolutionActionsState();
}

class _ResolutionActionsState extends ConsumerState<_ResolutionActions> {
  var _isResolving = false;

  @override
  Widget build(BuildContext context) {
    final conflict = widget.conflict;
    final reason = conflict.reason;
    final buttons = <Widget>[];
    if (reason == 'version_conflict') {
      buttons.add(
        FilledButton.icon(
          key: const Key('resolve-use-local-button'),
          onPressed: _isResolving
              ? null
              : () => _resolve(ProductConflictResolution.useLocal),
          icon: const Icon(Icons.upload_outlined),
          label: const Text('Use my changes'),
        ),
      );
      buttons.add(
        OutlinedButton.icon(
          key: const Key('resolve-use-server-button'),
          onPressed: _isResolving
              ? null
              : () => _resolve(ProductConflictResolution.useServer),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Use server version'),
        ),
      );
    } else if (reason == 'barcode_conflict') {
      buttons.add(
        FilledButton.icon(
          key: const Key('resolve-remove-barcode-button'),
          onPressed: _isResolving
              ? null
              : () => _resolve(
                  ProductConflictResolution.removeConflictingBarcode,
                ),
          icon: const Icon(Icons.qr_code_2_outlined),
          label: const Text('Retry without barcode'),
        ),
      );
      buttons.add(
        const Text(
          'The canonical barcode owner is shown above. Choose a different barcode locally before retrying if this product needs one.',
        ),
      );
    } else if (reason == 'product_deleted') {
      buttons.add(
        OutlinedButton.icon(
          key: const Key('resolve-acknowledge-deletion-button'),
          onPressed: _isResolving ? null : _markReviewed,
          icon: const Icon(Icons.check),
          label: const Text('Mark deletion reviewed'),
        ),
      );
      buttons.add(
        const Text(
          'The remote tombstone wins. The rejected edit remains visible, and no local action can resurrect the product.',
        ),
      );
    } else {
      buttons.add(
        OutlinedButton.icon(
          key: const Key('resolve-mark-reviewed-button'),
          onPressed: _isResolving ? null : _markReviewed,
          icon: const Icon(Icons.check),
          label: const Text('Mark reviewed'),
        ),
      );
    }

    return Card(
      key: const Key('conflict-resolution-actions'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Choose a follow-up action',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...buttons.map(
              (button) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: button,
              ),
            ),
            if (_isResolving)
              const Align(
                alignment: Alignment.centerLeft,
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _resolve(ProductConflictResolution resolution) async {
    setState(() => _isResolving = true);
    try {
      final result = await ref
          .read(localConflictResolutionRepositoryProvider)
          .resolveProduct(conflict: widget.conflict, resolution: resolution);
      if (!mounted) {
        return;
      }
      _showMessage(
        'Resolved locally. Follow-up operation ${result.operationId} is queued.',
      );
    } on ConflictResolutionException catch (error) {
      if (mounted) {
        _showMessage(error.message);
      }
    } on Exception {
      if (mounted) {
        _showMessage('Could not create the local follow-up operation.');
      }
    } finally {
      if (mounted) {
        setState(() => _isResolving = false);
      }
    }
  }

  Future<void> _markReviewed() async {
    setState(() => _isResolving = true);
    try {
      await ref
          .read(localConflictResolutionRepositoryProvider)
          .markReviewed(widget.conflict);
      if (mounted) {
        _showMessage('Conflict marked reviewed locally.');
      }
    } on ConflictResolutionException catch (error) {
      if (mounted) {
        _showMessage(error.message);
      }
    } on Exception {
      if (mounted) {
        _showMessage('Could not update the local conflict history.');
      }
    } finally {
      if (mounted) {
        setState(() => _isResolving = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PayloadSection extends StatelessWidget {
  const _PayloadSection({
    super.key,
    required this.title,
    required this.payload,
    this.emptyText = 'No payload was retained.',
  });

  final String title;
  final String? payload;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final formatted = _formatPayload(payload);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(
              formatted ?? emptyText,
              key: Key(
                '${key is ValueKey<String> ? (key as ValueKey<String>).value : title}-content',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

String conflictReasonLabel(String reason) {
  return switch (reason) {
    'version_conflict' => 'Product edit conflict',
    'barcode_conflict' => 'Barcode conflict',
    'product_deleted' => 'Product deleted remotely',
    'product_not_found' => 'Product no longer exists',
    'invalid_operation' => 'Invalid operation',
    _ => reason.replaceAll('_', ' '),
  };
}

String _statusLabel(String status) {
  return switch (status) {
    'unresolved' => 'Unresolved',
    'auto_merged' => 'Auto-merged',
    'resolved' => 'Resolved',
    _ => status,
  };
}

String? _formatPayload(String? payload) {
  if (payload == null || payload.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(payload);
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } on FormatException {
    return payload;
  }
}

String _formatUtc(DateTime timestamp) {
  final value = timestamp.toUtc();
  String twoDigits(int number) => number.toString().padLeft(2, '0');

  return '${value.year.toString().padLeft(4, '0')}-'
      '${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)} UTC';
}
