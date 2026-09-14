import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'protocol.dart';
import 'retry.dart';
import 'transport.dart';

/// A pending operation state persisted in the local queue.
enum PendingSyncOperationStatus {
  queued('queued'),
  inflight('inflight'),
  retrying('retrying'),
  blocked('blocked'),
  completed('completed');

  const PendingSyncOperationStatus(this.wireValue);

  final String wireValue;

  static PendingSyncOperationStatus fromWire(String value) {
    for (final status in values) {
      if (status.wireValue == value) {
        return status;
      }
    }
    throw ArgumentError.value(
      value,
      'value',
      'unknown pending operation state',
    );
  }
}

/// A framework-independent representation of one row in Drift's
/// `pending_ops` table.
final class PendingSyncOperation {
  PendingSyncOperation({
    required this.opId,
    required this.localSeq,
    required this.entity,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.baseVersion,
    required this.attempts,
    required DateTime nextAttemptAt,
    required this.lastError,
    required this.status,
  }) : nextAttemptAt = nextAttemptAt.toUtc() {
    if (localSeq <= 0) {
      throw ArgumentError.value(localSeq, 'localSeq', 'must be positive');
    }
    if (attempts < 0) {
      throw ArgumentError.value(attempts, 'attempts', 'must not be negative');
    }
    if (opId.isEmpty ||
        entity.isEmpty ||
        entityId.isEmpty ||
        operation.isEmpty) {
      throw ArgumentError(
        'pending operation identity fields must be non-empty',
      );
    }
  }

  final String opId;
  final int localSeq;
  final String entity;
  final String entityId;
  final String operation;
  final String payload;
  final int? baseVersion;
  final int attempts;
  final DateTime nextAttemptAt;
  final String? lastError;
  final PendingSyncOperationStatus status;

  /// Converts the local queue representation into the v1 protocol envelope.
  ///
  /// Local repositories persist only the operation name, base version, and
  /// payload object. The operation id and envelope are reconstructed here so
  /// a retry uses exactly the same idempotency key and payload.
  SyncOperation toSyncOperation() {
    final decodedPayload = _decodePayload(payload, opId);
    final envelope = <String, Object?>{
      'op_id': opId,
      'op': operation,
      if (baseVersion != null) 'base_version': baseVersion,
      'payload': decodedPayload,
    };
    return SyncOperation.fromJson(envelope);
  }
}

Map<String, Object?> _decodePayload(String source, String operationId) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw SyncProtocolException(
      SyncProtocolErrorKind.malformedJson,
      'pending operation payload contains malformed JSON',
      field: 'pending_ops.$operationId.payload',
    );
  }
  if (decoded is! Map) {
    throw SyncProtocolException(
      SyncProtocolErrorKind.invalidValue,
      'pending operation payload must be a JSON object',
      field: 'pending_ops.$operationId.payload',
    );
  }

  final payload = <String, Object?>{};
  for (final entry in decoded.entries) {
    if (entry.key is! String) {
      throw SyncProtocolException(
        SyncProtocolErrorKind.invalidValue,
        'pending operation payload contains a non-string field name',
        field: 'pending_ops.$operationId.payload',
      );
    }
    payload[entry.key as String] = entry.value;
  }
  return payload;
}

/// Narrow local-storage seam used by [SyncEngine].
///
/// Implementations must make claiming and state transitions durable. In
/// particular, [claimDueOperations] must mark the returned rows `inflight`
/// before returning them, and [recoverInterruptedOperations] must make rows
/// left in that state eligible again after a process interruption.
abstract interface class SyncPendingOperationStore {
  Future<void> recoverInterruptedOperations();

  Future<List<PendingSyncOperation>> claimDueOperations({
    required DateTime now,
    required int limit,
  });

  Future<void> scheduleRetry(
    String operationId, {
    required DateTime scheduledAt,
    required Duration delay,
    required String error,
  });

  Future<void> releaseInFlight(Iterable<String> operationIds);

  /// Parks an operation after a non-retryable failure without deleting it.
  Future<void> markBlocked(String operationId, {required String error});
}

/// Narrow read seam for the persisted `sync_state.cursor` value.
abstract interface class SyncCursorStore {
  Future<int> readCursor();
}

/// Narrow durable sync-status seam used by [SyncEngine].
///
/// Implementations persist only synchronization metadata. They must not
/// delete, reset, or otherwise rewrite local products, movements, queue rows,
/// or conflict records when authentication becomes blocked.
abstract interface class SyncStatusStore {
  /// Records that a serialized sync cycle has started.
  Future<void> markSyncing();

  /// Records a retryable failure while retaining the latest safe error summary.
  Future<void> markBackingOff({required String error});

