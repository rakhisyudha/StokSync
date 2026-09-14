import 'dart:async';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  group('SyncMutex', () {
    test('serializes concurrent actions and releases after an error', () async {
      final mutex = SyncMutex();
      final firstStarted = Completer<void>();
      final allowFirstToFinish = Completer<void>();
      final order = <String>[];

      final first = mutex.runExclusive(() async {
        order.add('first-start');
        firstStarted.complete();
        await allowFirstToFinish.future;
        order.add('first-end');
        throw StateError('first failure');
      });
      await firstStarted.future;

      final second = mutex.runExclusive(() async {
        order.add('second');
        return 42;
      });

      expect(mutex.isLocked, isTrue);
      expect(order, ['first-start']);
      allowFirstToFinish.complete();
      await expectLater(first, throwsStateError);
      expect(await second, 42);
      expect(order, ['first-start', 'first-end', 'second']);
      expect(mutex.isLocked, isFalse);
    });
  });

  group('SyncRetryClassifier', () {
    test('retries network, timeout, rate-limit, and server failures', () {
      final retryable = <Object>[
        const SyncNetworkException(),
        TimeoutException('timeout'),
        const SyncHttpException(
          statusCode: 408,
          kind: SyncHttpErrorKind.requestTimeout,
        ),
        const SyncHttpException(
          statusCode: 429,
          kind: SyncHttpErrorKind.rateLimited,
        ),
        const SyncHttpException(
          statusCode: 503,
          kind: SyncHttpErrorKind.server,
        ),
        const SyncClockOffsetException(),
      ];

      for (final error in retryable) {
        expect(
          classifySyncFailure(error).disposition,
          SyncRetryDisposition.retryable,
          reason: '$error should be retryable',
        );
      }
    });

    test(
      'blocks authentication and schema failures without retrying blindly',
      () {
        expect(
          classifySyncFailure(const SyncAuthenticationException()).disposition,
          SyncRetryDisposition.blocked,
        );
        expect(
          classifySyncFailure(
            UnsupportedSchemaVersionException(
              receivedVersion: 2,
              minimumSupportedVersion: 1,
            ),
          ).disposition,
          SyncRetryDisposition.blocked,
        );
        expect(
          classifySyncFailure(
            const SyncHttpException(
              statusCode: 403,
              kind: SyncHttpErrorKind.forbidden,
            ),
          ).disposition,
          SyncRetryDisposition.blocked,
        );
      },
    );

    test('parks protocol and validation failures as terminal', () {
      expect(
        classifySyncFailure(
          const SyncProtocolException(
            SyncProtocolErrorKind.invalidValue,
            'invalid',
          ),
        ).disposition,
        SyncRetryDisposition.terminal,
      );
      expect(
        classifySyncFailure(
          const SyncHttpException(
            statusCode: 400,
            kind: SyncHttpErrorKind.client,
          ),
        ).disposition,
        SyncRetryDisposition.terminal,
      );
    });
  });

  group('SyncBackoffPolicy', () {
    test('uses exponential delays and caps the jittered value', () {
      final policy = SyncBackoffPolicy(
        baseDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 5),
        jitterRatio: 0,
      );

      expect(policy.delayForAttempt(1), const Duration(seconds: 1));
      expect(policy.delayForAttempt(2), const Duration(seconds: 2));
      expect(policy.delayForAttempt(3), const Duration(seconds: 4));
      expect(policy.delayForAttempt(4), const Duration(seconds: 5));
      expect(policy.delayForAttempt(100), const Duration(seconds: 5));
    });

    test('keeps jitter within the configured multiplicative bounds', () {
      final policy = SyncBackoffPolicy(
        baseDelay: const Duration(seconds: 10),
        maxDelay: const Duration(minutes: 1),
        jitterRatio: 0.2,
      );

      expect(
        policy.delayForAttempt(1, jitterSample: 0),
        const Duration(seconds: 8),
      );
      expect(
        policy.delayForAttempt(1, jitterSample: 1),
        const Duration(seconds: 12),
      );
      expect(
        policy.delayForAttempt(10, jitterSample: 1),
        lessThanOrEqualTo(const Duration(minutes: 1)),
      );
    });
  });

  group('SyncEngine', () {
    test(
      'claims due operations in FIFO order and sends stable envelopes',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final store = _MemoryPendingStore([
          _pendingOperation(
            opId: _operationId(2),
            localSeq: 2,
            nextAttemptAt: now,
          ),
          _pendingOperation(
            opId: _operationId(1),
            localSeq: 1,
            nextAttemptAt: now.subtract(const Duration(seconds: 1)),
          ),
          _pendingOperation(
            opId: _operationId(3),
            localSeq: 3,
            nextAttemptAt: now.add(const Duration(minutes: 1)),
          ),
        ]);
        final transport = _RecordingTransport();
        final engine = SyncEngine(
          transport: transport,
          pendingOperations: store,
          cursorStore: _MemoryCursorStore(1482),
          deviceId: _deviceId,
          now: () => now,
          maxOperations: 2,
          maxChanges: 500,
          backoff: SyncBackoffPolicy(jitterRatio: 0),
        );

        final result = await engine.synchronize();

        expect(result, isNotNull);
        expect(transport.calls, 1);
        expect(
          transport.request!.operations.map((operation) => operation.opId),
          [_operationId(1), _operationId(2)],
        );
        expect(transport.request!.cursor, 1482);
        expect(transport.request!.clientTime, now);
        expect(
          store.statusOf(_operationId(1)),
          PendingSyncOperationStatus.inflight,
        );
        expect(
          store.statusOf(_operationId(2)),
          PendingSyncOperationStatus.inflight,
        );
        expect(
          store.statusOf(_operationId(3)),
          PendingSyncOperationStatus.queued,
        );
      },
    );

    test(
      'pushes once, applies each page, and pulls with persisted cursors',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final cursorStore = _MemoryCursorStore(0);
        final transport = _PagingTransport([
          _pageResponse(now, sequence: 1, nextCursor: 1, hasMore: true),
          _pageResponse(now, sequence: 2, nextCursor: 2, hasMore: true),
          _pageResponse(now, nextCursor: 2),
        ]);
        final events = <String>[];
        final operation = _pendingOperation(
          opId: _operationId(1),
          localSeq: 1,
          nextAttemptAt: now,
        );
        final engine = SyncEngine(
          transport: transport,
          pendingOperations: _MemoryPendingStore([operation]),
          cursorStore: cursorStore,
          deviceId: _deviceId,
          now: () => now,
          onResponse: (response, operations) async {
            events.add('apply:${response.nextCursor}:${operations.length}');
            cursorStore.cursor = response.nextCursor;
          },
        );

        final result = await engine.synchronize();

        expect(result, isNotNull);
        expect(transport.requests, hasLength(3));
        expect(transport.requests.map((request) => request.cursor), [0, 1, 2]);
        expect(transport.requests.map((request) => request.operations.length), [
          1,
          0,
          0,
        ]);
        expect(events, ['apply:1:1', 'apply:2:0', 'apply:2:0']);
        expect(cursorStore.cursor, 2);
      },
    );

    test(
      'runs a pull-only exchange and applies a final non-empty page',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final cursorStore = _MemoryCursorStore(4);
        final transport = _PagingTransport([
          _pageResponse(now, sequence: 5, nextCursor: 5),
        ]);
        final engine = SyncEngine(
          transport: transport,
          pendingOperations: _MemoryPendingStore(const []),
          cursorStore: cursorStore,
          deviceId: _deviceId,
          now: () => now,
          onResponse: (response, operations) async {
            expect(operations, isEmpty);
            cursorStore.cursor = response.nextCursor;
          },
        );

        final result = await engine.synchronize();

        expect(result, isNotNull);
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single.cursor, 4);
        expect(transport.requests.single.operations, isEmpty);
        expect(cursorStore.cursor, 5);
      },
    );

    test(
      'rejects a non-progressing pagination page before local application',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final cursorStore = _MemoryCursorStore(7);
        final transport = _PagingTransport([
          _pageResponse(now, nextCursor: 7, hasMore: true),
        ]);
        var handlerCalled = false;
        final engine = SyncEngine(
          transport: transport,
          pendingOperations: _MemoryPendingStore(const []),
          cursorStore: cursorStore,
          deviceId: _deviceId,
          now: () => now,
          onResponse: (_, _) async {
            handlerCalled = true;
          },
        );

        await expectLater(
          engine.synchronize(),
          throwsA(isA<SyncProtocolException>()),
        );

        expect(transport.requests, hasLength(1));
        expect(handlerCalled, isFalse);
        expect(cursorStore.cursor, 7);
      },
    );

    test(
      'rejects a page whose cursor does not match its last change',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final cursorStore = _MemoryCursorStore(0);
        final transport = _PagingTransport([
          _pageResponse(now, sequence: 8, nextCursor: 9),
        ]);
        final engine = SyncEngine(
          transport: transport,
          pendingOperations: _MemoryPendingStore(const []),
          cursorStore: cursorStore,
          deviceId: _deviceId,
          now: () => now,
          onResponse: (_, _) async {
            fail('malformed page must not reach the local handler');
          },
        );

        await expectLater(
          engine.synchronize(),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(cursorStore.cursor, 0);
      },
    );

    test(
      'schedules retryable failures with incremented attempts and jittered delay',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final operation = _pendingOperation(
          opId: _operationId(1),
          localSeq: 1,
          nextAttemptAt: now,
          attempts: 1,
        );
        final store = _MemoryPendingStore([operation]);
        final engine = SyncEngine(
          transport: _RecordingTransport(error: const SyncNetworkException()),
          pendingOperations: store,
          cursorStore: _MemoryCursorStore(0),
          deviceId: _deviceId,
          now: () => now,
          backoff: SyncBackoffPolicy(
            baseDelay: const Duration(seconds: 10),
            maxDelay: const Duration(minutes: 5),
            jitterRatio: 0,
          ),
        );

        await expectLater(
          engine.synchronize(),
          throwsA(isA<SyncNetworkException>()),
        );

        final updated = store.row(operation.opId);
        expect(updated.status, PendingSyncOperationStatus.retrying);
        expect(updated.attempts, 2);
        expect(updated.nextAttemptAt, now.add(const Duration(seconds: 20)));
        expect(updated.lastError, contains('sync request'));
      },
    );

    test(
      'schedules retryable 5xx responses with durable retry metadata',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final operation = _pendingOperation(
          opId: _operationId(1),
          localSeq: 1,
          nextAttemptAt: now,
        );
        final store = _MemoryPendingStore([operation]);
        final engine = SyncEngine(
          transport: _RecordingTransport(
            error: const SyncHttpException(
              statusCode: 503,
              kind: SyncHttpErrorKind.server,
            ),
          ),
          pendingOperations: store,
          cursorStore: _MemoryCursorStore(0),
          deviceId: _deviceId,
          now: () => now,
          backoff: SyncBackoffPolicy(
            baseDelay: const Duration(seconds: 10),
            maxDelay: const Duration(minutes: 5),
            jitterRatio: 0,
          ),
        );

        await expectLater(
          engine.synchronize(),
          throwsA(isA<SyncHttpException>()),
        );

        final updated = store.row(operation.opId);
        expect(updated.status, PendingSyncOperationStatus.retrying);
        expect(updated.attempts, 1);
        expect(updated.nextAttemptAt, now.add(const Duration(seconds: 10)));
        expect(
          updated.lastError,
          'SyncHttpException(status: 503, kind: server)',
        );
      },
    );

    test('releases claimed rows for an authentication blocker', () async {
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
      final store = _MemoryPendingStore([
        _pendingOperation(
          opId: _operationId(1),
          localSeq: 1,
          nextAttemptAt: now,
        ),
      ]);
      final engine = SyncEngine(
        transport: _RecordingTransport(
          error: const SyncAuthenticationException(),
        ),
        pendingOperations: store,
        cursorStore: _MemoryCursorStore(0),
        deviceId: _deviceId,
        now: () => now,
      );

      await expectLater(
        engine.synchronize(),
        throwsA(isA<SyncAuthenticationException>()),
      );
      expect(
        store.statusOf(_operationId(1)),
        PendingSyncOperationStatus.queued,
      );
      expect(store.row(_operationId(1)).attempts, 0);
      expect(store.row(_operationId(1)).payload, contains('"name":"Product"'));
      expect(store.row(_operationId(1)).lastError, isNull);
    });

    test('parks malformed pending payloads without deleting them', () async {
      final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
      final operation = _pendingOperation(
        opId: _operationId(1),
        localSeq: 1,
        nextAttemptAt: now,
        payload: '{malformed',
      );
      final store = _MemoryPendingStore([operation]);
      final engine = SyncEngine(
        transport: _RecordingTransport(),
        pendingOperations: store,
        cursorStore: _MemoryCursorStore(0),
        deviceId: _deviceId,
        now: () => now,
      );

      await expectLater(
        engine.synchronize(),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        store.statusOf(operation.opId),
        PendingSyncOperationStatus.blocked,
      );
      expect(store.row(operation.opId).lastError, contains('malformed'));
    });

    test(
      'releases claimed rows when local response application is interrupted',
      () async {
        final now = DateTime.utc(2026, 9, 13, 10, 2, 14);
        final store = _MemoryPendingStore([
          _pendingOperation(
            opId: _operationId(1),
            localSeq: 1,
            nextAttemptAt: now,
          ),
        ]);
        final engine = SyncEngine(
          transport: _RecordingTransport(),
          pendingOperations: store,
          cursorStore: _MemoryCursorStore(0),
          deviceId: _deviceId,
          now: () => now,
          onResponse: (_, _) async => throw StateError('interrupted apply'),
        );

        await expectLater(engine.synchronize(), throwsStateError);
        expect(
          store.statusOf(_operationId(1)),
          PendingSyncOperationStatus.queued,
        );
      },
    );
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _productId = '0192e1aa-0000-7000-8000-000000000001';

