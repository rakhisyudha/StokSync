import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'errors.dart';

/// The action the sync engine should take after a failed exchange.
enum SyncRetryDisposition {
  /// Keep the operation eligible and schedule another attempt.
  retryable,

  /// Keep the operation queued, but do not retry until the sync blocker is
  /// resolved (for example, authentication or a schema mismatch).
  blocked,

  /// Stop automatic retries for the operation. The local queue retains the
  /// row so a later reconciliation layer can record an inspectable error.
  terminal,
}

/// A classified sync failure with a stable, non-sensitive reason code.
final class SyncRetryClassification {
  const SyncRetryClassification({
    required this.disposition,
    required this.reason,
  });

  final SyncRetryDisposition disposition;
  final String reason;
}

/// Classifies transport and protocol failures without inspecting arbitrary
/// exception text (which could contain credentials or request payloads).
final class SyncRetryClassifier {
  const SyncRetryClassifier._();

  static SyncRetryClassification classify(Object error) {
    if (error is SyncNetworkException ||
        error is TimeoutException ||
        error is SocketException) {
      return const SyncRetryClassification(
        disposition: SyncRetryDisposition.retryable,
        reason: 'network_unreachable',
      );
    }

    if (error is SyncClockOffsetException) {
      return const SyncRetryClassification(
        disposition: SyncRetryDisposition.retryable,
        reason: 'clock_offset_persistence',
      );
    }

    if (error is SyncAuthenticationException) {
      return const SyncRetryClassification(
        disposition: SyncRetryDisposition.blocked,
        reason: 'authentication_required',
      );
    }

    if (error is UnsupportedSchemaVersionException) {
      return const SyncRetryClassification(
        disposition: SyncRetryDisposition.blocked,
        reason: 'unsupported_schema',
      );
    }

    if (error is SyncHttpException) {
      return switch (error.kind) {
        SyncHttpErrorKind.requestTimeout => const SyncRetryClassification(
          disposition: SyncRetryDisposition.retryable,
          reason: 'request_timeout',
        ),
        SyncHttpErrorKind.rateLimited => const SyncRetryClassification(
          disposition: SyncRetryDisposition.retryable,
          reason: 'rate_limited',
        ),
        SyncHttpErrorKind.server => const SyncRetryClassification(
          disposition: SyncRetryDisposition.retryable,
          reason: 'server_error',
        ),
        SyncHttpErrorKind.unauthorized => const SyncRetryClassification(
          disposition: SyncRetryDisposition.blocked,
          reason: 'unauthorized',
        ),
        SyncHttpErrorKind.forbidden => const SyncRetryClassification(
          disposition: SyncRetryDisposition.blocked,
          reason: 'forbidden',
        ),
        SyncHttpErrorKind.client => const SyncRetryClassification(
          disposition: SyncRetryDisposition.terminal,
          reason: 'client_error',
        ),
        SyncHttpErrorKind.unexpected => const SyncRetryClassification(
          disposition: SyncRetryDisposition.terminal,
          reason: 'unexpected_http_status',
        ),
      };
    }

    if (error is SyncProtocolException) {
      return const SyncRetryClassification(
        disposition: SyncRetryDisposition.terminal,
        reason: 'protocol_error',
      );
    }

    return const SyncRetryClassification(
      disposition: SyncRetryDisposition.terminal,
      reason: 'unknown_error',
    );
  }
}

/// Classifies a failure using the same policy as [SyncRetryClassifier].
SyncRetryClassification classifySyncFailure(Object error) {
  return SyncRetryClassifier.classify(error);
}

/// Capped exponential delay with bounded multiplicative jitter.
///
/// [attempt] is one-based: the first retry uses the base delay. The jitter
/// sample is in the inclusive range 0..1 and is injectable for deterministic
/// tests. The default policy is 1 second through a 5 minute cap with ±20%
/// jitter.
final class SyncBackoffPolicy {
  SyncBackoffPolicy({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(minutes: 5),
    this.jitterRatio = 0.2,
    Random? random,
  }) : _random = random ?? Random() {
    if (baseDelay <= Duration.zero) {
      throw ArgumentError.value(
        baseDelay,
        'baseDelay',
        'must be greater than zero',
      );
    }
    if (maxDelay < baseDelay) {
      throw ArgumentError.value(
        maxDelay,
        'maxDelay',
        'must not be less than baseDelay',
      );
    }
    if (jitterRatio < 0 || jitterRatio > 1) {
      throw ArgumentError.value(
        jitterRatio,
        'jitterRatio',
        'must be between zero and one',
      );
    }
  }

  final Duration baseDelay;
  final Duration maxDelay;
  final double jitterRatio;
  final Random _random;

  /// Returns a delay for a one-based retry attempt.
  Duration delayForAttempt(int attempt, {double? jitterSample}) {
    if (attempt <= 0) {
      throw ArgumentError.value(attempt, 'attempt', 'must be positive');
    }

    final sample = jitterSample ?? _random.nextDouble();
    if (sample < 0 || sample > 1) {
      throw ArgumentError.value(
        sample,
        'jitterSample',
        'must be between zero and one',
      );
    }

    var exponentialMicros = baseDelay.inMicroseconds.toDouble();
    final capMicros = maxDelay.inMicroseconds.toDouble();
    for (var index = 1; index < attempt; index++) {
      if (exponentialMicros >= capMicros) {
        exponentialMicros = capMicros;
        break;
      }
      exponentialMicros = min(exponentialMicros * 2, capMicros);
    }

    final jitterMultiplier = 1 - jitterRatio + (2 * jitterRatio * sample);
    final jitteredMicros = min(
      capMicros,
      max(0, exponentialMicros * jitterMultiplier),
    );
    return Duration(microseconds: jitteredMicros.round());
  }

  /// Alias that reads naturally at call sites calculating a retry delay.
  Duration delayFor(int attempt, {double? jitterSample}) {
    return delayForAttempt(attempt, jitterSample: jitterSample);
  }
}
