import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../gaia/gaia_constants.dart';
import '../hex.dart';
import 'transport.dart';

/// GAIA over BLE GATT.
///
/// Supports both layouts:
///  * v3 — service `63331337…`, write `…133B`, notify `…133C` (build-spec §3a)
///  * v2-over-LE — service `0xFDCE`, command `…1338`, response `…1339`
///    (what a real HD 350BT exposes)
class BleGaiaTransport implements GaiaTransport {
  BleGaiaTransport(this.device);

  final BluetoothDevice device;

  final _incoming = StreamController<Uint8List>.broadcast();
  final _state = StreamController<TransportState>.broadcast();
  TransportState _current = TransportState.disconnected;
  final List<String> _report = [];
  GaiaProtocol? _protocol;

  BluetoothCharacteristic? _writeChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final List<StreamSubscription<List<int>>> _notifySubs = [];

  @override
  Stream<Uint8List> get incoming => _incoming.stream;
  @override
  Stream<TransportState> get state => _state.stream;
  @override
  TransportState get currentState => _current;
  @override
  int get mtu => device.mtuNow;
  @override
  List<String> get discoveryReport => List.unmodifiable(_report);

  @override
  GaiaProtocol? get protocol => _protocol;

  void _setState(TransportState s) {
    _current = s;
    _state.add(s);
  }

  void _log(String line) {
    _report.add(line);
    // ignore: avoid_print
    print('[GATT] $line');
  }