  /// Records a terminal operation error without blocking unrelated sync work.
  Future<void> markError({required String error});

  /// Records an authentication/schema blocker that requires user/app action.
  Future<void> markBlocked({required String error});

  /// Clears transient status after a fully applied sync cycle.
  Future<void> markSyncSucceeded(DateTime serverTime);
}

/// Applies one validated response page and persists its cursor before
/// returning. [operations] is non-empty only for the initial push response;
/// pagination responses always pass an empty list.
typedef SyncResponseHandler =
    Future<void> Function(
      SyncResponse response,
      List<PendingSyncOperation> operations,
    );

/// Result of one serialized push-then-pull run. [response] is the initial
/// push exchange response; pull-only pagination responses are delivered to the
/// response handler in order but are not duplicated here.
final class SyncCycleResult {
  SyncCycleResult({
    required this.response,
    required List<PendingSyncOperation> operations,
  }) : operations = List<PendingSyncOperation>.unmodifiable(operations);

  final SyncResponse response;
  final List<PendingSyncOperation> operations;
}

/// A small FIFO async mutex for serializing sync cycles.
final class SyncMutex {
  Future<void> _tail = Future<void>.value();
  bool _locked = false;

  bool get isLocked => _locked;

  /// Runs [action] after all previously submitted actions and releases the
  /// lock even when [action] throws.
  Future<T> runExclusive<T>(Future<T> Function() action) {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;

    return previous.then((_) async {
      _locked = true;
      try {
        return await action();
      } finally {
        _locked = false;
        if (!release.isCompleted) {
          release.complete();
        }
      }
    });
  }

  /// Alias for callers that prefer mutex terminology.
  Future<T> synchronized<T>(Future<T> Function() action) {
    return runExclusive(action);
  }
}

/// Coordinates one serialized push-then-pull run. The local-store callback
/// reconciles operation outcomes and applies each complete change page.
final class SyncEngine {
  SyncEngine({
    required SyncTransport transport,
    required SyncPendingOperationStore pendingOperations,
    required SyncCursorStore cursorStore,
    required String deviceId,
    SyncNow? now,
    SyncMutex? mutex,
    SyncBackoffPolicy? backoff,
    SyncResponseHandler? onResponse,
    SyncStatusStore? statusStore,
    this.maxOperations = syncMaxOperations,
    this.maxChanges = syncMaxChanges,
  }) : _transport = transport,
       _pendingOperations = pendingOperations,
       _cursorStore = cursorStore,
       _deviceId = deviceId,
       _now = now ?? _utcNow,
       _mutex = mutex ?? SyncMutex(),
       _backoff = backoff ?? SyncBackoffPolicy(),
       _onResponse = onResponse,
       _statusStore = statusStore {
    if (maxOperations <= 0 || maxOperations > syncMaxOperations) {
      throw ArgumentError.value(
        maxOperations,
        'maxOperations',
        'must be between one and syncMaxOperations',
      );
    }
    if (maxChanges <= 0 || maxChanges > syncMaxChanges) {
      throw ArgumentError.value(
        maxChanges,
        'maxChanges',
        'must be between one and syncMaxChanges',
      );
    }
  }

  final SyncTransport _transport;
  final SyncPendingOperationStore _pendingOperations;
  final SyncCursorStore _cursorStore;
  final String _deviceId;
  final SyncNow _now;
  final SyncMutex _mutex;
  final SyncBackoffPolicy _backoff;
  final SyncResponseHandler? _onResponse;
  final SyncStatusStore? _statusStore;
  final int maxOperations;
  final int maxChanges;

  SyncMutex get mutex => _mutex;

  /// Executes one serialized push-then-pull run.
  ///
  /// The first exchange contains the bounded FIFO operation batch. Every
  /// subsequent exchange contains no operations and uses the cursor persisted
  /// by the response handler for the complete page just applied. A run always
  /// performs the initial exchange, even when the local queue is empty, so a
  /// device can pull remote changes.
  Future<SyncCycleResult?> synchronize() {
    return _mutex.runExclusive(_synchronizeOnce);
  }

