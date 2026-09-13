import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/features/sync/sync_reachability.dart';
import 'package:sync_engine/sync_engine.dart';

void main() {
  group('AuthenticatedHealthReachability', () {
    test('sends an authenticated health request and accepts 2xx', () async {
      final sender = _RecordingSender(
        SyncHttpResponse(statusCode: 200, body: <int>[]),
      );
      final probe = AuthenticatedHealthReachability(
        baseUri: Uri.parse(
          'https://example.test/api/v1/sync?token=must-not-be-retained',
        ),
        accessTokenProvider: () async => 'access-token',
        sender: sender,
      );

      expect(await probe.check(), isTrue);
      expect(sender.method, 'GET');
      expect(sender.uri?.path, '/api/v1/health');
      expect(sender.uri?.query, isEmpty);
      expect(sender.headers?['Accept'], 'application/json');
      expect(sender.headers?['Authorization'], 'Bearer access-token');
      expect(sender.body, isEmpty);
    });

    test(
      'treats missing token, failures, and non-2xx as unreachable',
      () async {
        final missingTokenSender = _RecordingSender(
          SyncHttpResponse(statusCode: 200, body: <int>[]),
        );
        final missingTokenProbe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => null,
          sender: missingTokenSender,
        );
        expect(await missingTokenProbe.check(), isFalse);
        expect(missingTokenSender.called, isFalse);

        final serverFailureProbe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => 'token',
          sender: _RecordingSender(
            SyncHttpResponse(statusCode: 503, body: <int>[]),
          ),
        );
        expect(await serverFailureProbe.check(), isFalse);

        final networkFailureProbe = AuthenticatedHealthReachability(
          baseUri: Uri.parse('https://example.test'),
          accessTokenProvider: () async => 'token',
          sender: _ThrowingSender(),
        );
        expect(await networkFailureProbe.check(), isFalse);
      },
    );
  });
}

final class _RecordingSender implements SyncHttpRequestSender {
  _RecordingSender(this.response);

  final SyncHttpResponse response;
  var called = false;
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

final class _ThrowingSender implements SyncHttpRequestSender {
  @override
  Future<SyncHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
  }) {
    throw const SyncNetworkException();
  }
}
