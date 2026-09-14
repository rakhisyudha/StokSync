import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/diagnostics/diagnostics.dart';

void main() {
  test('redacts credentials, tokens, headers, payloads, and error text', () {
    final fields = AppDiagnostics.sanitizeFields(<String, Object?>{
      'password': 'raw-password',
      'access_token': 'access-token',
      'refresh_token': 'refresh-token',
      'authorization': 'Bearer access-token',
      'payload': <String, Object?>{
        'password': 'nested-password',
        'note': 'sensitive full payload',
      },
      'error': 'database password=error-secret',
      'safe_count': 3,
      'message': 'request failed with bearer header-token',
    });

    expect(fields['password'], '[REDACTED]');
    expect(fields['access_token'], '[REDACTED]');
    expect(fields['refresh_token'], '[REDACTED]');
    expect(fields['authorization'], '[REDACTED]');
    expect(fields['payload'], '[REDACTED]');
    expect(fields['error'], 'String');
    expect(fields['safe_count'], 3);
    expect(fields['message'], 'request failed with bearer [REDACTED]');
    expect(jsonEncode(fields), isNot(contains('raw-password')));
    expect(jsonEncode(fields), isNot(contains('access-token')));
    expect(jsonEncode(fields), isNot(contains('refresh-token')));
    expect(jsonEncode(fields), isNot(contains('error-secret')));
  });

  test('writes structured safe events and tolerates writer failures', () {
    final lines = <String>[];
    final diagnostics = AppDiagnostics(writer: lines.add);

    diagnostics.event(
      'sync.trigger',
      fields: const <String, Object?>{
        'outcome': 'completed',
        'operation_count': 2,
        'token': 'must-not-appear',
      },
    );

    expect(lines, hasLength(1));
    final decoded = jsonDecode(lines.single) as Map<String, Object?>;
    expect(decoded['event'], 'sync.trigger');
    expect(decoded['outcome'], 'completed');
    expect(decoded['operation_count'], 2);
    expect(decoded['token'], '[REDACTED]');
    expect(lines.single, isNot(contains('must-not-appear')));

    AppDiagnostics(
      writer: (_) => throw StateError('writer failure'),
    ).event('sync.trigger');
  });
}
