import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../core/gaia/gaia_client.dart';
import '../../core/gaia/gaia_constants.dart';
import '../../core/gaia/gaia_frame.dart';
import '../../core/transport/ble_transport.dart';
import '../../core/transport/transport.dart';
import 'upgrade_machine.dart';
import 'vm_upgrade.dart';

/// Real [UpgradeTransport] over GAIA/BLE. It owns a dedicated connection to the
/// device so it can tear down and reconnect across the reboot that happens
/// mid-upgrade. The caller must first release any other connection to the
/// device (one GAIA link at a time).
class GaiaUpgradeTransport implements UpgradeTransport {
  GaiaUpgradeTransport(
    this.device, {
    this.rebootWait = Hd350Params.rebootTimeout,
  });

  final BluetoothDevice device;
  final Duration rebootWait;

  BleGaiaTransport? _transport;
  GaiaClient? _client;
  StreamSubscription<GaiaMessage>? _notifSub;
  final _events = StreamController<VmPdu>.broadcast();

  @override
  Stream<VmPdu> get events => _events.stream;

  @override
  int get maxChunkBytes {
    final m = (_client?.maxPayload ?? 20) - 4; // VM header (3) + flag (1)
    return m < 8 ? 8 : m;
  }

  Future<void> _openSession() async {
    final t = BleGaiaTransport(device);
    await t.connect();
    final c = GaiaClient(t);
    _transport = t;
    _client = c;
    _notifSub = c.notifications.listen((m) {
      // Event notification (0x4003), VMUP event id 0x12, then the VM PDU.
      if (m.commandId == UpgradeGaia.eventNotification &&
          m.payload.isNotEmpty &&
          m.payload[0] == UpgradeGaia.vmupEventId) {
        final pdu = VmPdu.decode(m.payload.sublist(1));
        if (pdu != null && !_events.isClosed) _events.add(pdu);
      }
    });
  }

  Future<void> _closeSession() async {
    await _notifSub?.cancel();
    _notifSub = null;
    await _client?.dispose();
    try {
      await _transport?.disconnect();
    } catch (_) {}
    _client = null;
    _transport = null;
  }

  Future<void> _send(int commandId, [Uint8List? payload]) async {
    final c = _client;
    if (c == null) throw UpgradeError('not connected');
    await c.request(UpgradeGaia.vendor, commandId, payload: payload);
  }

  @override
  Future<void> connect() async {
    await _openSession();
    await _send(UpgradeGaia.connect);
  }

  @override
  Future<void> enable() async {
    // Upgrade_Enable is vendor 0x0494, not 0x000A.
    await _client!.request(UpgradeGaia.sennheiserVendor, UpgradeGaia.enable);
  }

  @override
  Future<void> registerEvents() => _send(
    UpgradeGaia.registerNotification,
    Uint8List.fromList([UpgradeGaia.vmupEventId]),
  );

  @override
  Future<void> disconnect() => _send(UpgradeGaia.disconnect);

  @override
  Future<void> sendControl(VmPdu pdu) =>
      _send(UpgradeGaia.control, pdu.encode());

  @override
  Future<int?> deviceBatteryPercent() async {
    try {
      final r = await _client!.send('Battery_GetPercent');
      return r.payload.isNotEmpty ? r.payload[0] : null;
    } catch (_) {
      return null;
    }
  }

  /// After the device reboots to apply the image: let it go, wait, then open a
  /// fresh session and re-enable/register. Retries the reconnect a few times
  /// because the device comes back a little after the reboot timeout.
  @override
  Future<void> awaitReconnect() async {
    await _closeSession();
    await Future<void>.delayed(rebootWait);
    Object? lastError;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        await _openSession();
        await _send(UpgradeGaia.connect);
        await enable();
        await registerEvents();
        return;
      } catch (e) {
        lastError = e;
        debugPrint('[upgrade] reconnect attempt ${attempt + 1} failed: $e');
        await _closeSession();
        await Future<void>.delayed(Hd350Params.waitBeforeReconnect);
      }
    }
    throw UpgradeError('could not reconnect after reboot: $lastError');
  }

  /// True while a live link exists.
  bool get isConnected => _transport?.currentState == TransportState.connected;

  Future<void> dispose() async {
    await _closeSession();
    await _events.close();
  }
}
