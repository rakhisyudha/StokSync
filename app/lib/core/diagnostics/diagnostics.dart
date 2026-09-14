import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Writes one already-serialized diagnostic event.
typedef DiagnosticWriter = void Function(String line);

/// Emits small structured client events without accepting raw credentials,
/// tokens, request bodies, headers, or arbitrary exception text.
final class AppDiagnostics {
  const AppDiagnostics({DiagnosticWriter? writer})
    : _writer = writer ?? _defaultWriter;

  final DiagnosticWriter _writer;

  /// Writes an event as one JSON object. Writer failures are ignored so
  /// diagnostics can never change authentication or synchronization behavior.
  void event(String name, {Map<String, Object?> fields = const {}}) {
    final safeFields = sanitizeFields(fields);
    final payload = <String, Object?>{
      'event': _safeEventName(name),
      ...safeFields,
    };
    try {
      _writer(jsonEncode(payload));
    } on Object {
      // Logging is best effort and must not interfere with domain behavior.
    }
  }

  /// Sanitizes a field map for tests and for callers that need to inspect the
  /// exact safe representation without writing an event.
  static Map<String, Object?> sanitizeFields(Map<String, Object?> fields) {
    return <String, Object?>{
      for (final entry in fields.entries)
        entry.key: _sanitizeValue(entry.key, entry.value),
    };
  }

  static Object? _sanitizeValue(String key, Object? value) {
    if (_isSensitiveKey(key)) {
      return '[REDACTED]';
    }
    if (value == null || value is num || value is bool) {
      return value;
    }
    if (value is String) {
      if (_isErrorKey(key)) {
        return value.runtimeType.toString();
      }
      return _redactString(value);
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _sanitizeValue(
            entry.key.toString(),
            entry.value,
          ),
      };
    }
    if (value is Iterable) {
      return value.map((item) => _sanitizeValue('value', item)).toList();
    }
    return value.runtimeType.toString();
  }

  static bool _isErrorKey(String key) {
    final normalized = _normalizeKey(key);
    return normalized == 'error' ||
        normalized == 'exception' ||
        normalized == 'stack_trace';
  }

  static bool _isSensitiveKey(String key) {
    final normalized = _normalizeKey(key);
    switch (normalized) {
      case 'password':
      case 'passwd':
      case 'access_token':
      case 'refresh_token':
      case 'token':
      case 'authorization':
      case 'bearer':
      case 'secret':
      case 'cookie':
      case 'set_cookie':
      case 'payload':
      case 'body':
      case 'request':
      case 'response':
      case 'request_body':
      case 'response_body':
      case 'headers':
      case 'request_headers':
      case 'response_headers':
      case 'email':
        return true;
      default:
        return normalized.contains('password') ||
            normalized.contains('token') ||
            normalized.contains('authorization') ||
            normalized.contains('secret') ||
            normalized.contains('payload');
    }
  }

  static String _normalizeKey(String key) {
    return key.trim().toLowerCase().replaceAll('-', '_').replaceAll('.', '_');
  }

  static String _redactString(String value) {
    final credentialPattern = RegExp(
      r"""(password|passwd|access[_-]?token|refresh[_-]?token|authorization|bearer|secret)\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;}]+)""",
      caseSensitive: false,
    );
    final bearerPattern = RegExp(r'(bearer\s+)[^\s,;}]+', caseSensitive: false);
    return value
        .replaceAllMapped(
          credentialPattern,
          (match) => '${match.group(1)}=[REDACTED]',
        )
        .replaceAllMapped(
          bearerPattern,
          (match) => '${match.group(1)}[REDACTED]',
        );
  }

  static String _safeEventName(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return 'client.event';
    }
    return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
  }
}

void _defaultWriter(String line) {
  if (kDebugMode) {
    debugPrint(line);
  }
}
