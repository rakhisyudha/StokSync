import 'dart:convert';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  group('sync protocol DTOs', () {
    test('serializes typed operations using the versioned wire contract', () {
      final request = _request();
      final encoded =
          jsonDecode(request.toJsonString()) as Map<String, dynamic>;

      expect(encoded['schema_version'], syncSchemaVersion);
      expect(encoded['device_id'], _deviceId);
      expect(encoded['cursor'], 1482);
      expect(encoded['max_changes'], 500);
      expect(encoded['client_time'], '2026-09-13T10:02:14.000Z');
      expect(encoded['ops'], hasLength(3));

      final movement = encoded['ops'][0] as Map<String, dynamic>;
      expect(movement['op'], 'add_movement');
      expect(movement['payload']['product_id'], _productId);
      expect(movement['payload']['delta'], -3);
      expect(movement['payload']['occurred_at'], '2026-09-13T09:41:02.000Z');
      expect(movement['payload'], isNot(contains('note')));

      final upsert = encoded['ops'][1] as Map<String, dynamic>;
      expect(upsert['base_version'], 7);
      expect(upsert['payload']['min_stock'], 24);

      final deletion = encoded['ops'][2] as Map<String, dynamic>;
      expect(deletion['base_version'], 7);
      expect(deletion['payload']['deleted_at'], '2026-09-13T10:02:14.000Z');

      final roundTrip = SyncRequest.fromJsonString(request.toJsonString());
      expect(roundTrip.deviceId, request.deviceId);
      expect(roundTrip.operations, hasLength(3));
      expect((roundTrip.operations[0].payload as AddMovementPayload).delta, -3);
    });

    test(
      'rejects unknown fields, malformed timestamps, and unsupported schema',
      () {
        final requestJson =
            jsonDecode(_request().toJsonString()) as Map<String, dynamic>;
        requestJson['unexpected'] = true;
        expect(
          () => SyncRequest.fromJsonString(jsonEncode(requestJson)),
          throwsA(isA<SyncProtocolException>()),
        );

        requestJson.remove('unexpected');
        requestJson['client_time'] = '2026-02-31T10:02:14Z';
        expect(
          () => SyncRequest.fromJsonString(jsonEncode(requestJson)),
          throwsA(isA<SyncProtocolException>()),
        );

        requestJson['client_time'] = '2026-09-13T10:02:14+01:00';
        expect(
          () => SyncRequest.fromJsonString(jsonEncode(requestJson)),
          throwsA(isA<SyncProtocolException>()),
        );

        requestJson['client_time'] = '2026-09-13T10:02:14Z';
        requestJson['device_id'] = '00000000-0000-0000-0000-000000000000';
        expect(
          () => SyncRequest.fromJsonString(jsonEncode(requestJson)),
          throwsA(isA<SyncProtocolException>()),
        );

        requestJson['device_id'] = _deviceId;
        requestJson['schema_version'] = 2;
        expect(
          () => SyncRequest.fromJsonString(jsonEncode(requestJson)),
          throwsA(isA<UnsupportedSchemaVersionException>()),
        );
      },
    );

    test('requires canonical versions only for product mutations', () {
      final movement = SyncOperation(
        opId: _operationId,
        kind: SyncOperationKind.addMovement,
        baseVersion: 1,
        payload: AddMovementPayload(
          id: _movementId,
          productId: _productId,
          delta: 1,
          kind: 'receive',
          occurredAt: DateTime.utc(2026, 9, 13, 10),
        ),
      );
      expect(() => movement.toJson(), throwsA(isA<SyncProtocolException>()));

      final deleteWithoutBase = <String, Object?>{
        'op_id': '0192f3a3-0000-7000-8000-000000000001',
        'op': 'delete_product',
        'payload': <String, Object?>{'id': _productId},
      };
      expect(
        () => SyncOperation.fromJson(deleteWithoutBase),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test('decodes complete responses and preserves rejection state safely', () {
      final response = SyncResponse(
        results: [
          const SyncOperationResult(
            opId: _operationId,
            status: SyncOperationResultStatus.applied,
            seq: 1483,
          ),
          const SyncOperationResult(
            opId: _secondOperationId,
            status: SyncOperationResultStatus.rejected,
            reason: 'version_conflict',
            serverState: <String, Object?>{'id': _productId, 'version': 9},
          ),
        ],
        changes: [
          const SyncChangeEntry(
            seq: 1483,
            entity: 'stock_movement',
            operation: 'upsert',
            data: <String, Object?>{'id': _movementId},
          ),
        ],
        nextCursor: 1483,
        hasMore: false,
        serverTime: DateTime.utc(2026, 9, 13, 10, 2, 15),
      );

      final decoded = SyncResponse.fromJsonString(response.toJsonString());
      expect(decoded.results[0].seq, 1483);
      expect(decoded.results[1].reason, 'version_conflict');
      expect(decoded.results[1].serverState?['version'], 9);
      expect(decoded.changes.single.seq, 1483);
      expect(decoded.serverTime, DateTime.utc(2026, 9, 13, 10, 2, 15));
    });

    test('rejects malformed response shape and non-ascending changes', () {
      expect(
        () => SyncResponse.fromJsonString('{}'),
        throwsA(isA<SyncProtocolException>()),
      );

      final response = <String, Object?>{
        'schema_version': syncSchemaVersion,
        'results': <Object?>[],
        'changes': [
          <String, Object?>{
            'seq': 4,
            'entity': 'product',
            'op': 'upsert',
            'data': <String, Object?>{},
          },
          <String, Object?>{
            'seq': 3,
            'entity': 'product',
            'op': 'upsert',
            'data': <String, Object?>{},
          },
        ],
        'next_cursor': 4,
        'has_more': false,
        'server_time': '2026-09-13T10:02:15Z',
      };
      expect(
        () => SyncResponse.fromJsonString(jsonEncode(response)),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test(
      'decodes strict error envelopes and requires schema negotiation data',
      () {
        final envelope = SyncErrorEnvelope.fromJsonString(
          '{"schema_version":1,"error":"unsupported_schema_version",'
          '"min_supported_version":1}',
        );
        expect(envelope.error, 'unsupported_schema_version');
        expect(envelope.minimumSupportedVersion, 1);
        expect(jsonDecode(envelope.toJsonString()), <String, dynamic>{
          'schema_version': 1,
          'error': 'unsupported_schema_version',
          'min_supported_version': 1,
        });

        expect(
          () => SyncErrorEnvelope.fromJsonString(
            '{"schema_version":1,"error":"unsupported_schema_version"}',
          ),
          throwsA(isA<SyncProtocolException>()),
        );
        expect(
          () => SyncErrorEnvelope.fromJsonString(
            '{"schema_version":1,"error":"unauthorized","extra":true}',
          ),
          throwsA(isA<SyncProtocolException>()),
        );
      },
    );
  });

  group('HTTP sync transport', () {
    test(
      'sends authenticated JSON and persists midpoint server offset',
      () async {
        final sender = _RecordingSender(
          SyncHttpResponse(
            statusCode: 200,
            body: utf8.encode(
              _responseJson(serverTime: '2026-09-13T10:02:15.500Z'),
            ),
          ),
        );
        final store = _MemoryClockOffsetStore();
        final times = <DateTime>[
          DateTime.utc(2026, 9, 13, 10, 2, 14),
          DateTime.utc(2026, 9, 13, 10, 2, 16),
        ];
        final transport = HttpSyncTransport(
          baseUri: Uri.parse(
            'https://example.test/api?access_token=must-not-be-retained',
          ),
          accessTokenProvider: () async => 'secret-access-token',
          sender: sender,
          clockOffsetStore: store,
          now: () => times.removeAt(0),
        );

        final response = await transport.synchronize(_request());

        expect(response.nextCursor, 1483);
        expect(sender.method, 'POST');
        expect(sender.uri!.path, '/api/v1/sync');
        expect(sender.uri!.query, isEmpty);
        expect(sender.headers!['Accept'], 'application/json');
        expect(sender.headers!['Content-Type'], 'application/json');
        expect(sender.headers!['Authorization'], 'Bearer secret-access-token');
        expect(jsonDecode(utf8.decode(sender.body!))['schema_version'], 1);
        expect(store.offsetMs, 500);
      },
    );

    test(
      'maps HTTP statuses without exposing bearer tokens or response bodies',
      () async {
        final cases = <int, SyncHttpErrorKind>{
          400: SyncHttpErrorKind.client,
          401: SyncHttpErrorKind.unauthorized,
          408: SyncHttpErrorKind.requestTimeout,
          429: SyncHttpErrorKind.rateLimited,
          503: SyncHttpErrorKind.server,
        };
        for (final entry in cases.entries) {
          final sender = _RecordingSender(
            SyncHttpResponse(
              statusCode: entry.key,
              body: utf8.encode(
                '{"schema_version":1,"error":"internal_error",'
                '"sensitive":"secret-access-token"}',
              ),
            ),
          );
          final transport = HttpSyncTransport(
            baseUri: Uri.parse(
              'https://example.test/v1?token=secret-access-token',
            ),
            accessTokenProvider: () async => 'secret-access-token',
            sender: sender,
          );

          try {
            await transport.synchronize(_request());
            fail('status ${entry.key} unexpectedly succeeded');
          } on SyncHttpException catch (error) {
            expect(error.statusCode, entry.key);
            expect(error.kind, entry.value);
            expect(error.toString(), isNot(contains('secret-access-token')));
            expect(error.toString(), isNot(contains('sensitive')));
            expect(error.toString(), isNot(contains('response')));
          }
        }
      },
    );

    test('does not call the sender without an access token', () async {
      final sender = _RecordingSender(
        SyncHttpResponse(statusCode: 200, body: utf8.encode('{}')),
      );
      final transport = HttpSyncTransport(
        baseUri: Uri.parse('https://example.test'),
        accessTokenProvider: () async => null,
        sender: sender,
      );

      expect(
        () => transport.synchronize(_request()),
        throwsA(isA<SyncAuthenticationException>()),
      );
      expect(sender.called, isFalse);
    });

    test(
      'redacts failures from token providers and injected senders',
      () async {
        final providerTransport = HttpSyncTransport(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => throw Exception('secret-token'),
          sender: _RecordingSender(
            SyncHttpResponse(statusCode: 200, body: utf8.encode('{}')),
          ),
        );
        expect(
          () => providerTransport.synchronize(_request()),
          throwsA(
            allOf(
              isA<SyncAuthenticationException>(),
              isNot(contains('secret-token')),
            ),
          ),
        );

        final senderTransport = HttpSyncTransport(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => 'secret-token',
          sender: _ThrowingSender(),
        );
        expect(
          () => senderTransport.synchronize(_request()),
          throwsA(
            allOf(isA<SyncNetworkException>(), isNot(contains('secret-token'))),
          ),
        );
      },
    );

    test('rejects malformed successful response bodies', () async {
      final transport = HttpSyncTransport(
        baseUri: Uri.parse('https://example.test'),
        accessTokenProvider: () async => 'token',
        sender: _RecordingSender(
          SyncHttpResponse(statusCode: 200, body: utf8.encode('{}')),
        ),
      );

      expect(
        () => transport.synchronize(_request()),
        throwsA(isA<SyncProtocolException>()),
      );
    });
  });

  group('server clock offset', () {
    test('calculates midpoint offset and applies persisted values', () async {
      final sent = DateTime.utc(2026, 9, 13, 10, 0);
      final received = sent.add(const Duration(seconds: 2));
      final server = sent.add(const Duration(seconds: 1, milliseconds: 250));
      final offset = ServerClockOffset.calculateMs(
        serverTime: server,
        requestSentAt: sent,
        responseReceivedAt: received,
      );
      expect(offset, 250);

      final store = _MemoryClockOffsetStore()..offsetMs = 250;
      expect(
        await ServerClockOffset.correctedNow(localTime: sent, store: store),
        sent.add(const Duration(milliseconds: 250)),
      );
    });
  });
}

const _deviceId = '0192f200-0000-7000-8000-000000000001';
const _operationId = '0192f3a1-0000-7000-8000-000000000001';
const _secondOperationId = '0192f3a2-0000-7000-8000-000000000001';
const _movementId = '0192f3a0-0000-7000-8000-000000000001';
const _productId = '0192e1aa-0000-7000-8000-000000000001';

SyncRequest _request() {
  return SyncRequest(
    deviceId: _deviceId,
    cursor: 1482,
    maxChanges: 500,
    clientTime: DateTime.utc(2026, 9, 13, 10, 2, 14),
    operations: [
      SyncOperation.addMovement(
        opId: _operationId,
        payload: AddMovementPayload(
          id: _movementId,
          productId: _productId,
          delta: -3,
          kind: 'issue',
          occurredAt: DateTime.utc(2026, 9, 13, 9, 41, 2),
        ),
      ),
      SyncOperation.upsertProduct(
        opId: _secondOperationId,
        baseVersion: 7,
        payload: const UpsertProductPayload(
          id: _productId,
          name: 'Indomie Goreng',
          unit: 'pcs',
          minStock: 24,
        ),
      ),
      SyncOperation.deleteProduct(
        opId: '0192f3a3-0000-7000-8000-000000000001',
        baseVersion: 7,
        payload: DeleteProductPayload(
          id: _productId,
          deletedAt: DateTime.utc(2026, 9, 13, 10, 2, 14),
        ),
      ),
    ],
  );
}

String _responseJson({required String serverTime}) {
  return jsonEncode(<String, Object?>{
    'schema_version': 1,
    'results': <Object?>[],
    'changes': <Object?>[],
    'next_cursor': 1483,
    'has_more': false,
    'server_time': serverTime,
  });
}

final class _RecordingSender implements SyncHttpRequestSender {
  _RecordingSender(this.response);

  final SyncHttpResponse response;
  bool called = false;
  String? method;
  Uri? uri;
  Map<String, String>? headers;
  List<int>? body;

  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    called = true;
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    this.body = body;
    return response;
  }
}

final class _MemoryClockOffsetStore implements ServerClockOffsetStore {
  int? offsetMs;

  @override
  Future<int?> readOffsetMs() async => offsetMs;

  @override
  Future<void> writeOffsetMs(int offsetMs) async {
    this.offsetMs = offsetMs;
  }
}

final class _ThrowingSender implements SyncHttpRequestSender {
  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) {
    throw Exception('secret-token');
  }
}
