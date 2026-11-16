import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gaia/command_table.dart';
import '../core/gaia/gaia_client.dart';
import '../core/gaia/gaia_constants.dart';
import '../core/gaia/gaia_frame.dart';
import '../core/hex.dart';
import '../core/transport/transport.dart';

/// Raw GAIA console: shows every PDU in both directions, lets you send hex,
/// and probes the safe (non-destructive) commands for the device's protocol.
class DebugConsoleScreen extends StatefulWidget {
  const DebugConsoleScreen({
    super.key,
    required this.client,
    required this.title,
  });

  final GaiaClient client;
  final String title;

  @override
  State<DebugConsoleScreen> createState() => _DebugConsoleScreenState();
}

class _DebugConsoleScreenState extends State<DebugConsoleScreen> {
  final _entries = <_Line>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final StreamSubscription<PduLogEntry> _logSub;
  late final StreamSubscription<TransportState> _stateSub;
  late TransportState _state;
  late final List<GaiaCommandDef> _probes;

  GaiaProtocol get _protocol => widget.client.protocol;

  @override
  void initState() {
    super.initState();
    final t = widget.client.transport;
    _state = t.currentState;
    _probes = gaiaCommands
        .where(
          (c) =>
              c.protocol == _protocol &&
              c.status != CommandStatus.unresolved &&
              !c.destructive &&
              c.name.contains('Get'),
        )
        .toList();
    for (final line in t.discoveryReport) {
      _add(_Line.info(line));
    }
    _logSub = widget.client.log.listen((e) => _add(_Line.pdu(e, _protocol)));
    _stateSub = t.state.listen((s) {
      setState(() => _state = s);
      _add(_Line.info('transport ${s.name}'));
    });
  }

