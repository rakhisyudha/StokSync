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

typedef SyncResponseHandler =
    Future<void> Function(
      SyncResponse response,
      List<PendingSyncOperation> operations,
    );

/// Result of one serialized push exchange.
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

/// Coordinates one bounded push exchange while leaving response
/// reconciliation to the next task's local-store implementation.
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
    this.maxOperations = syncMaxOperations,
    this.maxChanges = syncMaxChanges,
  }) : _transport = transport,
       _pendingOperations = pendingOperations,
       _cursorStore = cursorStore,
       _deviceId = deviceId,
       _now = now ?? _utcNow,
       _mutex = mutex ?? SyncMutex(),
       _backoff = backoff ?? SyncBackoffPolicy(),
       _onResponse = onResponse {
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
  final int maxOperations;
  final int maxChanges;

  SyncMutex get mutex => _mutex;

  /// Executes at most one due FIFO batch. A null result means the queue is
  /// empty at the time of selection; pull-only synchronization is intentionally
  /// left to the later incremental pull task.
  Future<SyncCycleResult?> synchronize() {
    return _mutex.runExclusive(_synchronizeOnce);
  }

  Future<SyncCycleResult?> _synchronizeOnce() async {
    await _pendingOperations.recoverInterruptedOperations();
    final now = _now().toUtc();
    final operations = await _pendingOperations.claimDueOperations(
      now: now,
      limit: maxOperations,
    );
    if (operations.isEmpty) {
      return null;
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
      await _bestEffortRelease(operations);
      Error.throwWithStackTrace(error, stackTrace);
    }

    final request = SyncRequest(
      deviceId: _deviceId,
      cursor: cursor,
      maxChanges: maxChanges,
      clientTime: now,
      operations: syncOperations,
    );

    final SyncResponse response;
    try {
      response = await _transport.synchronize(request);
    } catch (error, stackTrace) {
      await _bestEffortHandleFailure(operations, error, now);
      Error.throwWithStackTrace(error, stackTrace);
    }

    final handler = _onResponse;
    if (handler != null) {
      try {
        await handler(response, operations);
      } catch (error, stackTrace) {
        // A crash or failed local apply must not strand queue rows as
        // inflight. If this release is interrupted too, the next cycle's
        // recovery pass makes them eligible again.
        await _bestEffortRelease(operations);
        Error.throwWithStackTrace(error, stackTrace);
      }
    }

    return SyncCycleResult(response: response, operations: operations);
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
          await _pendingOperations.releaseInFlight(
            operations.map((operation) => operation.opId),
          );
        case SyncRetryDisposition.terminal:
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

String _safeErrorSummary(Object error) {
  if (error is SyncTransportException || error is SyncProtocolException) {
    return error.toString();
  }
  return error.runtimeType.toString();
}

DateTime _utcNow() => DateTime.now().toUtc();
