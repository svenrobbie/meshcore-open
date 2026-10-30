import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/test_message_generator.dart';
import 'package:meshcore_open/utils/test_mode_input.dart';

void main() {
  group('parseTestPathHex', () {
    test('empty input means flood', () {
      final result = parseTestPathHex('', hashSize: 1);
      expect(result.isValid, isTrue);
      expect(result.bytes, isEmpty);
    });

    test('accepts spaces, commas, colons and 0x prefixes', () {
      for (final input in [
        '12 34 ab cd',
        '12,34,ab,cd',
        '12:34:AB:CD',
        '0x12 0x34 0xAB 0xCD',
      ]) {
        final result = parseTestPathHex(input, hashSize: 2);
        expect(result.isValid, isTrue, reason: input);
        expect(result.bytes, [0x12, 0x34, 0xAB, 0xCD]);
      }
    });

    test('rejects incomplete and non-hex input', () {
      expect(
        parseTestPathHex('1', hashSize: 1).error,
        TestPathParseError.invalidHex,
      );
      expect(
        parseTestPathHex('12 3g', hashSize: 1).error,
        TestPathParseError.invalidHex,
      );
    });

    test('rejects paths longer than 64 bytes', () {
      final result = parseTestPathHex(
        List.filled(66, 'aa').join(' '),
        hashSize: 1,
      );
      expect(result.error, TestPathParseError.tooLong);
    });

    test('rejects paths that do not fit the short-ID size', () {
      expect(
        parseTestPathHex('12 34 56', hashSize: 2).error,
        TestPathParseError.notDivisibleByHashSize,
      );
      expect(parseTestPathHex('12 34 56 78', hashSize: 2).isValid, isTrue);
    });

    test('rejects more than 63 hops', () {
      expect(
        parseTestPathHex(List.filled(64, 'aa').join(' '), hashSize: 1).error,
        TestPathParseError.tooManyHops,
      );
      expect(
        parseTestPathHex(List.filled(64, 'aa').join(' '), hashSize: 2).isValid,
        isTrue,
      );
    });
  });

  group('formatTestPathHex', () {
    test('uses lowercase space-separated bytes', () {
      expect(
        formatTestPathHex(Uint8List.fromList([0x01, 0xAB, 0xFF])),
        '01 ab ff',
      );
    });

    test('round-trips through the parser', () {
      final bytes = Uint8List.fromList([0x00, 0x7F, 0x80, 0xFF]);
      final parsed = parseTestPathHex(formatTestPathHex(bytes), hashSize: 2);
      expect(parsed.bytes, bytes);
    });
  });

  group('random test packets', () {
    test('messages are two words plus a four-digit number', () {
      final random = Random(7);
      final pattern = RegExp(r'^[a-z]+ [a-z]+ [1-9]\d{3}$');
      final seen = <String>{};
      for (var i = 0; i < 20; i++) {
        final text = randomTestMessage(random);
        expect(pattern.hasMatch(text), isTrue, reason: text);
        seen.add(text);
      }
      expect(seen.length, greaterThan(1));
    });

    test('random paths keep their length', () {
      final random = Random(11);
      final template = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final path = randomTestPath(template, random);
      expect(path, hasLength(template.length));
      expect(path, isNot(template));
    });

    test('an empty template stays a flood', () {
      final path = randomTestPath(Uint8List(0), Random(3));
      expect(path, isEmpty);
    });
  });
}
