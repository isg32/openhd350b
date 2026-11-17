import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/gaia/gaia_client.dart';
import '../../core/gaia/gaia_constants.dart';
import '../../core/transport/ble_transport.dart';
import '../../core/transport/transport.dart';
import 'device_session.dart';

enum ConnectionPhase {
  idle,
  needsPermission,
  searching,
  connecting,
  connected,
  failed,
}

/// Owns the connection lifecycle to an HD 350BT: finds the bonded device,
/// connects, and exposes the live [DeviceSession]. Used by the home screen to
/// auto-connect on launch and reconnect after a drop.
class ConnectionController extends ChangeNotifier {
  ConnectionPhase phase = ConnectionPhase.idle;
  String? error;

  BleGaiaTransport? _transport;
  GaiaClient? _client;
  DeviceSession? _session;
  StreamSubscription<TransportState>? _stateSub;

  DeviceSession? get session => _session;
  bool get isConnected =>
      phase == ConnectionPhase.connected && _session != null;

  void _set(ConnectionPhase p, {String? err}) {
    phase = p;
    error = err;
    notifyListeners();
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final modern =
        (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
        (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
    return modern ||
        (statuses[Permission.locationWhenInUse]?.isGranted ?? false);
  }

  /// Finds a bonded / system HD 350BT and connects to it. Falls back to a
  /// short BLE scan if it isn't already known to the system.
  Future<void> autoConnect() async {
    if (phase == ConnectionPhase.connecting ||
        phase == ConnectionPhase.connected) {
      return;
    }
    _set(ConnectionPhase.searching);
    if (!await _ensurePermissions()) {
      _set(
        ConnectionPhase.needsPermission,
        err: 'Bluetooth permission is required',
      );
      return;
    }
    if (Platform.isAndroid &&
        FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      final s = await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
      if (s != BluetoothAdapterState.on) {
        _set(ConnectionPhase.failed, err: 'Bluetooth is ${s.name}');
        return;
      }
    }

    final device = await _findKnownDevice();
    if (device == null) {
      _set(
        ConnectionPhase.failed,
        err: 'HD 350BT not found. Pair it in Bluetooth settings, then retry.',
      );
      return;
    }
    await connectTo(device);
  }

  Future<BluetoothDevice?> _findKnownDevice() async {
    bool isHd350(String name) =>
        hd350NamePrefixes.any((p) => name.startsWith(p));

    // Already bonded to the phone (preferred — no scan needed).
    try {
      final bonded = await FlutterBluePlus.bondedDevices;
      final hit = bonded.where((d) => isHd350(d.platformName)).firstOrNull;
      if (hit != null) return hit;
    } catch (_) {}

    // Exposes the GAIA service to the system.
    try {
      final sys = await FlutterBluePlus.systemDevices([
        Guid(GaiaLeV2Uuids.service),
        Guid(GaiaUuids.service),
      ]);
      if (sys.isNotEmpty) return sys.first;
    } catch (_) {}

    // Last resort: a short scan.
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      final completer = Completer<BluetoothDevice?>();
      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          if (isHd350(name) && !completer.isCompleted) {
            completer.complete(r.device);
          }
        }
      });
      final found = await completer.future.timeout(
        const Duration(seconds: 9),
        onTimeout: () => null,
      );
      await sub.cancel();
      await FlutterBluePlus.stopScan();
      return found;
    } catch (_) {
      return null;
    }
  }

  /// Connects to a specific device and brings up a session.
  Future<void> connectTo(BluetoothDevice device) async {
    await _teardown();
    _set(ConnectionPhase.connecting);
    final transport = BleGaiaTransport(device);
    try {
      await transport.connect();
      final client = GaiaClient(transport);
      final fw = transport.discoveryReport
          .where((l) => l.startsWith('Firmware revision:'))
          .map((l) => l.split(':').last.trim())
          .where((v) => v.isNotEmpty)
          .firstOrNull;
      final session = DeviceSession(client, firmwareFromGatt: fw);
      _transport = transport;
      _client = client;
      _session = session;
      _stateSub = transport.state.listen((s) {
        if (s == TransportState.disconnected) {
          _set(ConnectionPhase.failed, err: 'Disconnected');
        }
      });
      _set(ConnectionPhase.connected);
      await session.refreshAll();
    } catch (e) {
      await _teardown();
      _set(ConnectionPhase.failed, err: 'Connect failed: $e');
    }
  }

  Future<void> disconnect() async {
    await _teardown();
    _set(ConnectionPhase.idle);
  }

  Future<void> _teardown() async {
    await _stateSub?.cancel();
    _stateSub = null;
    _session?.dispose();
    await _client?.dispose();
    await _transport?.disconnect();
    _session = null;
    _client = null;
    _transport = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