  Future<SyncCycleResult?> _synchronizeOnce() async {
    await _bestEffortMarkSyncing();
    final now = _now().toUtc();
    try {
      await _pendingOperations.recoverInterruptedOperations();
    } catch (error, stackTrace) {
      await _bestEffortMarkError(error);
      Error.throwWithStackTrace(error, stackTrace);
    }

    late final List<PendingSyncOperation> operations;
    try {
      operations = await _pendingOperations.claimDueOperations(
        now: now,
        limit: maxOperations,
      );
    } catch (error, stackTrace) {
      await _bestEffortMarkError(error);
      Error.throwWithStackTrace(error, stackTrace);
    }

    final syncOperations = <SyncOperation>[];
    try {
      for (final operation in operations) {
        syncOperations.add(operation.toSyncOperation());
      }
    } catch (error, stackTrace) {
      await _bestEffortHandleFailure(operations, error, now);
      Error.throwWithStackTrace(error, stackTrace);
    }

    final int cursor;
    try {
      cursor = await _cursorStore.readCursor();
    } catch (error, stackTrace) {
      await _bestEffortMarkError(error);
      await _bestEffortRelease(operations);
      Error.throwWithStackTrace(error, stackTrace);
    }

    final initialRequest = SyncRequest(
      deviceId: _deviceId,
      cursor: cursor,
      maxChanges: maxChanges,
      clientTime: now,
      operations: syncOperations,
    );

    final SyncResponse initialResponse;
    try {
      initialResponse = await _transport.synchronize(initialRequest);
    } catch (error, stackTrace) {
      await _bestEffortHandleFailure(operations, error, now);
      Error.throwWithStackTrace(error, stackTrace);
    }

    try {
      _validatePaginationPage(initialResponse, cursor);
    } catch (error, stackTrace) {
      // The server response was received, but the operation outcomes could
      // not safely be reconciled. Retain them through the same terminal
      // failure path used for malformed transport responses.
      await _bestEffortHandleFailure(operations, error, now);
      Error.throwWithStackTrace(error, stackTrace);
    }

    var currentCursor = await _applyPageAndReadCursor(
      initialResponse,
      operations,
      requestedCursor: cursor,
    );
    var response = initialResponse;

    while (response.hasMore) {
      final request = SyncRequest(
        deviceId: _deviceId,
        cursor: currentCursor,
        maxChanges: maxChanges,
        clientTime: _now().toUtc(),
        operations: const <SyncOperation>[],
      );

      final SyncResponse nextResponse;
      try {
        nextResponse = await _transport.synchronize(request);
      } catch (error, stackTrace) {
        // The initial operation response has already reached the handler. No
        // claimed operations are associated with this pull-only exchange, but
        // a blocked authentication result still belongs in durable sync
        // status.
        await _bestEffortHandleFailure(
          const <PendingSyncOperation>[],
          error,
          _now().toUtc(),
        );
        Error.throwWithStackTrace(error, stackTrace);
      }

      try {
        _validatePaginationPage(
          nextResponse,
          currentCursor,
          requireEmptyResults: true,
        );
      } catch (error, stackTrace) {
        await _bestEffortMarkError(error);
        Error.throwWithStackTrace(error, stackTrace);
      }

      currentCursor = await _applyPageAndReadCursor(
        nextResponse,
        const <PendingSyncOperation>[],
        requestedCursor: currentCursor,
      );
      response = nextResponse;
    }

    await _bestEffortMarkSyncSucceeded(response.serverTime);
    return SyncCycleResult(response: initialResponse, operations: operations);
  }