String _operationId(int index) {
  return '0192f3a$index-0000-7000-8000-000000000001';
}

PendingSyncOperation _pendingOperation({
  required String opId,
  required int localSeq,
  required DateTime nextAttemptAt,
  int attempts = 0,
  String payload =
      '{"id":"0192e1aa-0000-7000-8000-000000000001",'
      '"name":"Product"}',
}) {
  return PendingSyncOperation(
    opId: opId,
    localSeq: localSeq,
    entity: 'product',
    entityId: '0192e1aa-0000-7000-8000-000000000001',
    operation: 'upsert_product',
    payload: payload,
    baseVersion: attempts == 0 ? null : 1,
    attempts: attempts,
    nextAttemptAt: nextAttemptAt,
    lastError: null,
    status: PendingSyncOperationStatus.queued,
  );
}

final class _MemoryCursorStore implements SyncCursorStore {
  _MemoryCursorStore(this.cursor);

  int cursor;

  @override
  Future<int> readCursor() async => cursor;
}

SyncResponse _pageResponse(
  DateTime serverTime, {
  int? sequence,
  required int nextCursor,
  bool hasMore = false,
}) {
  final changes = sequence == null
      ? const <SyncChangeEntry>[]
      : <SyncChangeEntry>[
          SyncChangeEntry(
            seq: sequence,
            entity: 'product',
            operation: 'upsert',
            data: const <String, Object?>{'id': _productId},
            createdAt: serverTime,
          ),
        ];
  return SyncResponse(
    results: const [],
    changes: changes,
    nextCursor: nextCursor,
    hasMore: hasMore,
    serverTime: serverTime,
  );
}

