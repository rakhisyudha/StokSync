import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/local/local_query_providers.dart';
import 'sync_trigger_coordinator.dart';
import 'sync_trigger_providers.dart';

/// A compact, reactive entry point to the local sync-status detail screen.
class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(syncSummaryProvider);
    return Semantics(
      button: true,
      label: 'Open sync status details',
      child: summary.when(
        loading: () => ActionChip(
          key: const Key('sync-status-chip'),
          label: const Text('Sync status'),
          onPressed: () => _openSyncStatusDetails(context),
        ),
        error: (_, _) => ActionChip(
          key: const Key('sync-status-chip'),
          label: const Text('Sync unavailable'),
          onPressed: () => _openSyncStatusDetails(context),
        ),
        data: (value) => ActionChip(
          key: const Key('sync-status-chip'),
          avatar: const Icon(Icons.sync_outlined, size: 18),
          label: Text(localSyncStatusLabel(value)),
          onPressed: () => _openSyncStatusDetails(context),
        ),
      ),
    );
  }
}

/// A local-first sync status surface with an optional manual trigger.
///
/// Counts and timestamps come from the Drift replica. When an authenticated
/// runtime is supplied, the manual action delegates to the trigger coordinator,
/// which confirms service reachability before sending queued work.
class LocalSyncStatusCard extends ConsumerWidget {
  const LocalSyncStatusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(syncSummaryProvider);
    final coordinator = ref.watch(syncTriggerCoordinatorProvider);
    return Card(
      key: const Key('sync-status-card'),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: summary.when(
          loading: () => const _LocalSyncStatusLoading(),
          error: (_, _) => const _LocalSyncStatusUnavailable(),
          data: (value) =>
              _LocalSyncStatusContent(summary: value, coordinator: coordinator),
        ),
      ),
    );
  }
}

/// Returns the current status label without implying that a network request
/// has happened.
String localSyncStatusLabel(SyncSummary summary) {
  switch (summary.status.trim().toLowerCase()) {
    case 'syncing':
      return 'Syncing';
    case 'backing_off':
      return 'Backing off';
    case 'blocked':
      return 'Sync blocked';
  }

  final error = summary.lastError?.trim();
  if (error != null && error.isNotEmpty) {
    return 'Needs attention';
  }
  if (summary.pendingOperationCount > 0) {
    return 'Queued locally';
  }
  if (summary.lastSyncedAt != null) {
    return 'Last synced';
  }
  return 'Local only';
}

/// Returns the user-facing name of the persisted sync state.
String syncStatusStateLabel(String status) {
  return switch (status.trim().toLowerCase()) {
    'syncing' => 'Syncing',
    'backing_off' => 'Backing off',
    'blocked' => 'Blocked',
    'idle' => 'Idle',
    _ => 'Idle',
  };
}

/// Returns the latest locally known sync detail for the status card.
String localSyncLastKnownStatus(SyncSummary summary) {
  final error = summary.lastError?.trim();
  switch (summary.status.trim().toLowerCase()) {
    case 'syncing':
      return error == null || error.isEmpty
          ? 'Sync is in progress. Local data remains available.'
          : 'Sync is in progress. Last error: $error';
    case 'backing_off':
      return error == null || error.isEmpty
          ? 'Sync will retry automatically. Local work is retained.'
          : 'Sync will retry automatically: $error';
    case 'blocked':
      return error == null || error.isEmpty
          ? 'Sync is blocked until authentication is restored. Local work is retained.'
          : 'Sync blocked: $error';
  }
  if (error != null && error.isNotEmpty) {
    return 'Last attempt failed: $error';
  }
  final lastSyncedAt = summary.lastSyncedAt;
  if (lastSyncedAt != null) {
    return 'Last successful sync: ${_formatUtc(lastSyncedAt)}';
  }
  if (summary.bootstrapped) {
    return 'Ready to sync. No completed sync is recorded locally.';
  }
  return 'Not synced yet. Local changes stay on this device.';
}

class _LocalSyncStatusContent extends StatelessWidget {
  const _LocalSyncStatusContent({
    required this.summary,
    required this.coordinator,
  });

  final SyncSummary summary;
  final SyncTriggerCoordinator? coordinator;