  Future<int> _applyPageAndReadCursor(
    SyncResponse response,
    List<PendingSyncOperation> operations, {
    required int requestedCursor,
  }) async {
    final handler = _onResponse;
    if (handler != null) {
      try {
        await handler(response, operations);
      } catch (error, stackTrace) {
        // A crash or failed local apply must not strand queue rows as
        // inflight. If this release is interrupted too, the next cycle's
        // recovery pass makes them eligible again.
        await _bestEffortMarkError(error);
        await _bestEffortRelease(operations);
        Error.throwWithStackTrace(error, stackTrace);
      }
    }

    try {
      final persistedCursor = await _cursorStore.readCursor();
      if (persistedCursor != response.nextCursor) {
        throw _invalidPagination(
          'next_cursor',
          'was not persisted after applying the complete change page',
        );
      }
      if (persistedCursor < requestedCursor) {
        throw _invalidPagination(
          'next_cursor',
          'must not move the local cursor backwards',
        );
      }
      return persistedCursor;
    } catch (error, stackTrace) {
      await _bestEffortMarkError(error);
      await _bestEffortRelease(operations);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _validatePaginationPage(
    SyncResponse response,
    int requestedCursor, {
    bool requireEmptyResults = false,
  }) {
    // Validate the complete response before invoking the local page handler so
    // malformed pages cannot partially advance the replica.
    response.toJson();
    if (requireEmptyResults && response.results.isNotEmpty) {
      throw _invalidPagination(
        'results',
        'must be empty for a pull-only pagination request',
      );
    }
    if (response.nextCursor < requestedCursor) {
      throw _invalidPagination(
        'next_cursor',
        'must not move the local cursor backwards',
      );
    }

    final changes = response.changes;
    if (changes.isEmpty) {
      if (response.nextCursor != requestedCursor) {
        throw _invalidPagination(
          'next_cursor',
          'must preserve the request cursor when a page is empty',
        );
      }
      if (response.hasMore) {
        throw _invalidPagination(
          'has_more',
          'cannot be true for an empty change page',
        );
      }
      return;
    }

    final lastSequence = changes.last.seq;
    if (response.nextCursor != lastSequence) {
      throw _invalidPagination(
        'next_cursor',
        'must equal the last change sequence in the page',
      );
    }
    if (response.nextCursor > requestedCursor &&
        changes.first.seq <= requestedCursor) {
      throw _invalidPagination(
        'changes',
        'contains changes at or before the request cursor while advancing',
      );
    }
    if (response.hasMore && response.nextCursor <= requestedCursor) {
      throw _invalidPagination(
        'next_cursor',
        'must advance when has_more is true',
      );
    }
  }

  Future<void> _bestEffortHandleFailure(
    List<PendingSyncOperation> operations,
    Object error,
    DateTime scheduledAt,
  ) async {
    final classification = SyncRetryClassifier.classify(error);
    try {
      switch (classification.disposition) {
        case SyncRetryDisposition.retryable:
          await _bestEffortMarkBackingOff(error);
          for (final operation in operations) {
            final nextAttempt = operation.attempts + 1;
            await _pendingOperations.scheduleRetry(
              operation.opId,
              scheduledAt: scheduledAt,
              delay: _backoff.delayForAttempt(nextAttempt),
              error: _safeErrorSummary(error),
            );
          }
        case SyncRetryDisposition.blocked:
          await _bestEffortMarkBlocked(error);
          await _pendingOperations.releaseInFlight(
            operations.map((operation) => operation.opId),
          );
        case SyncRetryDisposition.terminal:
          await _bestEffortMarkError(error);
          for (final operation in operations) {
            await _pendingOperations.markBlocked(
              operation.opId,
              error: _safeErrorSummary(error),
            );
          }
      }
    } on Object {
      // The original failure remains authoritative. Any rows left inflight
      // are recoverable by the next cycle, so a secondary local-write error
      // must not hide the network/protocol failure or lose the operation.
    }
  }

  Future<void> _bestEffortMarkSyncing() async {
    final store = _statusStore;
    if (store == null) {
      return;
    }
    try {
      await store.markSyncing();
    } on Object {
      // Status metadata is advisory; a failure must not prevent sync work.
    }
  }

  Future<void> _bestEffortMarkBackingOff(Object error) async {
    final store = _statusStore;
    if (store == null) {
      return;
    }
    try {
      await store.markBackingOff(error: _safeErrorSummary(error));
    } on Object {
      // The original retryable failure remains authoritative.
    }
  }

  Future<void> _bestEffortMarkError(Object error) async {
    final store = _statusStore;
    if (store == null) {
      return;
    }
    try {
      await store.markError(error: _safeErrorSummary(error));
    } on Object {
      // The original terminal failure remains authoritative.
    }
  }

  Future<void> _bestEffortMarkBlocked(Object error) async {
    final store = _statusStore;
    if (store == null) {
      return;
    }
    try {
      await store.markBlocked(error: _safeErrorSummary(error));
    } on Object {
      // The original authentication failure remains authoritative. The local
      // queue and replica are still preserved if metadata persistence fails.
    }
  }

  Future<void> _bestEffortMarkSyncSucceeded(DateTime serverTime) async {
    final store = _statusStore;
    if (store == null) {
      return;
    }
    try {
      await store.markSyncSucceeded(serverTime.toUtc());
    } on Object {
      // Sync data was already reconciled. A later successful cycle can retry
      // this metadata-only clear; never roll back local domain data here.
    }
  }

  Future<void> _bestEffortRelease(List<PendingSyncOperation> operations) async {
    try {
      await _pendingOperations.releaseInFlight(
        operations.map((operation) => operation.opId),
      );
    } on Object {
      // Startup recovery is the final safety net if this write is interrupted.
    }
  }
}

SyncProtocolException _invalidPagination(String field, String message) {
  return SyncProtocolException(
    SyncProtocolErrorKind.invalidResponse,
    message,
    field: field,
  );
}

String _safeErrorSummary(Object error) {
  if (error is SyncTransportException || error is SyncProtocolException) {
    return error.toString();
  }
  return error.runtimeType.toString();
}

DateTime _utcNow() => DateTime.now().toUtc();
