/// Typed failures raised by the synchronization protocol and transport.
library;

enum SyncProtocolErrorKind {
  malformedJson,
  invalidValue,
  unsupportedSchema,
  invalidRequest,
  invalidResponse,
  invalidErrorEnvelope,
}

/// Raised when a JSON value does not satisfy the versioned sync contract.
class SyncProtocolException implements Exception {
  const SyncProtocolException(this.kind, this.message, {this.field});

  final SyncProtocolErrorKind kind;
  final String message;
  final String? field;

  @override
  String toString() {
    final fieldSuffix = field == null ? '' : ' (${field!})';
    return 'SyncProtocolException$fieldSuffix: $message';
  }
}

/// Raised when a peer speaks a schema version that this client cannot read.
final class UnsupportedSchemaVersionException extends SyncProtocolException {
  UnsupportedSchemaVersionException({
    required this.receivedVersion,
    required this.minimumSupportedVersion,
  }) : super(
         SyncProtocolErrorKind.unsupportedSchema,
         'schema version is not supported',
         field: 'schema_version',
       );

  final int receivedVersion;
  final int minimumSupportedVersion;
}

/// Base class for failures while sending or receiving a sync exchange.
abstract class SyncTransportException implements Exception {
  const SyncTransportException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Raised when the network request cannot obtain an HTTP response.
final class SyncNetworkException extends SyncTransportException {
  const SyncNetworkException()
    : super('sync request could not reach the server');
}

/// Raised when no usable bearer token is available for an authenticated call.
final class SyncAuthenticationException extends SyncTransportException {
  const SyncAuthenticationException()
    : super('an access token is required for synchronization');
}

/// Raised when an HTTP response cannot be interpreted as a sync error or body.
final class SyncHttpException extends SyncTransportException {
  const SyncHttpException({
    required this.statusCode,
    required this.kind,
    this.errorCode,
    this.minimumSupportedVersion,
    this.endpoint,
  }) : super('sync HTTP request failed');

  final int statusCode;
  final SyncHttpErrorKind kind;
  final String? errorCode;
  final int? minimumSupportedVersion;

  /// A sanitized endpoint containing no query, fragment, credentials, or
  /// authorization data.
  final String? endpoint;

  @override
  String toString() {
    final endpointSuffix = endpoint == null ? '' : ', endpoint: $endpoint';
    return 'SyncHttpException(status: $statusCode, kind: ${kind.name}'
        '$endpointSuffix)';
  }
}

enum SyncHttpErrorKind {
  unauthorized,
  forbidden,
  requestTimeout,
  rateLimited,
  client,
  server,
  unexpected,
}

/// Raised when a valid response cannot be persisted to the clock store.
final class SyncClockOffsetException extends SyncTransportException {
  const SyncClockOffsetException()
    : super('server clock offset could not be persisted');
}
