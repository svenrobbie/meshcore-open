import 'dart:typed_data';

import '../models/test_mode_config.dart';

enum TestPathParseError {
  invalidHex,
  tooLong,
  notDivisibleByHashSize,
  tooManyHops,
}

class TestPathParseResult {
  final Uint8List bytes;
  final TestPathParseError? error;

  const TestPathParseResult(this.bytes, this.error);

  bool get isValid => error == null;
}

/// Parses a free-form hex path ("12 34 ab", "0x12,0x34", "1234").
///
/// Empty input is valid and means flood.
TestPathParseResult parseTestPathHex(String input, {required int hashSize}) {
  final cleaned = input
      .replaceAll(RegExp('0[xX]'), '')
      .replaceAll(RegExp(r'[\s,;:_-]'), '');
  if (cleaned.isEmpty) {
    return TestPathParseResult(Uint8List(0), null);
  }
  if (cleaned.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned)) {
    return TestPathParseResult(Uint8List(0), TestPathParseError.invalidHex);
  }

  final bytes = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byte = int.tryParse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      return TestPathParseResult(Uint8List(0), TestPathParseError.invalidHex);
    }
    bytes[i] = byte;
  }

  if (bytes.length > testModeMaxPathBytes) {
    return TestPathParseResult(bytes, TestPathParseError.tooLong);
  }
  if (hashSize < testModeHashSizeMin || hashSize > testModeHashSizeMax) {
    return TestPathParseResult(
      bytes,
      TestPathParseError.notDivisibleByHashSize,
    );
  }
  if (bytes.length % hashSize != 0) {
    return TestPathParseResult(
      bytes,
      TestPathParseError.notDivisibleByHashSize,
    );
  }
  if (bytes.length ~/ hashSize > testModeMaxHops) {
    return TestPathParseResult(bytes, TestPathParseError.tooManyHops);
  }
  return TestPathParseResult(bytes, null);
}

/// Formats raw path bytes as lowercase space-separated hex, e.g. "12 34 ab".
String formatTestPathHex(Uint8List bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
}
