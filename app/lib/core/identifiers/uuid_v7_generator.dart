import 'dart:math';
import 'dart:typed_data';

/// Generates identifiers for locally created products, movements, and
/// synchronization operations.
abstract interface class IdentifierGenerator {
  String generate();
}

/// Supplies cryptographically secure random bytes to [UuidV7Generator].
abstract interface class RandomBytesSource {
  Uint8List nextBytes(int length);
}

/// A [RandomBytesSource] backed by Dart's platform secure random source.
final class SecureRandomBytesSource implements RandomBytesSource {
  SecureRandomBytesSource({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  Uint8List nextBytes(int length) {
    return Uint8List.fromList(
      List<int>.generate(length, (_) => _random.nextInt(256)),
    );
  }
}

/// Utilities for canonical RFC 9562 UUIDv7 strings.
final class UuidV7 {
  UuidV7._();

  static final RegExp _canonicalPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-7[0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  /// Whether [value] is a canonical UUIDv7 string with the RFC variant bits.
  static bool isValid(String value) => _canonicalPattern.hasMatch(value);

  /// Returns the 48-bit Unix-epoch millisecond timestamp embedded in [value].
  ///
  /// Returns `null` when [value] is not a canonical UUIDv7.
  static int? timestampMilliseconds(String value) {
    if (!isValid(value)) {
      return null;
    }

    final compact = value.replaceAll('-', '');
    return int.parse(compact.substring(0, 12), radix: 16);
  }
}

/// Generates RFC 9562 UUIDv7 values using Unix-epoch milliseconds and secure
/// random bits. Values from one generator are strictly lexicographically
/// ordered, including calls in the same millisecond or after a clock rollback.
final class UuidV7Generator implements IdentifierGenerator {
  UuidV7Generator({
    int Function()? millisecondsSinceEpoch,
    RandomBytesSource? randomBytesSource,
  }) : _millisecondsSinceEpoch =
           millisecondsSinceEpoch ??
           (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _randomBytesSource = randomBytesSource ?? SecureRandomBytesSource();

  static const int _maximumTimestampMilliseconds = 0xffffffffffff;

  final int Function() _millisecondsSinceEpoch;
  final RandomBytesSource _randomBytesSource;

  int? _lastTimestampMilliseconds;
  Uint8List? _lastBytes;

  @override
  String generate() {
    final now = _millisecondsSinceEpoch();
    if (now < 0 || now > _maximumTimestampMilliseconds) {
      throw ArgumentError.value(
        now,
        'millisecondsSinceEpoch',
        'must fit in UUIDv7\'s unsigned 48-bit timestamp',
      );
    }

    final previousTimestamp = _lastTimestampMilliseconds;
    final previousBytes = _lastBytes;
    if (previousTimestamp == null ||
        previousBytes == null ||
        now > previousTimestamp) {
      _lastTimestampMilliseconds = now;
      _lastBytes = _newUuidBytes(now);
      return _toCanonicalString(_lastBytes!);
    }

    final nextBytes = Uint8List.fromList(previousBytes);
    if (_incrementRandomBits(nextBytes)) {
      _lastBytes = nextBytes;
      return _toCanonicalString(nextBytes);
    }

    if (previousTimestamp == _maximumTimestampMilliseconds) {
      throw StateError('UUIDv7 timestamp and random space are exhausted');
    }

    _lastTimestampMilliseconds = previousTimestamp + 1;
    _lastBytes = _newUuidBytes(_lastTimestampMilliseconds!);
    return _toCanonicalString(_lastBytes!);
  }

  Uint8List _newUuidBytes(int timestampMilliseconds) {
    final randomBytes = _randomBytesSource.nextBytes(10);
    if (randomBytes.length != 10) {
      throw StateError('UUIDv7 random source must return exactly 10 bytes');
    }

    final bytes = Uint8List(16);
    var timestamp = timestampMilliseconds;
    for (var index = 5; index >= 0; index--) {
      bytes[index] = timestamp & 0xff;
      timestamp >>= 8;
    }

    bytes.setRange(6, 16, randomBytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes;
  }

  /// Increments the 74 random bits while preserving UUIDv7 version and variant
  /// fields. Returns `false` only when every random bit is already set.
  bool _incrementRandomBits(Uint8List bytes) {
    for (var index = 15; index >= 9; index--) {
      if (bytes[index] != 0xff) {
        bytes[index]++;
        return true;
      }
      bytes[index] = 0;
    }

    final randomByteEight = bytes[8] & 0x3f;
    if (randomByteEight != 0x3f) {
      bytes[8] = 0x80 | (randomByteEight + 1);
      return true;
    }
    bytes[8] = 0x80;

    if (bytes[7] != 0xff) {
      bytes[7]++;
      return true;
    }
    bytes[7] = 0;

    final randomNibbleSix = bytes[6] & 0x0f;
    if (randomNibbleSix != 0x0f) {
      bytes[6] = 0x70 | (randomNibbleSix + 1);
      return true;
    }
    bytes[6] = 0x70;
    return false;
  }

  String _toCanonicalString(Uint8List bytes) {
    final compact = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${compact.substring(0, 8)}-${compact.substring(8, 12)}-'
        '${compact.substring(12, 16)}-${compact.substring(16, 20)}-'
        '${compact.substring(20)}';
  }
}