final class _PagingTransport implements SyncTransport {
  _PagingTransport(Iterable<SyncResponse> responses)
    : _responses = responses.toList(growable: false);

  final List<SyncResponse> _responses;
  final List<SyncRequest> requests = [];
  var _responseIndex = 0;

  @override
  Future<SyncResponse> synchronize(SyncRequest request) async {
    requests.add(request);
    if (_responseIndex >= _responses.length) {
      throw StateError('test transport received an unexpected request');
    }
    return _responses[_responseIndex++];
  }
}

final class _RecordingTransport implements SyncTransport {
  _RecordingTransport({this.error});

  final Object? error;
  int calls = 0;
  SyncRequest? request;

  @override
  Future<SyncResponse> synchronize(SyncRequest request) async {
    calls++;
    this.request = request;
    if (error != null) {
      throw error!;
    }
    return SyncResponse(
      results: const [],
      changes: const [],
      nextCursor: request.cursor,
      hasMore: false,
      serverTime: request.clientTime,
    );
  }
}

final class _MemoryPendingStore implements SyncPendingOperationStore {
  _MemoryPendingStore(Iterable<PendingSyncOperation> operations)
    : _rows = operations
          .map((operation) => _MutablePendingOperation.from(operation))
          .toList();

  final List<_MutablePendingOperation> _rows;