  @override
  Future<void> connect() async {
    _setState(TransportState.connecting);
    _report.clear();
    try {
      // Personal / open-source use. See the FlutterBluePlus license.
      await device.connect(license: License.nonprofit, mtu: 512);
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            _current != TransportState.disconnected) {
          _teardown();
        }
      });

      // The connect-time `mtu:` request is unreliable on Android; ask again
      // explicitly. A larger ATT MTU means larger firmware-upgrade packets,
      // which the device needs (it rejects both small fragments and long
      // writes). Best-effort: some stacks ignore it.
      _log('MTU after connect: ${device.mtuNow}');
      try {
        final granted = await device.requestMtu(512);
        _log('MTU after explicit request: $granted');
      } catch (e) {
        _log('requestMtu failed: $e');
      }

      final services = await device.discoverServices();
      _log('MTU: ${device.mtuNow}');
      for (final s in services) {
        _log('service ${s.uuid.str128}');
        for (final c in s.characteristics) {
          final p = c.properties;
          final flags = [
            if (p.read) 'read',
            if (p.write) 'write',
            if (p.writeWithoutResponse) 'writeNoRsp',
            if (p.notify) 'notify',
            if (p.indicate) 'indicate',
          ].join(',');
          _log('  char ${c.uuid.str128} [$flags]');
        }
      }

      await _readStandardInfo(services);

      BluetoothCharacteristic? find(String svc, String chr) {
        for (final s in services.where((s) => s.uuid == Guid(svc))) {
          for (final c in s.characteristics) {
            if (c.uuid == Guid(chr)) return c;
          }
        }
        return null;
      }

      BluetoothCharacteristic? notifyChar;
      final v3Write = find(GaiaUuids.service, GaiaUuids.write);
      final v3Notify = find(GaiaUuids.service, GaiaUuids.notify);
      final v2Cmd = find(GaiaLeV2Uuids.service, GaiaLeV2Uuids.command);
      final v2Rsp = find(GaiaLeV2Uuids.service, GaiaLeV2Uuids.response);
      if (v3Write != null && v3Notify != null) {
        _protocol = GaiaProtocol.v3;
        _writeChar = v3Write;
        notifyChar = v3Notify;
      } else if (v2Cmd != null && v2Rsp != null) {
        _protocol = GaiaProtocol.v2Le;
        _writeChar = v2Cmd;
        notifyChar = v2Rsp;
      } else {
        throw TransportException(
          'No GAIA service found. Discovered:\n${_report.join('\n')}',
        );
      }
      _log('GAIA protocol: ${_protocol!.name}');

      // Pair up-front. Writing to the GAIA command characteristic needs an
      // encrypted link, so the OS otherwise starts pairing on the first
      // write — and a failure there once made Android DELETE the existing
      // bond. Bonding explicitly here keeps that out of the command path.
      await _ensureBonded();

      final sub = notifyChar.onValueReceived.listen(
        (v) => _incoming.add(Uint8List.fromList(v)),
      );
      device.cancelWhenDisconnected(sub);
      _notifySubs.add(sub);
      await notifyChar.setNotifyValue(true);

      // Also watch the v2 data / unknown endpoints so their traffic shows up
      // in the log (not fed to the GAIA client).
      if (_protocol == GaiaProtocol.v2Le) {
        for (final uuid in [GaiaLeV2Uuids.data, GaiaLeV2Uuids.unknown]) {
          final c = find(GaiaLeV2Uuids.service, uuid);
          if (c == null || !c.properties.notify) continue;
          final short = uuid.substring(4, 8);
          final s = c.onValueReceived.listen(
            (v) => _log('notify $short: ${toHex(v)}'),
          );
          device.cancelWhenDisconnected(s);
          _notifySubs.add(s);
          try {
            await c.setNotifyValue(true);
          } catch (e) {
            _log('notify $short enable failed: $e');
          }
        }
      }

      _setState(TransportState.connected);
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  /// Ensures the device is bonded before any encrypted write. Android only;
  /// iOS/macOS bond automatically when an encrypted characteristic is first
  /// accessed. Safe to call when already bonded.
  Future<void> _ensureBonded() async {
    if (!Platform.isAndroid) return;
    final state = await device.bondState.first;
    _log('bond state: ${state.name}');
    if (state == BluetoothBondState.bonded) return;
    _log('creating bond…');
    await device.createBond();
    final now = await device.bondState
        .firstWhere((s) => s != BluetoothBondState.bonding)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => BluetoothBondState.none,
        );
    _log('bond result: ${now.name}');
    if (now != BluetoothBondState.bonded) {
      throw TransportException(
        'Pairing failed (${now.name}); not writing, to protect the bond',
      );
    }
  }

  Future<void> _readStandardInfo(List<BluetoothService> services) async {
    for (final s in services) {
      for (final c in s.characteristics) {
        final label = standardReadableChars[c.uuid.str128];
        if (label == null || !c.properties.read) continue;
        try {
          final v = await c.read();
          final printable =
              v.isNotEmpty && v.every((b) => b >= 0x20 && b < 0x7F);
          final text = label == 'Battery level' && v.length == 1
              ? '${v[0]}%'
              : printable
              ? utf8.decode(v)
              : toHex(v);
          _log('$label: $text');
        } catch (e) {
          _log('$label: read failed ($e)');
        }
      }
    }
  }

  @override
  Future<void> write(Uint8List pdu) async {
    final c = _writeChar;
    if (c == null || _current != TransportState.connected) {
      throw TransportException('Not connected');
    }
    // The device's GATT server rejects long (queued) writes
    // (GATT_REQUEST_NOT_SUPPORTED), so a PDU must fit the negotiated ATT MTU.
    if (pdu.length > mtu - 3) {
      throw TransportException(
        'PDU of ${pdu.length} bytes exceeds MTU payload ${mtu - 3}',
      );
    }
    await c.write(pdu, withoutResponse: !c.properties.write);
  }

  @override
  Future<void> disconnect() async {
    try {
      await device.disconnect();
    } finally {
      _teardown();
    }
  }

  void _teardown() {
    for (final s in _notifySubs) {
      s.cancel();
    }
    _notifySubs.clear();
    _connSub?.cancel();
    _connSub = null;
    _writeChar = null;
    if (_current != TransportState.disconnected) {
      _setState(TransportState.disconnected);
    }
  }
}
