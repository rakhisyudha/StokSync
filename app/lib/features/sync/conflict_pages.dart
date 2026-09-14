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
        loading: () => const _ConflictStateMessage(
          key: Key('conflicts-loading-state'),
          icon: Icons.warning_amber_outlined,
          message: 'Loading conflict history…',
          loading: true,
        ),
        error: (_, _) => const _ConflictStateMessage(
          key: Key('conflicts-error-state'),
          icon: Icons.error_outline,
          message: 'Local conflict history is unavailable.',
          isError: true,
        ),
        data: (values) {
          final unresolvedCount = values
              .where((conflict) => conflict.resolutionStatus == 'unresolved')
              .length;
          if (values.isEmpty) {
            return const _ConflictStateMessage(
              key: Key('conflicts-empty-state'),
              icon: Icons.check_circle_outline,
              message: 'No conflicts recorded on this device.',
              detail:
                  'Conflicts will appear here when local work needs review.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: values.length + 1,
            separatorBuilder: (_, index) =>
                SizedBox(height: index == 0 ? 12 : 8),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _ConflictListHeader(unresolvedCount: unresolvedCount);
              }
              final conflict = values[index - 1];
              return _ConflictListTile(
                conflict: conflict,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ConflictDetailPage(operationId: conflict.opId),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

final class _ConflictStateMessage extends StatelessWidget {
  const _ConflictStateMessage({
    super.key,
    required this.icon,
    required this.message,
    this.detail,
    this.loading = false,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final bool loading;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final iconColor = isError ? colorScheme.error : colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              CircularProgressIndicator(color: colorScheme.primary)
            else
              Icon(icon, size: 48, color: iconColor),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConflictListHeader extends StatelessWidget {
  const _ConflictListHeader({required this.unresolvedCount});

  final int unresolvedCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final conflictWord = unresolvedCount == 1 ? 'conflict' : 'conflicts';
    return Card(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              unresolvedCount == 0
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              color: unresolvedCount == 0
                  ? colorScheme.primary
                  : colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$unresolvedCount unresolved $conflictWord',
                    key: const Key('unresolved-conflict-heading'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Review local intent and canonical server state before choosing a follow-up action.',
                    style: Theme.of(context).textTheme.bodyMedium,
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

class _ConflictListTile extends StatelessWidget {
  const _ConflictListTile({required this.conflict, required this.onTap});

  final Conflict conflict;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unresolved = conflict.resolutionStatus == 'unresolved';
    final colorScheme = Theme.of(context).colorScheme;
    final iconColor = unresolved
        ? colorScheme.onErrorContainer
        : colorScheme.onSecondaryContainer;
    final iconBackground = unresolved
        ? colorScheme.errorContainer
        : colorScheme.secondaryContainer;

    return Card(
      key: Key('conflict-row-${conflict.opId}'),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: iconBackground,
          foregroundColor: iconColor,
          child: Icon(
            unresolved
                ? Icons.warning_amber_outlined
                : Icons.check_circle_outline,
          ),
        ),
        title: Text(
          conflictReasonLabel(conflict.reason),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${conflict.entity} · ${_statusLabel(conflict.resolutionStatus)}',
              ),
              const SizedBox(height: 2),
              Text(
                _formatUtc(conflict.createdAt),
                key: Key('conflict-timestamp-${conflict.opId}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
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
        loading: () => const _ConflictStateMessage(
          key: Key('conflict-detail-loading-state'),
          icon: Icons.description_outlined,
          message: 'Loading conflict details…',
          loading: true,
        ),
        error: (_, _) => const _ConflictStateMessage(
          key: Key('conflict-detail-error-state'),
          icon: Icons.error_outline,
          message: 'Local conflict details are unavailable.',
          isError: true,
        ),
        data: (value) {
          if (value == null) {
            return const _ConflictStateMessage(
              key: Key('conflict-detail-not-found-state'),
              icon: Icons.search_off,
              message: 'Conflict was not found locally.',
              isError: true,
            );
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    conflictReasonLabel(conflict.reason),
                    key: const Key('conflict-reason'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  key: const Key('conflict-resolution-status'),
                  label: Text(_statusLabel(conflict.resolutionStatus)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MetadataRow(
                  label: 'Reason code',
                  value: conflict.reason,
                  valueKey: const Key('conflict-reason-code'),
                ),
                _MetadataRow(
                  label: 'Entity',
                  value: '${conflict.entity} ${conflict.entityId}',
                ),
                _MetadataRow(
                  label: 'Recorded',
                  value: _formatUtc(conflict.createdAt),
                ),
              ],
            ),
          ),
        ),
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

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(value, key: valueKey)),
        ],
      ),
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
    final sectionId = key is ValueKey<String>
        ? (key as ValueKey<String>).value
        : title.toLowerCase().replaceAll(' ', '-');
    final hasPayload = payload != null && payload!.trim().isNotEmpty;
    final decoded = _decodePayload(payload);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Divider(color: Theme.of(context).colorScheme.outlineVariant),
            const SizedBox(height: 4),
            if (!hasPayload)
              Text(emptyText, key: Key('$sectionId-content'))
            else
              _PayloadFields(
                key: Key('$sectionId-content'),
                sectionId: sectionId,
                decoded: decoded,
              ),
          ],
        ),
      ),
    );
  }
}

class _PayloadFields extends StatelessWidget {
  const _PayloadFields({
    super.key,
    required this.sectionId,
    required this.decoded,
  });

  final String sectionId;
  final Object? decoded;

  @override
  Widget build(BuildContext context) {
    final fields = _payloadFields(decoded);
    if (fields == null) {
      return _PayloadField(
        fieldKey: Key('$sectionId-field-payload'),
        label: 'Payload',
        value: _formatPayloadValue(decoded),
      );
    }
    if (fields.isEmpty) {
      return _PayloadField(
        fieldKey: Key('$sectionId-field-payload'),
        label: 'Payload',
        value: 'Object is empty.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in fields.entries)
          _PayloadField(
            fieldKey: Key('$sectionId-field-${entry.key}'),
            label: _payloadLabel(entry.key),
            value: _formatPayloadValue(entry.value),
          ),
      ],
    );
  }
}

class _PayloadField extends StatelessWidget {
  const _PayloadField({
    required this.fieldKey,
    required this.label,
    required this.value,
  });

  final Key fieldKey;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 136,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: fieldKey,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

const _payloadFieldLabels = <String, String>{
  'id': 'ID',
  'product_id': 'Product ID',
  'name': 'Name',
  'barcode': 'Barcode',
  'sku': 'SKU',
  'description': 'Description',
  'category': 'Category',
  'unit': 'Unit',
  'min_stock': 'Minimum stock',
  'version': 'Version',
  'deleted_at': 'Deleted at',
  'delta': 'Quantity change',
  'kind': 'Movement type',
  'note': 'Note',
  'occurred_at': 'Occurred at',
  'raw_occurred_at': 'Original occurred at',
  'clock_offset_ms': 'Clock offset (ms)',
  'counted_qty': 'Counted quantity',
  'reverses_id': 'Reverses movement ID',
  'device_id': 'Originating device ID',
  'server_created_at': 'Server received at',
  'created_at': 'Created at',
  'updated_at': 'Last updated at',
  'updated_by': 'Last updated by',
  'sync_status': 'Sync status',
  'base_version': 'Base version',
  'op_id': 'Operation ID',
  'operation_id': 'Operation ID',
  'op': 'Operation',
  'operation': 'Operation',
  'entity': 'Entity',
  'entity_id': 'Entity ID',
  'reason': 'Conflict reason',
  'status': 'Status',
  'resolution_status': 'Resolution status',
  'local_seq': 'Local sequence',
  'attempts': 'Retry attempts',
  'next_attempt_at': 'Next attempt at',
  'last_error': 'Last error',
  'server_state': 'Canonical server state',
  'stocktake_outcome': 'Stocktake outcome',
  'user_id': 'User ID',
  'schema_version': 'Schema version',
  'server_time': 'Server time',
  'seq': 'Sequence',
  'cursor': 'Cursor',
  'has_more': 'More changes',
};

String _payloadLabel(String key) => _payloadFieldLabels[key] ?? key;

Object? _decodePayload(String? payload) {
  if (payload == null || payload.trim().isEmpty) {
    return null;
  }
  try {
    return jsonDecode(payload);
  } on FormatException {
    return payload;
  }
}

Map<String, Object?>? _payloadFields(Object? decoded) {
  if (decoded is! Map) {
    return null;
  }
  return <String, Object?>{
    for (final entry in decoded.entries) entry.key.toString(): entry.value,
  };
}

String _formatPayloadValue(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is String) {
    return value;
  }
  if (value is num || value is bool) {
    return value.toString();
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on JsonUnsupportedObjectError {
    return value.toString();
  }
}

String conflictReasonLabel(String reason) {
  return switch (reason) {
    'version_conflict' => 'Product edit conflict',
    'barcode_conflict' => 'Barcode conflict',
    'product_deleted' => 'Product deleted remotely',
    'stocktake_displaced' => 'Stocktake superseded by another device',
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

String _formatUtc(DateTime timestamp) {
  final value = timestamp.toUtc();
  String twoDigits(int number) => number.toString().padLeft(2, '0');

  return '${value.year.toString().padLeft(4, '0')}-'
      '${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)} UTC';
}
