import 'package:sync_engine/sync_engine.dart';

import 'sync_page_applier.dart';
import 'sync_response_reconciler.dart';

/// Composes push-result reconciliation with atomic change-page application.
///
/// [SyncEngine] invokes this handler for the initial push response and for
/// every pull-only pagination response. The response reconciler persists the
/// operation outcomes first; the page applier then applies the complete
/// response page and advances the local cursor in its transaction. Replaying a
/// page after an interrupted run remains safe because both local adapters are
/// idempotent.
final class DriftSyncResponseApplier {
  const DriftSyncResponseApplier({
    required DriftSyncResponseReconciler responseReconciler,
    required DriftSyncPageApplier pageApplier,
  }) : _responseReconciler = responseReconciler,
       _pageApplier = pageApplier;

  final DriftSyncResponseReconciler _responseReconciler;
  final DriftSyncPageApplier _pageApplier;

  /// Applies operation outcomes and then the complete change page.
  ///
  /// An applied push result can point at a change that is also present in the
  /// response's pull page. The reconciler has already persisted that canonical
  /// consequence, so the page applier must advance past the change without
  /// writing it a second time. This is especially important for Drift date-time
  /// columns, which can round-trip with less precision than the server JSON.
  Future<void> call(
    SyncResponse response,
    List<PendingSyncOperation> operations,
  ) async {
    await _responseReconciler.reconcile(response, operations);

    final changeSequences = response.changes
        .map((change) => change.seq)
        .toSet();
    final reconciledSequences = response.results
        .where(
          (result) =>
              result.status == SyncOperationResultStatus.applied &&
              result.seq != null &&
              changeSequences.contains(result.seq),
        )
        .map((result) => result.seq!)
        .toSet();
    await _pageApplier.applyPage(response, skipSequences: reconciledSequences);
  }
}