  @override
  void dispose() {
    _logSub.cancel();
    _stateSub.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _add(_Line line) {
    debugPrint('[GAIA] ${line.display()}');
    if (!mounted) return;
    setState(() => _entries.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _sendRaw() async {
    try {
      final bytes = fromHex(_input.text);
      if (bytes.isEmpty) return;
      await widget.client.sendRaw(bytes);
    } catch (e) {
      _add(_Line.error('$e'));
    }
  }

  bool _sweeping = false;

  /// Default payloads so a verification probe sends something the device
  /// accepts (e.g. the EQ-knob get needs an index).
  static final _verifyPayload = <String, Uint8List>{
    'Sound_GetCustomEQKnob': Uint8List.fromList([0x00, 0x00]), // index 0 = X
  };

  Future<void> _probe(GaiaCommandDef def) async {
    try {
      final rsp = await widget.client.send(
        def.name,
        allowCandidate: true,
        payload: _verifyPayload[def.name],
      );
      _add(_Line.info('${def.name} → ${_interpret(def.name, rsp.payload)}'));
    } catch (e) {
      _add(_Line.error('${def.name}: $e'));
    }
  }

  /// Fires every read/get probe in sequence. Only reads — never sets,
  /// factory reset, or firmware commands.
  Future<void> _verifyReads() async {
    setState(() => _sweeping = true);
    _add(_Line.info('── verifying ${_probes.length} read commands ──'));
    for (final def in _probes) {
      if (!mounted) break;
      await _probe(def);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _add(_Line.info('── done; copy the log and send it back ──'));
    if (mounted) setState(() => _sweeping = false);
  }

  /// Human-readable value for the verified v2 status commands.
  static String _interpret(String name, List<int> p) {
    switch (name) {
      case 'V2_GetApiVersion' when p.length >= 3:
        return 'protocol ${p[0]}, API ${p[1]}.${p[2]}';
      case 'V2_GetCurrentRssi' when p.isNotEmpty:
        return '${p[0] >= 128 ? p[0] - 256 : p[0]} dBm';
      case 'V2_GetBatteryLevel' when p.length >= 2:
        return '${(p[0] << 8) | p[1]} mV';
      case 'Service_GetSystemReleaseVersion' when p.length >= 6:
        return 'fw ${(p[0] << 8) | p[1]}.${(p[2] << 8) | p[3]}.'
            '${(p[4] << 8) | p[5]}  (expect 5.8.0)';
      case 'Battery_GetPercent' when p.isNotEmpty:
        return '${p[0]}%';
      case 'Battery_GetChargingStatus' when p.isNotEmpty:
        return const [
              'disconnected',
              'charging',
              'complete',
            ].elementAtOrNull(p[0]) ??
            'status ${p[0]}';
      case 'Sound_GetCustomEQKnob' when p.length >= 2:
        return 'knob X = ${(p[0] << 8) | p[1]}';
      case 'Sound_GetCustomEQControl' when p.isNotEmpty:
        return p[0] == 1 ? 'custom EQ on' : 'custom EQ off';
      case 'AudioMode_Get' when p.length >= 2:
        final v = (p[0] << 8) | p[1];
        return v == 1
            ? 'user EQ'
            : v == 2
            ? 'speech/podcast'
            : 'mode $v';
      case 'Sidetone_GetState' when p.isNotEmpty:
        return const ['off', 'min', 'max'].elementAtOrNull(p[0]) ??
            'sidetone ${p[0]}';
    }
    return '[${toHex(p)}]${_ascii(p)}';
  }

  static String _ascii(List<int> b) {
    final tail = b.reversed.takeWhile((c) => c >= 0x20 && c < 0x7F).toList();
    return tail.length >= 3
        ? '  "…${String.fromCharCodes(tail.reversed)}"'
        : '';
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(
      ClipboardData(text: _entries.map((e) => e.display()).join('\n')),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Log copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context).textTheme.bodySmall
        ?.copyWith(fontFamily: 'monospace');
    final connected = _state == TransportState.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Text(
            '${_state.name} · GAIA ${_protocol.name} · '
            'MTU ${widget.client.transport.mtu}',
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Verify read commands',
            onPressed: connected && !_sweeping ? _verifyReads : null,
            icon: _sweeping
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check_outlined),
          ),
          IconButton(
            tooltip: 'Copy log',
            onPressed: _copyLog,
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: () => setState(_entries.clear),
            icon: const Icon(Icons.delete_sweep),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final p in _probes)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ActionChip(
                      avatar: p.status == CommandStatus.verified
                          ? const Icon(Icons.verified, size: 16)
                          : null,
                      label: Text(
                        p.name
                            .replaceFirst(RegExp(r'^(V2_|Core_)'), '')
                            .replaceFirst('Get', ''),
                      ),
                      onPressed: connected ? () => _probe(p) : null,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: _entries.length,
              itemBuilder: (_, i) {
                final e = _entries[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: SelectableText(
                    e.display(),
                    style: mono?.copyWith(color: e.color),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      style: mono,
                      decoration: const InputDecoration(
                        hintText: 'Raw hex PDU, e.g. 000A0300',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendRaw(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: connected ? _sendRaw : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Kind { tx, rx, info, error }

class _Line {
  _Line._(this.kind, this.text, this.time);

  factory _Line.pdu(PduLogEntry e, GaiaProtocol protocol) {
    final dir = e.direction == PduDirection.tx ? _Kind.tx : _Kind.rx;
    var text = toHex(e.bytes);
    final m = e.message;
    if (m != null) {
      final name = lookupCommand(protocol, m.vendorId, m.commandId)?.name;
      text += '\n    ${_describe(m)}${name != null ? '  ($name)' : ''}';
    }
    return _Line._(dir, text, e.time);
  }

  factory _Line.info(String t) => _Line._(_Kind.info, t, DateTime.now());
  factory _Line.error(String t) => _Line._(_Kind.error, t, DateTime.now());

  final _Kind kind;
  final String text;
  final DateTime time;

  static String _describe(GaiaMessage m) {
    String h(int v, int w) => v.toRadixString(16).padLeft(w, '0');
    return 'v=${h(m.vendorId, 4)} cmd=${h(m.commandId, 4)} ${m.type.name}'
        '${m.status != null ? ' status=${m.status}' : ''}'
        '${m.payload.isNotEmpty ? ' payload=[${toHex(m.payload)}]' : ''}';
  }

  String get _ts => time.toIso8601String().substring(11, 23);

  String display() => switch (kind) {
    _Kind.tx => '$_ts → $text',
    _Kind.rx => '$_ts ← $text',
    _Kind.info => '$_ts · $text',
    _Kind.error => '$_ts ! $text',
  };

  Color? get color => switch (kind) {
    _Kind.tx => Colors.blue,
    _Kind.rx => Colors.green,
    _Kind.info => null,
    _Kind.error => Colors.red,
  };
}
