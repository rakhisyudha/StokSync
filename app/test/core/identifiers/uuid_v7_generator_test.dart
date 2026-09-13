import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stoksync/core/identifiers/uuid_v7_generator.dart';

void main() {
  group('UuidV7Generator', () {
    test('encodes the Unix millisecond timestamp and RFC version fields', () {
      const timestamp = 1726221734000;
      final generator = UuidV7Generator(
        millisecondsSinceEpoch: () => timestamp,
        randomBytesSource: _FixedRandomBytes(List<int>.filled(10, 0)),
      );

      final identifier = generator.generate();

      expect(identifier, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7')));
      expect(identifier.substring(19, 20), anyOf('8', '9', 'a', 'b'));
      expect(UuidV7.isValid(identifier), isTrue);
      expect(UuidV7.timestampMilliseconds(identifier), timestamp);
    });

    test(
      'is strictly time-sortable for repeated and regressing clock values',
      () {
        var timestamp = 1726221734000;
        final generator = UuidV7Generator(
          millisecondsSinceEpoch: () => timestamp,
          randomBytesSource: _FixedRandomBytes(List<int>.filled(10, 0)),
        );

        final identifiers = <String>[
          generator.generate(),
          generator.generate(),
        ];
        timestamp -= 1000;
        identifiers.add(generator.generate());
        timestamp += 2000;
        identifiers.add(generator.generate());

        final sorted = [...identifiers]..sort();
        expect(identifiers, orderedEquals(sorted));
        expect(identifiers.toSet(), hasLength(identifiers.length));
        expect(UuidV7.timestampMilliseconds(identifiers[0]), 1726221734000);
        expect(UuidV7.timestampMilliseconds(identifiers[1]), 1726221734000);
        expect(UuidV7.timestampMilliseconds(identifiers[2]), 1726221734000);
        expect(UuidV7.timestampMilliseconds(identifiers[3]), 1726221735000);
      },
    );

    test(
      'maintains UUIDv7 invariants for varied timestamp and entropy samples',
      () {
        final entropy = Random(42);

        for (var index = 0; index < 256; index++) {
          final timestamp = 1700000000000 + entropy.nextInt(1000000000);
          final randomBytes = List<int>.generate(
            10,
            (_) => entropy.nextInt(256),
          );
          final generator = UuidV7Generator(
            millisecondsSinceEpoch: () => timestamp,
            randomBytesSource: _FixedRandomBytes(randomBytes),
          );

          final identifier = generator.generate();

          expect(UuidV7.isValid(identifier), isTrue, reason: identifier);
          expect(UuidV7.timestampMilliseconds(identifier), timestamp);
        }
      },
    );

    test('advances the logical timestamp when random bits are exhausted', () {
      const timestamp = 1726221734000;
      final generator = UuidV7Generator(
        millisecondsSinceEpoch: () => timestamp,
        randomBytesSource: _FixedRandomBytes(List<int>.filled(10, 0xff)),
      );

      final first = generator.generate();
      final second = generator.generate();

      expect(second.compareTo(first), greaterThan(0));
      expect(UuidV7.timestampMilliseconds(second), timestamp + 1);
      expect(UuidV7.isValid(second), isTrue);
    });

    test('rejects timestamps outside the UUIDv7 48-bit range', () {
      final generator = UuidV7Generator(
        millisecondsSinceEpoch: () => -1,
        randomBytesSource: _FixedRandomBytes(List<int>.filled(10, 0)),
      );

      expect(generator.generate, throwsArgumentError);
    });
  });
}

final class _FixedRandomBytes implements RandomBytesSource {
  _FixedRandomBytes(this._bytes);

  final List<int> _bytes;

  @override
  Uint8List nextBytes(int length) {
    if (length != _bytes.length) {
      throw StateError('Unexpected random-byte request length: $length');
    }
    return Uint8List.fromList(_bytes);
  }
}
