import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/pending_command_replies.dart';
import 'package:meshcore_open/models/test_mode_config.dart';
import 'package:meshcore_open/review_mode/review_radio.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitFor(bool Function() condition, {int seconds = 8}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for condition');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Review radio that records every frame the app sends.
class _RecordingRadio extends ReviewRadio {
  _RecordingRadio({required super.firmwareVerCode})
    : super(
        scheduledMessageInterval: const Duration(hours: 1),
        ackDelay: const Duration(milliseconds: 50),
        replyDelay: const Duration(hours: 1),
      );

  final List<Uint8List> sent = [];

  @override
  void handle(Uint8List frame) {
    sent.add(Uint8List.fromList(frame));
    super.handle(frame);
  }

  Iterable<Uint8List> withCode(int code) =>
      sent.where((f) => f.isNotEmpty && f[0] == code);
}

// NotificationService is a process-wide singleton whose reply stream can be
// listened to once, so every test shares one connector and reconnects it to a
// fresh radio.
late MeshCoreConnector _connector;

Future<(MeshCoreConnector, _RecordingRadio)> _connect(int verCode) async {
  final connector = _connector;
  final radio = _RecordingRadio(firmwareVerCode: verCode);
  connector.reviewRadioFactoryForTest = () => radio;
  await connector.connectReview();
  addTearDown(connector.disconnect);
  await _waitFor(
    () => connector.firmwareVerCode == verCode && connector.channels.isNotEmpty,
  );
  // Let the version-gated config queries go out.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return (connector, radio);
}

