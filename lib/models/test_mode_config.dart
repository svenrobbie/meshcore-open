import 'dart:typed_data';

/// RAM-only configuration for the companion firmware's test mode.
///
/// The radio keeps this in memory only: every reboot starts disabled with an
/// empty path and an unscoped (all-zero) region key.
class TestModeConfig {
  final bool enabled;

  /// Bytes per path hop: 1, 2 or 3.
  final int hashSize;

  /// Raw hop bytes. Empty means the packet is sent as a flood.
  final Uint8List pathBytes;

  /// 16-byte region scope key. All zero means the packet is unscoped.
  final Uint8List regionKey;

  TestModeConfig({
    required this.enabled,
    required this.hashSize,
    required this.pathBytes,
    required this.regionKey,
  });

  factory TestModeConfig.disabled() {
    return TestModeConfig(
      enabled: false,
      hashSize: 1,
      pathBytes: Uint8List(0),
      regionKey: Uint8List(testModeRegionKeySize),
    );
  }

  int get hopCount => hashSize <= 0 ? 0 : pathBytes.length ~/ hashSize;

  bool get isFlood => pathBytes.isEmpty;

  bool get isScoped => regionKey.any((byte) => byte != 0);

  TestModeConfig copyWith({
    bool? enabled,
    int? hashSize,
    Uint8List? pathBytes,
    Uint8List? regionKey,
  }) {
    return TestModeConfig(
      enabled: enabled ?? this.enabled,
      hashSize: hashSize ?? this.hashSize,
      pathBytes: pathBytes ?? this.pathBytes,
      regionKey: regionKey ?? this.regionKey,
    );
  }
}

/// Result of a test packet send, taken from the normal `RESP_CODE_SENT` reply.
///
/// Test packets never expect an ACK, so [expectedAckHash] is always 0.
class TestSendResult {
  final bool flood;
  final int estimatedTimeoutMs;
  final int expectedAckHash;

  const TestSendResult({
    required this.flood,
    required this.estimatedTimeoutMs,
    this.expectedAckHash = 0,
  });
}

const int testModeRegionKeySize = 16;
const int testModeHashSizeMin = 1;
const int testModeHashSizeMax = 3;
// Leave room for at least one real flood router to append its hash.
const int testModeMaxHops = 62;
const int testModeMaxPathBytes = 64;
const int testModeMaxTextBytes = 160;
