import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../connector/pending_command_replies.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/test_mode_config.dart';
import '../storage/region_store.dart';
import '../utils/test_message_generator.dart';
import '../utils/test_mode_input.dart';
import 'channels_screen.dart';
import 'region_management_screen.dart';
import '../widgets/mesh_ui.dart';

const String _customRegionValue = '__test_mode_custom_region__';

enum _TestPacketTarget { direct, group }

class _TestSendLogEntry {
  final String message;
  final bool flood;
  final int timeoutMs;
  final DateTime at;

  const _TestSendLogEntry({
    required this.message,
    required this.flood,
    required this.timeoutMs,
    required this.at,
  });
}

class TestModeScreen extends StatefulWidget {
  const TestModeScreen({super.key});

  @override
  State<TestModeScreen> createState() => _TestModeScreenState();
}

class _TestModeScreenState extends State<TestModeScreen> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _senderController = TextEditingController(
    text: 'MeshTest',
  );
  final TextEditingController _timestampController = TextEditingController();
  final Random _random = Random();

  bool _initialized = false;
  bool _loading = true;
  bool _busy = false;
  bool _running = false;

  bool _enabled = false;
  int _hashSize = 1;
  Uint8List _pathBytes = Uint8List(0);
  TestPathParseError? _pathError;
  List<String> _regions = const [];
  String _regionSelection = '';
  Uint8List? _unknownRegionKey;

  bool _randomMessage = false;
  bool _randomPath = false;
  bool _randomGroupSender = true;
  bool _continuousMode = false;
  int _continuousIntervalMs = 500;
  bool _useCurrentTime = true;
  _TestPacketTarget _target = _TestPacketTarget.direct;
  int? _selectedChannelIndex;

  String? _errorText;
  String? _lastMessage;
  TestSendResult? _lastResult;
  int _sentCount = 0;
  final List<_TestSendLogEntry> _log = [];

  @override
  void initState() {
    super.initState();
    _timestampController.text =
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final connector = context.read<MeshCoreConnector>();
    _loadRegions(connector);
    unawaited(_loadConfig(connector));
  }

  @override
  void dispose() {
    _running = false;
    _textController.dispose();
    _pathController.dispose();
    _senderController.dispose();
    _timestampController.dispose();
    super.dispose();
  }

  void _loadRegions(MeshCoreConnector connector) {
    final radioRegion = connector.defaultFloodScopeName;
    final regions = <String>{
      ...RegionStore().loadRegions().where(
        (region) => region.isNotEmpty && region != kUnscopedRegion,
      ),
      if (connector.defaultRegion.isNotEmpty &&
          connector.defaultRegion != kUnscopedRegion)
        connector.defaultRegion,
      if (radioRegion != null && radioRegion.isNotEmpty) radioRegion,
    }.toList()..sort();
    _regions = List.unmodifiable(regions);
  }

  Future<void> _manageRegions(MeshCoreConnector connector) async {
    await pushRegionManagementScreen(context);
    if (!mounted) return;
    setState(() => _loadRegions(connector));
  }

  Channel? _selectedGroupChannel(MeshCoreConnector connector) {
    final channels = connector.channels.where((channel) => !channel.isEmpty);
    return channels
            .where((channel) => channel.index == _selectedChannelIndex)
            .firstOrNull ??
        channels.firstOrNull;
  }

  Future<void> _openChannels() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => const ChannelsScreen()),
    );
    if (!mounted) return;
    final connector = context.read<MeshCoreConnector>();
    setState(() {
      _selectedChannelIndex = _selectedGroupChannel(connector)?.index;
    });
  }

  Future<void> _loadConfig(MeshCoreConnector connector) async {
    if (!connector.isConnected || !connector.supportsTestMode) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final config = await connector.getTestModeConfig();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (config != null) _applyConfig(config);
    });
  }

  void _applyConfig(TestModeConfig config) {
    _enabled = config.enabled;
    _hashSize = config.hashSize;
    _pathBytes = config.pathBytes;
    _pathController.text = formatTestPathHex(config.pathBytes);
    final path = parseTestPathHex(
      _pathController.text,
      hashSize: config.hashSize,
    );
    _pathError = path.error;
    _regionSelection = _selectionForRegionKey(config.regionKey);
  }

  String _selectionForRegionKey(Uint8List key) {
    if (key.every((byte) => byte == 0)) {
      _unknownRegionKey = null;
      return '';
    }
    for (final region in _regions) {
      if (_sameBytes(floodScopeKeyForRegion(region), key)) {
        _unknownRegionKey = null;
        return region;
      }
    }
    _unknownRegionKey = Uint8List.fromList(key);
    return _customRegionValue;
  }

  bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Uint8List _selectedRegionKey() {
    if (_regionSelection == '') {
      return Uint8List(testModeRegionKeySize);
    }
    if (_regionSelection == _customRegionValue) {
      return Uint8List.fromList(
        _unknownRegionKey ?? Uint8List(testModeRegionKeySize),
      );
    }
    return floodScopeKeyForRegion(_regionSelection);
  }

  TestModeConfig _buildConfig({Uint8List? pathBytes}) {
    return TestModeConfig(
      enabled: _enabled,
      hashSize: _hashSize,
      pathBytes: pathBytes ?? _pathBytes,
      regionKey: _selectedRegionKey(),
    );
  }

  int _textBytes(String text) => utf8.encode(text).length;

  int get _messageByteLimit {
    if (_target != _TestPacketTarget.group) return testModeMaxTextBytes;
    final senderBytes = _randomGroupSender
        ? randomTestSenderNameMaxBytes
        : _textBytes(_senderController.text);
    return testModeMaxTextBytes - senderBytes - 2;
  }

  bool get _hasValidTimestamp {
    if (_useCurrentTime) return true;
    final value = int.tryParse(_timestampController.text.trim());
    return value != null && value >= 0 && value <= 0xFFFFFFFF;
  }

  int? _timestampForSend() {
    if (_useCurrentTime) return null;
    return int.tryParse(_timestampController.text.trim());
  }

  bool get _canSendNow {
    if (_loading || _busy || _running || !_enabled) return false;
    if (_pathError != null || !_hasValidTimestamp) return false;
    if (!_randomMessage) {
      if (_textController.text.trim().isEmpty) return false;
      if (_textBytes(_textController.text) > _messageByteLimit) {
        return false;
      }
    } else if (_messageByteLimit < randomTestMessageMaxBytes) {
      return false;
    }
    if (_target == _TestPacketTarget.group && !_randomGroupSender) {
      final senderBytes = _textBytes(_senderController.text.trim());
      if (senderBytes == 0 || senderBytes > 31) return false;
      if (senderBytes +
              2 +
              (_randomMessage
                  ? randomTestMessageMaxBytes
                  : _textBytes(_textController.text)) >
          testModeMaxTextBytes) {
        return false;
      }
    }
    return true;
  }

  void _onPathChanged(String value) {
    final parsed = parseTestPathHex(value, hashSize: _hashSize);
    setState(() {
      _pathError = parsed.error;
      if (parsed.isValid) _pathBytes = parsed.bytes;
      if (parsed.isValid && parsed.bytes.isEmpty) _randomPath = false;
    });
  }

  void _setHashSize(int value) {
    final parsed = parseTestPathHex(_pathController.text, hashSize: value);
    setState(() {
      _hashSize = value;
      _pathError = parsed.error;
      if (parsed.isValid) _pathBytes = parsed.bytes;
    });
  }

  Future<void> _applyConfigToRadio() async {
    final connector = context.read<MeshCoreConnector>();
    if (!connector.isConnected || !connector.supportsTestMode) return;
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      await connector.setTestModeConfig(_buildConfig());
      if (!mounted) return;
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.testMode_applySuccess),
      );
    } catch (error) {
      if (mounted) setState(() => _errorText = _describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<(String, TestSendResult)> _sendTestPacket(
    MeshCoreConnector connector,
    String text, {
    int? channelIndex,
  }) async {
    if (_target == _TestPacketTarget.group) {
      if (channelIndex == null) {
        throw StateError('No group channel is selected');
      }
      final senderName = _randomGroupSender
          ? randomTestSenderName(_random)
          : _senderController.text.trim();
      final result = await connector.sendTestGroupText(
        channelIndex: channelIndex,
        senderName: senderName,
        text: text,
        timestampSeconds: _timestampForSend(),
      );
      return ('$senderName: $text', result);
    }

    final result = await connector.sendTestText(
      text,
      timestampSeconds: _timestampForSend(),
    );
    return (text, result);
  }

  Future<void> _sendOnce() async {
    final connector = context.read<MeshCoreConnector>();
    if (!_canSendNow || !connector.isConnected || !connector.supportsTestMode) {
      return;
    }
    final channelIndex = _selectedGroupChannel(connector)?.index;
    if (_target == _TestPacketTarget.group && channelIndex == null) return;
    final pathBytes = _randomPath
        ? randomTestPath(_pathBytes, _random)
        : _pathBytes;
    final config = _buildConfig(pathBytes: pathBytes);
    final text = _randomMessage
        ? randomTestMessage(_random)
        : _textController.text;

    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      await connector.setTestModeConfig(config);
      final sent = await _sendTestPacket(
        connector,
        text,
        channelIndex: channelIndex,
      );
      if (!mounted) return;
      _recordSend(sent.$1, sent.$2);
    } catch (error) {
      if (mounted) setState(() => _errorText = _describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startContinuous() async {
    final connector = context.read<MeshCoreConnector>();
    if (!_canSendNow || !connector.isConnected || !connector.supportsTestMode) {
      return;
    }
    final channelIndex = _selectedGroupChannel(connector)?.index;
    if (_target == _TestPacketTarget.group && channelIndex == null) return;

    setState(() {
      _busy = true;
      _running = true;
      _errorText = null;
      _sentCount = 0;
      _lastMessage = null;
      _lastResult = null;
      _log.clear();
    });

    try {
      final baseConfig = _buildConfig();
      await connector.setTestModeConfig(baseConfig);
      while (_running && mounted) {
        if (!connector.isConnected ||
            !connector.supportsTestMode ||
            (_target == _TestPacketTarget.group &&
                !connector.supportsTestGroupMode)) {
          throw StateError('Disconnected');
        }
        final pathBytes = _randomPath
            ? randomTestPath(baseConfig.pathBytes, _random)
            : baseConfig.pathBytes;
        final config = baseConfig.copyWith(pathBytes: pathBytes);
        if (_randomPath) await connector.setTestModeConfig(config);
        final text = _randomMessage
            ? randomTestMessage(_random)
            : _textController.text;
        final sent = await _sendContinuousPacket(
          connector,
          text,
          channelIndex: channelIndex,
        );
        if (sent == null) break;
        if (!mounted || !_running) break;
        _recordSend(sent.$1, sent.$2);
        await _waitWhileRunning(Duration(milliseconds: _continuousIntervalMs));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = _describeError(error);
          _running = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _busy = false;
        });
      }
    }
  }

  void _stopContinuous() {
    if (!_running) return;
    setState(() => _running = false);
  }

  Future<(String, TestSendResult)?> _sendContinuousPacket(
    MeshCoreConnector connector,
    String text, {
    int? channelIndex,
  }) async {
    final retryDelay = Duration(milliseconds: _continuousIntervalMs);
    while (_running && mounted) {
      try {
        return await _sendTestPacket(
          connector,
          text,
          channelIndex: channelIndex,
        );
      } on FirmwareCommandException catch (error) {
        if (error.errCode != 3) rethrow;
        await _waitWhileRunning(retryDelay);
      }
    }
    return null;
  }

  Future<void> _waitWhileRunning(Duration wait) async {
    final deadline = DateTime.now().add(wait);
    const pollInterval = Duration(milliseconds: 200);
    while (_running && mounted) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      await Future.delayed(remaining < pollInterval ? remaining : pollInterval);
    }
  }

  void _recordSend(String message, TestSendResult result) {
    setState(() {
      _sentCount++;
      _lastMessage = message;
      _lastResult = result;
      _log.insert(
        0,
        _TestSendLogEntry(
          message: message,
          flood: result.flood,
          timeoutMs: result.estimatedTimeoutMs,
          at: DateTime.now(),
        ),
      );
      if (_log.length > 10) {
        _log.removeRange(10, _log.length);
      }
    });
  }

  String _describeError(Object error) {
    final l10n = context.l10n;
    if (error is FirmwareCommandException) {
      return switch (error.errCode) {
        3 => l10n.testMode_errorQueueFull,
        4 => l10n.testMode_errorBadState,
        6 => l10n.testMode_errorIllegalArg,
        _ => l10n.testMode_errorFirmware(error.errCode),
      };
    }
    if (error is TimeoutException) return l10n.testMode_errorTimeout;
    if (error is UnsupportedError) return l10n.testMode_notSupported;
    if (error is StateError) return l10n.testMode_errorNotConnected;
    return l10n.testMode_errorGeneric(error.toString());
  }

  String _pathErrorText(TestPathParseError error) {
    final l10n = context.l10n;
    return switch (error) {
      TestPathParseError.invalidHex => l10n.testMode_pathErrorInvalidHex,
      TestPathParseError.tooLong => l10n.testMode_pathErrorTooLong,
      TestPathParseError.notDivisibleByHashSize =>
        l10n.testMode_pathErrorNotDivisible,
      TestPathParseError.tooManyHops => l10n.testMode_pathErrorTooManyHops,
    };
  }

  String _formatKey(Uint8List key) {
    return key.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  String? _timestampPreview() {
    final value = int.tryParse(_timestampController.text.trim());
    if (value == null || value < 0 || value > 0xFFFFFFFF) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(value * 1000);
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')} ${_formatTime(time)}';
  }

  String _pathSummary() {
    if (_pathBytes.isEmpty) return context.l10n.testMode_pathFlood;
    return context.l10n.testMode_pathSummary(
      _pathBytes.length ~/ _hashSize,
      _pathBytes.length,
      _hashSize,
    );
  }

  String _randomPathNote() => context.l10n.testMode_randomModePathNote(
    _pathBytes.length ~/ _hashSize,
    _hashSize,
  );

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final l10n = context.l10n;
    final available = connector.isConnected && connector.supportsTestMode;
    final controlsEnabled = available && !_busy && !_running;
    final groupChannels = connector.channels
        .where((channel) => !channel.isEmpty)
        .toList();
    final selectedGroupChannel = _selectedGroupChannel(connector);
    final groupTargetAvailable = connector.supportsTestGroupMode;
    final textBytes = _textBytes(_textController.text);
    final messageByteLimit = _messageByteLimit;
    final textTooLong = !_randomMessage && textBytes > messageByteLimit;
    final canSend =
        available &&
        _canSendNow &&
        (_target != _TestPacketTarget.group ||
            (groupTargetAvailable && selectedGroupChannel != null));
    final timestampInvalid = !_useCurrentTime && !_hasValidTimestamp;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.testMode_title), centerTitle: true),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
          children: [
            if (!available)
              MeshCard(
                child: Row(
                  children: [
                    Icon(
                      Icons.science_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        connector.isConnected
                            ? l10n.testMode_unavailable
                            : l10n.testMode_disconnected,
                      ),
                    ),
                  ],
                ),
              ),
            SectionHeader(l10n.testMode_configuration),
            MeshCard(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.testMode_enabled),
                          subtitle: Text(l10n.testMode_enabledSubtitle),
                          value: _enabled,
                          onChanged: controlsEnabled
                              ? (value) => setState(() => _enabled = value)
                              : null,
                        ),
                        const Divider(height: 1),
                        const SizedBox(height: 12),
                        Text(
                          l10n.testMode_idSize,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 1, label: Text('1')),
                            ButtonSegment(value: 2, label: Text('2')),
                            ButtonSegment(value: 3, label: Text('3')),
                          ],
                          selected: {_hashSize},
                          onSelectionChanged: controlsEnabled
                              ? (selection) => _setHashSize(selection.first)
                              : null,
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: ValueKey(_regionSelection),
                          initialValue: _regionSelection,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l10n.testMode_region,
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: controlsEnabled
                              ? (value) {
                                  if (value == null) return;
                                  setState(() => _regionSelection = value);
                                }
                              : null,
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text(l10n.testMode_regionNone),
                            ),
                            for (final region in _regions)
                              DropdownMenuItem(
                                value: region,
                                child: Text(
                                  region,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (_regionSelection == _customRegionValue)
                              DropdownMenuItem(
                                value: _customRegionValue,
                                child: Text(
                                  l10n.testMode_regionUnknown,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: controlsEnabled
                                ? () => _manageRegions(connector)
                                : null,
                            icon: const Icon(Icons.travel_explore),
                            label: Text(
                              l10n.settings_regionManagement_screenTitle,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          l10n.testMode_regionKey(
                            _formatKey(_selectedRegionKey()),
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _pathController,
                          enabled: controlsEnabled,
                          onChanged: _onPathChanged,
                          decoration: InputDecoration(
                            labelText: l10n.testMode_path,
                            hintText: l10n.testMode_pathHint,
                            helperText: _pathError == null
                                ? _pathSummary()
                                : null,
                            errorText: _pathError == null
                                ? null
                                : _pathErrorText(_pathError!),
                            errorMaxLines: 2,
                            helperMaxLines: 2,
                            border: const OutlineInputBorder(),
                            suffixIcon: _pathController.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: l10n.testMode_pathClear,
                                    icon: const Icon(Icons.clear),
                                    onPressed: controlsEnabled
                                        ? () {
                                            _pathController.clear();
                                            _onPathChanged('');
                                          }
                                        : null,
                                  ),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.testMode_randomPath),
                          subtitle: Text(
                            _pathBytes.isEmpty
                                ? l10n.testMode_pathFlood
                                : _randomPath
                                ? _randomPathNote()
                                : l10n.testMode_randomPathSubtitle,
                          ),
                          value: _randomPath,
                          onChanged: controlsEnabled && _pathBytes.isNotEmpty
                              ? (value) => setState(() => _randomPath = value)
                              : null,
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.testMode_randomMessage),
                          subtitle: Text(l10n.testMode_randomMessageSubtitle),
                          value: _randomMessage,
                          onChanged: controlsEnabled
                              ? (value) =>
                                    setState(() => _randomMessage = value)
                              : null,
                        ),
                        const Divider(height: 1),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.testMode_timestamp),
                          subtitle: Text(l10n.testMode_timestampSubtitle),
                          value: !_useCurrentTime,
                          onChanged: controlsEnabled
                              ? (value) =>
                                    setState(() => _useCurrentTime = !value)
                              : null,
                        ),
                        if (!_useCurrentTime) ...[
                          const SizedBox(height: 8),
                          TextField(
                            controller: _timestampController,
                            enabled: controlsEnabled,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: l10n.testMode_timestampField,
                              errorText: timestampInvalid
                                  ? l10n.testMode_timestampInvalid
                                  : null,
                              helperText: timestampInvalid
                                  ? null
                                  : _timestampPreview(),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: controlsEnabled && available
                              ? _applyConfigToRadio
                              : null,
                          icon: const Icon(Icons.save_outlined),
                          label: Text(l10n.testMode_apply),
                        ),
                      ],
                    ),
            ),
            SectionHeader(l10n.testMode_packet),
            MeshCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.testMode_target,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<_TestPacketTarget>(
                    segments: [
                      ButtonSegment(
                        value: _TestPacketTarget.direct,
                        label: Text(l10n.testMode_targetDirect),
                      ),
                      ButtonSegment(
                        value: _TestPacketTarget.group,
                        label: Text(l10n.testMode_targetGroup),
                        enabled: groupTargetAvailable,
                      ),
                    ],
                    selected: {_target},
                    onSelectionChanged: controlsEnabled
                        ? (selection) =>
                              setState(() => _target = selection.first)
                        : null,
                  ),
                  if (!groupTargetAvailable)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        l10n.testMode_groupRequiresFirmware,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (_target == _TestPacketTarget.group) ...[
                    const SizedBox(height: 12),
                    if (groupChannels.isEmpty) ...[
                      Text(
                        l10n.testMode_groupNoChannels,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: controlsEnabled ? _openChannels : null,
                          icon: const Icon(Icons.forum_outlined),
                          label: Text(l10n.testMode_groupManageChannels),
                        ),
                      ),
                    ] else ...[
                      DropdownButtonFormField<int>(
                        key: ValueKey(selectedGroupChannel?.index),
                        initialValue: selectedGroupChannel?.index,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10n.testMode_groupChannel,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: controlsEnabled
                            ? (value) {
                                if (value == null) return;
                                setState(() => _selectedChannelIndex = value);
                              }
                            : null,
                        items: [
                          for (final channel in groupChannels)
                            DropdownMenuItem(
                              value: channel.index,
                              child: Text(
                                channel.name.isEmpty
                                    ? 'Channel ${channel.index + 1}'
                                    : channel.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.testMode_randomSender),
                        subtitle: Text(l10n.testMode_randomSenderSubtitle),
                        value: _randomGroupSender,
                        onChanged: controlsEnabled
                            ? (value) =>
                                  setState(() => _randomGroupSender = value)
                            : null,
                      ),
                      if (!_randomGroupSender) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _senderController,
                          enabled: controlsEnabled,
                          onChanged: (_) => setState(() {}),
                          maxLength: 31,
                          decoration: InputDecoration(
                            labelText: l10n.testMode_senderName,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _textController,
                    enabled: controlsEnabled && !_randomMessage,
                    onChanged: (_) => setState(() {}),
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: l10n.testMode_message,
                      hintText: _randomMessage
                          ? l10n.testMode_messageRandom
                          : l10n.testMode_messageHint,
                      errorText: textTooLong
                          ? l10n.testMode_messageTooLong(messageByteLimit)
                          : null,
                      helperText: _randomMessage
                          ? l10n.testMode_messageRandom
                          : l10n.testMode_messageBytes(
                              textBytes,
                              messageByteLimit,
                            ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.testMode_continuous),
                    subtitle: Text(l10n.testMode_continuousSubtitle),
                    value: _continuousMode,
                    onChanged: controlsEnabled
                        ? (value) => setState(() => _continuousMode = value)
                        : null,
                  ),
                  if (_continuousMode) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: _continuousIntervalMs,
                      decoration: InputDecoration(
                        labelText: l10n.testMode_continuousInterval,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: controlsEnabled
                          ? (value) {
                              if (value != null) {
                                setState(() => _continuousIntervalMs = value);
                              }
                            }
                          : null,
                      items: [
                        DropdownMenuItem(
                          value: 250,
                          child: Text(l10n.testMode_interval250ms),
                        ),
                        DropdownMenuItem(
                          value: 500,
                          child: Text(l10n.testMode_interval500ms),
                        ),
                      ],
                    ),
                  ],
                  if (_continuousMode)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        l10n.testMode_airtimeWarning,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 4),
                  if (_continuousMode)
                    FilledButton.icon(
                      onPressed: _running
                          ? _stopContinuous
                          : (canSend ? _startContinuous : null),
                      icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        _running
                            ? l10n.testMode_stop
                            : _busy
                            ? l10n.testMode_sending
                            : l10n.testMode_start,
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: canSend ? _sendOnce : null,
                      icon: const Icon(Icons.send),
                      label: Text(
                        _busy ? l10n.testMode_sending : l10n.testMode_send,
                      ),
                    ),
                  if (!_enabled && available)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        l10n.testMode_enableFirst,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (_errorText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _errorText!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_lastResult != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '${_target == _TestPacketTarget.group ? l10n.testMode_targetGroup : l10n.testMode_targetDirect} · ${_lastResult!.flood ? l10n.testMode_sentFlood : l10n.testMode_sentDirect}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(l10n.testMode_noAck),
                    Text(
                      l10n.testMode_estimatedTimeout(
                        _lastResult!.estimatedTimeoutMs,
                      ),
                    ),
                    if (_lastMessage != null)
                      Text(l10n.testMode_lastMessage(_lastMessage!)),
                    if (_continuousMode)
                      Text(l10n.testMode_packetCount(_sentCount)),
                  ],
                ],
              ),
            ),
            if (_log.isNotEmpty) ...[
              SectionHeader(l10n.testMode_recent),
              MeshCard(
                child: Column(
                  children: [
                    for (var i = 0; i < _log.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          _log[i].message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_log[i].flood ? l10n.testMode_logFlood : l10n.testMode_logDirect}'
                          ' · ${_log[i].timeoutMs} ms',
                        ),
                        trailing: Text(_formatTime(_log[i].at)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
