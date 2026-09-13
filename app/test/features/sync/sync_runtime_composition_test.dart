import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/data/local/stoksync_database.dart';
import 'package:stoksync/features/sync/sync_runtime_composition.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  test(
    'uses one session manager for authenticated health and sync engine calls',
    () async {
      final database = StokSyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final sender = _RecordingSender();
      final runtime = AuthenticatedSyncRuntime(
        database: database,
        baseUri: Uri.parse('https://example.test'),
        deviceId: _deviceId,
        sessionStore: _MemorySessionStore(_session),
        sender: sender,
        refresher: _UnusedRefresher(),
      );

      expect(await runtime.reachability.check(), isTrue);
      final cycle = await runtime.engine.synchronize();

      expect(cycle, isNotNull);
      expect(sender.calls.map((call) => call.method), ['GET', 'POST']);
      expect(sender.calls.map((call) => call.headers['Authorization']), [
        'Bearer access-token',
        'Bearer access-token',
      ]);
      expect(runtime.transport, isA<HttpSyncTransport>());
      expect(runtime.sessionManager, isA<SyncSessionManager>());

      final state = await (database.select(
        database.syncState,
      )..where((row) => row.id.equals(1))).getSingle();
      expect(state.status, 'idle');
      expect(state.cursor, 0);
    },
  );
}

const _deviceId = '0192f200-0000-7000-8000-000000000002';

final _session = SyncSession(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  userId: '0192f200-0000-7000-8000-000000000001',
  deviceId: _deviceId,
  accessTokenExpiresAt: DateTime.utc(2026, 9, 13, 10, 17, 14),
);

final class _MemorySessionStore implements SyncSessionStore {
  _MemorySessionStore(this.session);

  final SyncSession session;

  @override
  Future<SyncSession?> readSession() async => session;

  @override
  Future<void> writeSession(SyncSession session) async {}
}

final class _UnusedRefresher implements SyncSessionRefresher {
  @override
  Future<SyncSession> refresh(String refreshToken) {
    throw StateError('refresh should not be called in this test');
  }
}

final class _RecordingSender implements SyncHttpRequestSender {
  final List<_Call> calls = <_Call>[];

  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    calls.add(_Call(method: method, headers: headers));
    if (method == 'GET') {
      return SyncHttpResponse(statusCode: 200, body: utf8.encode('{}'));
    }
    final response = SyncResponse(
      results: const <SyncOperationResult>[],
      changes: const <SyncChangeEntry>[],
      nextCursor: 0,
      hasMore: false,
      serverTime: DateTime.utc(2026, 9, 13, 10, 2, 15),
    );
    return SyncHttpResponse(
      statusCode: 200,
      body: utf8.encode(response.toJsonString()),
    );
  }
}

final class _Call {
  const _Call({required this.method, required this.headers});

  final String method;
  final Map<String, String> headers;
}