  @override
  Widget build(BuildContext context) {
    final status = localSyncStatusLabel(summary);
    return Column(
      key: const Key('sync-status-content'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.sync_outlined),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Sync status',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (coordinator != null)
              IconButton(
                key: const Key('manual-sync-button'),
                tooltip: 'Sync now',
                icon: const Icon(Icons.sync),
                onPressed: () {
                  unawaited(coordinator!.manualRefresh());
                },
              ),
            ActionChip(
              key: const Key('sync-status-label'),
              label: Text(status),
              visualDensity: VisualDensity.compact,
              onPressed: () => _openSyncStatusDetails(context),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          localSyncLastKnownStatus(summary),
          key: const Key('sync-last-known-status'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _SyncStatusMetric(
                key: const Key('queued-operation-count'),
                value: summary.pendingOperationCount,
                label: 'queued operations',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SyncStatusMetric(
                key: const Key('unresolved-conflict-count'),
                value: summary.unresolvedConflictCount,
                label: 'unresolved conflicts',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Status counts are local; sync checks reachability before sending work.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Shows the complete local sync summary as the authenticated Sync
/// destination, with an optional manual sync action.
class SyncStatusDetailPage extends ConsumerWidget {
  const SyncStatusDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(syncSummaryProvider);
    final coordinator = ref.watch(syncTriggerCoordinatorProvider);
    return Scaffold(
      key: const Key('sync-destination-page'),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sync'),
            Text(
              'Local-first delivery status',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: summary.when(
        loading: () => const _SyncStatusDetailLoading(),
        error: (_, _) => _SyncStatusDetailUnavailable(coordinator: coordinator),
        data: (value) =>
            _SyncStatusDetailContent(summary: value, coordinator: coordinator),
      ),
    );
  }
}

class _SyncStatusDetailContent extends StatelessWidget {
  const _SyncStatusDetailContent({
    required this.summary,
    required this.coordinator,
  });

  final SyncSummary summary;
  final SyncTriggerCoordinator? coordinator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final lastSyncedAt = summary.lastSyncedAt;
    final error = summary.lastError?.trim();
    final semantic = semanticColorsOf(context);
    final hasError = error != null && error.isNotEmpty;
    final statusValue = summary.status.trim().toLowerCase();
    final attentionRequired = statusValue == 'blocked' || hasError;
    final backingOff = statusValue == 'backing_off';
    final statusContainer = attentionRequired
        ? colorScheme.errorContainer
        : backingOff
        ? semantic.warningContainer
        : colorScheme.primaryContainer;
    final statusOnContainer = attentionRequired
        ? colorScheme.onErrorContainer
        : backingOff
        ? semantic.onWarningContainer
        : colorScheme.onPrimaryContainer;

    return ListView(
      key: const Key('sync-status-detail-content'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Text('Sync status', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'Keep working locally while StokSync checks reachability and sends pending changes.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Card(
          key: const Key('sync-status-overview'),
          color: statusContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: statusOnContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      attentionRequired
                          ? Icons.sync_problem_outlined
                          : Icons.sync_outlined,
                      color: statusContainer,
                      size: 28,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current state',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: statusOnContainer,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        syncStatusStateLabel(summary.status),
                        key: const Key('sync-status-state'),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: statusOnContainer,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Chip(
                        key: const Key('sync-status-detail-chip'),
                        label: Text(localSyncStatusLabel(summary)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Sync overview', style: theme.textTheme.titleLarge),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SyncStatusDetailMetric(
                key: const Key('sync-status-pending-count'),
                label: 'Pending operations',
                value: '${summary.pendingOperationCount}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SyncStatusDetailMetric(
                key: const Key('sync-status-conflict-count'),
                label: 'Unresolved conflicts',
                value: '${summary.unresolvedConflictCount}',
              ),
            ),
          ],
        ),
        _SyncStatusDetailMetric(
          key: const Key('sync-status-last-successful-sync'),
          label: 'Last successful sync',
          value: lastSyncedAt == null ? 'Never' : _formatUtc(lastSyncedAt),
        ),
        _SyncStatusDetailMetric(
          key: const Key('sync-status-error-summary'),
          label: 'Latest error',
          value: hasError ? error : 'None recorded',
          valueColor: hasError ? colorScheme.error : null,
        ),
        const SizedBox(height: 8),
        Card(
          key: const Key('sync-status-explanation'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'What this means',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        localSyncLastKnownStatus(summary),
                        key: const Key('sync-status-detail-copy'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Status counts are local. A sync attempt confirms reachability before sending work.',
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
        ),
        if (coordinator != null) ...[
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('manual-sync-detail-button'),
              onPressed: () => unawaited(coordinator!.manualRefresh()),
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
            ),
          ),
        ],
      ],
    );
  }
}

class _SyncStatusDetailMetric extends StatelessWidget {
  const _SyncStatusDetailMetric({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(color: valueColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncStatusDetailLoading extends StatelessWidget {
  const _SyncStatusDetailLoading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView(
      key: const Key('sync-status-detail-loading'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Text('Sync status', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                CircularProgressIndicator(color: colorScheme.primary),
                const SizedBox(width: 16),
                const Expanded(child: Text('Reading local sync status…')),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SyncStatusDetailUnavailable extends StatelessWidget {
  const _SyncStatusDetailUnavailable({required this.coordinator});

  final SyncTriggerCoordinator? coordinator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView(
      key: const Key('sync-status-detail-unavailable'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Text('Sync status', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 20),
        Card(
          color: colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Local sync status is unavailable. Your local inventory remains on this device.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (coordinator != null) ...[
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('manual-sync-detail-button'),
              onPressed: () => unawaited(coordinator!.manualRefresh()),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ),
        ],
      ],
    );
  }
}

void _openSyncStatusDetails(BuildContext context) {
  Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => const SyncStatusDetailPage()));
}

class _SyncStatusMetric extends StatelessWidget {
  const _SyncStatusMetric({
    super.key,
    required this.value,
    required this.label,
  });

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$value $label',
        style: Theme.of(context).textTheme.labelLarge,
      ),
    );
  }
}

class _LocalSyncStatusLoading extends StatelessWidget {
  const _LocalSyncStatusLoading();

  @override
  Widget build(BuildContext context) {
    return const Row(
      key: Key('sync-status-loading'),
      children: [
        SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 12),
        Text('Reading local sync status…'),
      ],
    );
  }
}

class _LocalSyncStatusUnavailable extends StatelessWidget {
  const _LocalSyncStatusUnavailable();

  @override
  Widget build(BuildContext context) {
    return const Column(
      key: Key('sync-status-unavailable'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sync status unavailable'),
        SizedBox(height: 4),
        Text('The local sync metadata could not be read.'),
      ],
    );
  }
}

String _formatUtc(DateTime timestamp) {
  final value = timestamp.toUtc();
  String twoDigits(int number) => number.toString().padLeft(2, '0');

  return '${value.year.toString().padLeft(4, '0')}-'
      '${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)} UTC';
}