TestModeConfig _config({
  bool enabled = true,
  int hashSize = 1,
  List<int> path = const [],
  List<int>? regionKey,
}) {
  return TestModeConfig(
    enabled: enabled,
    hashSize: hashSize,
    pathBytes: Uint8List.fromList(path),
    regionKey: Uint8List.fromList(regionKey ?? List<int>.filled(16, 0)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    _connector = MeshCoreConnector();
    final retryService = MessageRetryService();
    _connector.initialize(
      retryService: retryService,
      pathHistoryService: PathHistoryService(StorageService()),
    );
    addTearDown(() {
      _connector.dispose();
      retryService.dispose();
    });
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  group('frames', () {
    test('SET_CONFIG layout', () {
      final regionKey = List<int>.generate(16, (i) => i + 1);
      final frame = buildTestSetConfigFrame(
        _config(
          hashSize: 2,
          path: [0x12, 0x34, 0x56, 0x78],
          regionKey: regionKey,
        ),
      );

      expect(frame.length, 20 + 4);
      expect(frame[0], cmdTestSetConfig);
      expect(frame[1], 1);
      expect(frame[2], 2);
      expect(frame[3], 4);
      expect(frame.sublist(4, 20), regionKey);
      expect(frame.sublist(20), [0x12, 0x34, 0x56, 0x78]);
    });

    test('SET_CONFIG rejects invalid hash sizes', () {
      expect(
        () => buildTestSetConfigFrame(_config(hashSize: 0)),
        throwsArgumentError,
      );
      expect(
        () => buildTestSetConfigFrame(_config(hashSize: 4)),
        throwsArgumentError,
      );
    });

    test('SET_CONFIG rejects a path that does not fit the hash size', () {
      expect(
        () => buildTestSetConfigFrame(_config(hashSize: 2, path: [1, 2, 3])),
        throwsArgumentError,
      );
    });

    test('SET_CONFIG rejects a path longer than 64 bytes', () {
      expect(
        () => buildTestSetConfigFrame(
          _config(hashSize: 2, path: List<int>.filled(66, 0xAA)),
        ),
        throwsArgumentError,
      );
    });

    test('SET_CONFIG rejects more than 63 hops', () {
      expect(
        () => buildTestSetConfigFrame(
          _config(hashSize: 1, path: List<int>.filled(64, 0xAA)),
        ),
        throwsArgumentError,
      );
      expect(
        buildTestSetConfigFrame(
          _config(hashSize: 1, path: List<int>.filled(63, 0xAA)),
        ).length,
        20 + 63,
      );
    });

    test('SET_CONFIG rejects a region key that is not 16 bytes', () {
      expect(
        () => buildTestSetConfigFrame(
          _config(regionKey: List<int>.filled(15, 0)),
        ),
        throwsArgumentError,
      );
    });

    test('GET_CONFIG layout', () {
      expect(buildTestGetConfigFrame(), [cmdTestGetConfig]);
    });

    test('SEND_TXT layout uses a little-endian timestamp', () {
      final frame = buildTestSendTxtFrame('hi', timestampSeconds: 0x01020304);

      expect(frame[0], cmdTestSendTxt);
      expect(frame.sublist(1, 5), [0x04, 0x03, 0x02, 0x01]);
      expect(frame.sublist(5), 'hi'.codeUnits);
    });

    test('SEND_TXT rejects text over 160 UTF-8 bytes', () {
      expect(
        () => buildTestSendTxtFrame('a' * testModeMaxTextBytes),
        returnsNormally,
      );
      expect(
        () => buildTestSendTxtFrame('a' * (testModeMaxTextBytes + 1)),
        throwsArgumentError,
      );
      expect(
        () => buildTestSendTxtFrame('é' * (testModeMaxTextBytes ~/ 2 + 1)),
        throwsArgumentError,
      );
    });

    test('SEND_TXT rejects an out-of-range timestamp', () {
      expect(
        () => buildTestSendTxtFrame('hi', timestampSeconds: -1),
        throwsArgumentError,
      );
      expect(
        () => buildTestSendTxtFrame('hi', timestampSeconds: 0x100000000),
        throwsArgumentError,
      );
    });

    test('TEST_CONFIG reply parses a full configuration', () {
      final regionKey = List<int>.generate(16, (i) => 0x10 + i);
      final config = _config(
        enabled: true,
        hashSize: 3,
        path: [1, 2, 3, 4, 5, 6],
        regionKey: regionKey,
      );
      final reply = Uint8List.fromList([
        respCodeTestConfig,
        ...buildTestSetConfigFrame(config).sublist(1),
      ]);

      final parsed = parseTestConfigFrame(reply)!;
      expect(parsed.enabled, isTrue);
      expect(parsed.hashSize, 3);
      expect(parsed.pathBytes, [1, 2, 3, 4, 5, 6]);
      expect(parsed.regionKey, regionKey);
      expect(parsed.hopCount, 2);
      expect(parsed.isFlood, isFalse);
      expect(parsed.isScoped, isTrue);
    });

    test('TEST_CONFIG reply validates its header', () {
      expect(parseTestConfigFrame(Uint8List(0)), isNull);
      expect(parseTestConfigFrame(Uint8List.fromList([respCodeOk])), isNull);
      expect(
        parseTestConfigFrame(
          Uint8List.fromList([
            respCodeTestConfig,
            1,
            0,
            0,
            ...List<int>.filled(16, 0),
          ]),
        ),
        isNull,
      );
      expect(
        parseTestConfigFrame(
          Uint8List.fromList([
            respCodeTestConfig,
            1,
            4,
            0,
            ...List<int>.filled(16, 0),
          ]),
        ),
        isNull,
      );
      expect(
        parseTestConfigFrame(
          Uint8List.fromList([
            respCodeTestConfig,
            1,
            2,
            3,
            ...List<int>.filled(16, 0),
          ]),
        ),
        isNull,
      );
      expect(
        parseTestConfigFrame(
          Uint8List.fromList([
            respCodeTestConfig,
            1,
            2,
            4,
            ...List<int>.filled(16, 0),
          ]),
        ),
        isNull,
      );
    });

    test('test-mode commands map to their replies', () {
      expect(
        replyCodeForCommand(Uint8List.fromList([cmdTestSetConfig])),
        respCodeOk,
      );
      expect(
        replyCodeForCommand(Uint8List.fromList([cmdTestGetConfig])),
        respCodeTestConfig,
      );
      expect(
        replyCodeForCommand(Uint8List.fromList([cmdTestSendTxt])),
        respCodeSent,
      );
    });
  });

  group('connector', () {
    test('supportsTestMode is gated on firmware ver code 15', () async {
      final (connector, _) = await _connect(14);
      expect(connector.supportsTestMode, isFalse);
      await connector.disconnect();
    });

    test('reads, writes and round-trips the configuration', () async {
      final (connector, radio) = await _connect(15);
      expect(connector.supportsTestMode, isTrue);

      final initial = await connector.getTestModeConfig();
      expect(initial, isNotNull);
      expect(initial!.enabled, isFalse);
      expect(initial.hashSize, 1);
      expect(initial.pathBytes, isEmpty);
      expect(initial.isScoped, isFalse);

      final config = _config(
        hashSize: 2,
        path: [0xAA, 0xBB, 0xCC, 0xDD],
        regionKey: List<int>.generate(16, (i) => 0xFF - i),
      );
      await connector.setTestModeConfig(config);

      final stored = await connector.getTestModeConfig();
      expect(stored, isNotNull);
      expect(stored!.enabled, isTrue);
      expect(stored.hashSize, 2);
      expect(stored.pathBytes, [0xAA, 0xBB, 0xCC, 0xDD]);
      expect(stored.regionKey, config.regionKey);
      expect(connector.lastTestModeConfig?.regionKey, config.regionKey);

      expect(radio.withCode(cmdTestGetConfig), hasLength(2));
      expect(radio.withCode(cmdTestSetConfig), hasLength(1));
    });

    test('sends a flood packet with ACK hash 0', () async {
      final (connector, _) = await _connect(15);
      await connector.setTestModeConfig(_config());

      final result = await connector.sendTestText('amber fox 4832');

      expect(result.flood, isTrue);
      expect(result.expectedAckHash, 0);
      expect(result.estimatedTimeoutMs, greaterThan(0));
    });

    test('sends a direct packet when a path is configured', () async {
      final (connector, _) = await _connect(15);
      await connector.setTestModeConfig(
        _config(hashSize: 2, path: [1, 2, 3, 4]),
      );

      final result = await connector.sendTestText('direct test');

      expect(result.flood, isFalse);
      expect(result.expectedAckHash, 0);
    });

    test('a disabled radio rejects sends with BAD_STATE', () async {
      final (connector, _) = await _connect(15);
      await connector.setTestModeConfig(_config(enabled: false));

      await expectLater(
        connector.sendTestText('blocked'),
        throwsA(
          isA<FirmwareCommandException>().having(
            (e) => e.errCode,
            'errCode',
            4,
          ),
        ),
      );
    });

    test('overlong text is rejected with ILLEGAL_ARG', () async {
      final (connector, _) = await _connect(15);
      await connector.setTestModeConfig(_config());

      final raw = Uint8List.fromList([
        cmdTestSendTxt,
        1,
        0,
        0,
        0,
        ...List<int>.filled(testModeMaxTextBytes + 1, 0x61),
      ]);
      await expectLater(
        connector.sendFrame(raw, waitForGenericAck: true),
        throwsA(
          isA<FirmwareCommandException>().having(
            (e) => e.errCode,
            'errCode',
            6,
          ),
        ),
      );
    });

    test('a normal direct send still works after a test packet', () async {
      final (connector, _) = await _connect(15);
      await connector.setTestModeConfig(_config());
      await connector.sendTestText('test first');

      final contact = connector.contacts.firstWhere((c) => c.path.isNotEmpty);
      await connector.sendMessage(contact, 'normal after test');

      expect(connector.getMessages(contact), isNotEmpty);
    });
  });
}
