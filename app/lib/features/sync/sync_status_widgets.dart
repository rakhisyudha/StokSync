import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/local_query_providers.dart';
import 'sync_trigger_coordinator.dart';
import 'sync_trigger_providers.dart';

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

/// Returns the latest locally known sync detail for the status card.
String localSyncLastKnownStatus(SyncSummary summary) {
  final error = summary.lastError?.trim();
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
            Chip(
              key: const Key('sync-status-label'),
              label: Text(status),
              visualDensity: VisualDensity.compact,
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