  PendingSyncOperationStatus statusOf(String operationId) =>
      row(operationId).status;

  PendingSyncOperation row(String operationId) =>
      _rows.singleWhere((operation) => operation.opId == operationId).value;

  @override
  Future<void> recoverInterruptedOperations() async {
    for (final row in _rows) {
      if (row.status == PendingSyncOperationStatus.inflight) {
        row.status = PendingSyncOperationStatus.queued;
      }
    }
  }

  @override
  Future<List<PendingSyncOperation>> claimDueOperations({
    required DateTime now,
    required int limit,
  }) async {
    final candidates =
        _rows
            .where(
              (row) =>
                  (row.status == PendingSyncOperationStatus.queued ||
                      row.status == PendingSyncOperationStatus.retrying) &&
                  !row.nextAttemptAt.isAfter(now.toUtc()),
            )
            .toList()
          ..sort((left, right) => left.localSeq.compareTo(right.localSeq));
    final claimed = candidates.take(limit).toList();
    for (final row in claimed) {
      row.status = PendingSyncOperationStatus.inflight;
    }
    return claimed.map((row) => row.value).toList(growable: false);
  }

  @override
  Future<void> scheduleRetry(
    String operationId, {
    required DateTime scheduledAt,
    required Duration delay,
    required String error,
  }) async {
    final row = _rows.singleWhere((item) => item.opId == operationId);
    if (row.status != PendingSyncOperationStatus.inflight) {
      return;
    }
    row.attempts++;
    row.nextAttemptAt = scheduledAt.toUtc().add(delay);
    row.lastError = error;
    row.status = PendingSyncOperationStatus.retrying;
  }

