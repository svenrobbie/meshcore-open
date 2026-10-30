import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/test_mode_config.dart';
import 'package:meshcore_open/screens/test_mode_screen.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeConnector extends MeshCoreConnector {
  _FakeConnector({required this.config});

  final TestModeConfig config;
  final List<TestModeConfig> applied = [];
  final List<String> sent = [];

  @override
  bool get isConnected => true;

  @override
  bool get supportsTestMode => true;

  @override
  String get defaultRegion => 'eu-west';

  @override
  Future<TestModeConfig?> getTestModeConfig({
    Duration timeout = const Duration(seconds: 3),
  }) async => config;

  @override
  Future<void> setTestModeConfig(TestModeConfig config) async {
    applied.add(config);
  }

  @override
  Future<TestSendResult> sendTestText(
    String text, {
    int? timestampSeconds,
  }) async {
    sent.add(text);
    return const TestSendResult(flood: true, estimatedTimeoutMs: 8000);
  }
}

Widget _buildApp(MeshCoreConnector connector) {
  return ChangeNotifierProvider<MeshCoreConnector>.value(
    value: connector,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const TestModeScreen(),
    ),
  );
}

/// The screen is a long ListView; give the test viewport enough height that
/// the send controls are built instead of staying lazy off-screen.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  testWidgets('loads the radio configuration and sends a test packet', (
    tester,
  ) async {
    final connector = _FakeConnector(
      config: TestModeConfig(
        enabled: true,
        hashSize: 1,
        pathBytes: Uint8List.fromList([0x12, 0x34]),
        regionKey: Uint8List(16),
      ),
    );
    addTearDown(connector.dispose);

    _useTallSurface(tester);
    await tester.pumpWidget(_buildApp(connector));
    await tester.pumpAndSettle();

    expect(find.text('12 34'), findsOneWidget);
    expect(find.text('2 hops x 1 bytes (2 bytes)'), findsOneWidget);
    expect(find.text('Sent as flood'), findsNothing);
    expect(find.text('Key: 00000000000000000000000000000000'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'hello mesh');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send test packet'));
    await tester.pumpAndSettle();

    expect(connector.applied, hasLength(1));
    expect(connector.applied.single.enabled, isTrue);
    expect(connector.applied.single.pathBytes, [0x12, 0x34]);
    expect(connector.sent, ['hello mesh']);
    expect(find.text('Sent as flood'), findsOneWidget);
    expect(find.text('hello mesh'), findsWidgets);
  });

  testWidgets('disables sending when test mode is off', (tester) async {
    final connector = _FakeConnector(config: TestModeConfig.disabled());
    addTearDown(connector.dispose);

    _useTallSurface(tester);
    await tester.pumpWidget(_buildApp(connector));
    await tester.pumpAndSettle();

    expect(find.text('Enable test mode before sending.'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send test packet'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('shows the unsupported banner without a compatible radio', (
    tester,
  ) async {
    final connector = _UnsupportedConnector();
    addTearDown(connector.dispose);

    _useTallSurface(tester);
    await tester.pumpWidget(_buildApp(connector));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This radio does not support test mode. Use companion firmware 15 or '
        'newer compiled with ENABLE_TEST_MODE.',
      ),
      findsOneWidget,
    );
  });
}

class _UnsupportedConnector extends MeshCoreConnector {
  @override
  bool get isConnected => true;

  @override
  bool get supportsTestMode => false;
}
