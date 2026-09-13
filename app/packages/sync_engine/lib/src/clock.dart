/// Durable storage for the rolling server-minus-device clock offset.
abstract interface class ServerClockOffsetStore {
  Future<int?> readOffsetMs();

  Future<void> writeOffsetMs(int offsetMs);
}

/// Calculates and applies the offset learned from a sync response.
final class ServerClockOffset {
  const ServerClockOffset._();

  /// Computes `server_time - local_midpoint` in milliseconds.
  ///
  /// Using the midpoint between request send and response receive reduces the
  /// one-way network latency bias without requiring a second clock exchange.
  static int calculateMs({
    required DateTime serverTime,
    required DateTime requestSentAt,
    required DateTime responseReceivedAt,
  }) {
    final sent = requestSentAt.toUtc();
    final received = responseReceivedAt.toUtc();
    final elapsedMicros = received.difference(sent).inMicroseconds;
    final midpoint = sent.add(Duration(microseconds: elapsedMicros ~/ 2));
    final offsetMicros = serverTime.toUtc().difference(midpoint).inMicroseconds;
    return (offsetMicros / Duration.microsecondsPerMillisecond).round();
  }

  static DateTime apply(DateTime localTime, int offsetMs) {
    return localTime.toUtc().add(Duration(milliseconds: offsetMs));
  }

  static Future<DateTime> correctedNow({
    required DateTime localTime,
    required ServerClockOffsetStore store,
  }) async {
    final offsetMs = await store.readOffsetMs() ?? 0;
    return apply(localTime, offsetMs);
  }
}