  @override
  Future<void> releaseInFlight(Iterable<String> operationIds) async {
    final ids = operationIds.toSet();
    for (final row in _rows) {
      if (ids.contains(row.opId) &&
          row.status == PendingSyncOperationStatus.inflight) {
        row.status = PendingSyncOperationStatus.queued;
      }
    }
  }

  @override
  Future<void> markBlocked(String operationId, {required String error}) async {
    final row = _rows.singleWhere((item) => item.opId == operationId);
    if (row.status == PendingSyncOperationStatus.inflight) {
      row.status = PendingSyncOperationStatus.blocked;
      row.lastError = error;
    }
  }
}

final class _MutablePendingOperation {
  _MutablePendingOperation.from(PendingSyncOperation operation)
    : opId = operation.opId,
      localSeq = operation.localSeq,
      entity = operation.entity,
      entityId = operation.entityId,
      operation = operation.operation,
      payload = operation.payload,
      baseVersion = operation.baseVersion,
      attempts = operation.attempts,
      nextAttemptAt = operation.nextAttemptAt,
      lastError = operation.lastError,
      status = operation.status;

  final String opId;
  final int localSeq;
  final String entity;
  final String entityId;
  final String operation;
  final String payload;
  final int? baseVersion;
  int attempts;
  DateTime nextAttemptAt;
  String? lastError;
  PendingSyncOperationStatus status;

  PendingSyncOperation get value => PendingSyncOperation(
    opId: opId,
    localSeq: localSeq,
    entity: entity,
    entityId: entityId,
    operation: operation,
    payload: payload,
    baseVersion: baseVersion,
    attempts: attempts,
    nextAttemptAt: nextAttemptAt,
    lastError: lastError,
    status: status,
  );
}
