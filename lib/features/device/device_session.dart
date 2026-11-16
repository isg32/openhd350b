import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/gaia/gaia_client.dart';
import '../../core/gaia/gaia_frame.dart';
import '../../core/transport/ble_transport.dart';
import '../../core/transport/transport.dart';
import '../equalizer/eq_engine.dart';

/// Snapshot of everything the dashboard/EQ screens show.
@immutable
class DeviceState {
  const DeviceState({
    this.model = 'HD 350BT',
    this.firmware,
    this.batteryPercent,
    this.charging = ChargingStatus.unknown,
    this.rssi,
    this.eqBands = const [0, 0, 0],
    this.bassBoost = false,
    this.customEqOn,
    this.audioMode,
    this.sidetone,
    this.connected = true,
  });

  final String model;
  final String? firmware;
  final int? batteryPercent;
  final ChargingStatus charging;
  final int? rssi;
  final List<double> eqBands;
  final bool bassBoost;
  final bool? customEqOn;
  final AudioMode? audioMode;
  final SidetoneState? sidetone;
  final bool connected;

  DeviceState copyWith({
    String? firmware,
    int? batteryPercent,
    ChargingStatus? charging,
    int? rssi,
    List<double>? eqBands,
    bool? bassBoost,
    bool? customEqOn,
    AudioMode? audioMode,
    SidetoneState? sidetone,
    bool? connected,
  }) => DeviceState(
    model: model,
    firmware: firmware ?? this.firmware,
    batteryPercent: batteryPercent ?? this.batteryPercent,
    charging: charging ?? this.charging,
    rssi: rssi ?? this.rssi,
    eqBands: eqBands ?? this.eqBands,
    bassBoost: bassBoost ?? this.bassBoost,
    customEqOn: customEqOn ?? this.customEqOn,
    audioMode: audioMode ?? this.audioMode,
    sidetone: sidetone ?? this.sidetone,
    connected: connected ?? this.connected,
  );
}

enum ChargingStatus { unknown, disconnected, charging, complete }

enum AudioMode {
  userEq(1),
  speech(2);

  const AudioMode(this.value);
  final int value;
  static AudioMode? fromValue(int v) =>
      values.where((m) => m.value == v).firstOrNull;
}

enum SidetoneState {
  off(0),
  min(1),
  max(2);

  const SidetoneState(this.value);
  final int value;
  static SidetoneState? fromValue(int v) =>
      values.where((s) => s.value == v).firstOrNull;
}

/// Owns the live [GaiaClient] and exposes typed, HD 350BT-specific reads and
/// writes over the verified command set. Set commands write then read back to
/// confirm the device accepted them.
class DeviceSession extends ChangeNotifier {
  DeviceSession(this.client, {this.firmwareFromGatt}) {
    _notifSub = client.notifications.listen(_onNotification);
    _stateSub = client.transport.state.listen((s) {
      if (s == TransportState.disconnected) {
        _state = _state.copyWith(connected: false);
        notifyListeners();
      }
    });
  }

  final GaiaClient client;

  /// Firmware string already read from the standard GATT characteristic.
  final String? firmwareFromGatt;

  final eq = const Hd350EqEngine();
  late final StreamSubscription<GaiaMessage> _notifSub;
  late final StreamSubscription<TransportState> _stateSub;

  DeviceState _state = const DeviceState();
  DeviceState get state => _state;

  void _set(DeviceState s) {
    _state = s;
    notifyListeners();
  }

  /// Reads everything the dashboard + EQ screens need, in sequence.
  Future<void> refreshAll() async {
    _set(_state.copyWith(firmware: firmwareFromGatt));
    await _guard(_readFirmware);
    await _guard(_readBattery);
    await _guard(_readCharging);
    await _guard(_readRssi);
    await _guard(_readEq);
    await _guard(_readCustomEqControl);
    await _guard(_readAudioMode);
    await _guard(_readSidetone);
  }

  Future<void> _guard(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      debugPrint('[session] read failed: $e');
    }
  }

  Future<void> _readFirmware() async {
    final p = (await client.send('Service_GetSystemReleaseVersion')).payload;
    if (p.length >= 6) {
      _set(
        _state.copyWith(
          firmware:
              '${(p[0] << 8) | p[1]}.${(p[2] << 8) | p[3]}.'
              '${(p[4] << 8) | p[5]}',
        ),
      );
    }
  }

  Future<void> _readBattery() async {
    final p = (await client.send('Battery_GetPercent')).payload;
    if (p.isNotEmpty) _set(_state.copyWith(batteryPercent: p[0]));
  }

  Future<void> _readCharging() async {
    final p = (await client.send('Battery_GetChargingStatus')).payload;
    if (p.isNotEmpty) {
      _set(
        _state.copyWith(
          charging:
              ChargingStatus.values.elementAtOrNull(p[0] + 1) ??
              ChargingStatus.unknown,
        ),
      );
    }
  }

  Future<void> _readRssi() async {
    final p = (await client.send('V2_GetCurrentRssi')).payload;
    if (p.isNotEmpty) {
      _set(_state.copyWith(rssi: p[0] >= 128 ? p[0] - 256 : p[0]));
    }
  }

  Future<void> _readEq() async {
    final x = (await client.send(
      'Sound_GetCustomEQKnob',
      payload: Hd350EqEngine.knobPayload(0, 0),
    )).payload;
    final y = (await client.send(
      'Sound_GetCustomEQKnob',
      payload: Hd350EqEngine.knobPayload(1, 0),
    )).payload;
    if (x.length >= 2 && y.length >= 2) {
      final decoded = eq.decodeKnobs((x[0] << 8) | x[1], (y[0] << 8) | y[1]);
      if (decoded != null) {
        _set(
          _state.copyWith(eqBands: decoded.bands, bassBoost: decoded.bassBoost),
        );
      } else {
        _set(_state.copyWith(eqBands: const [0, 0, 0], bassBoost: false));
      }
    }
  }

  Future<void> _readCustomEqControl() async {
    final p = (await client.send('Sound_GetCustomEQControl')).payload;
    if (p.isNotEmpty) _set(_state.copyWith(customEqOn: p[0] == 1));
  }

  Future<void> _readAudioMode() async {
    final p = (await client.send('AudioMode_Get')).payload;
    if (p.length >= 2) {
      _set(_state.copyWith(audioMode: AudioMode.fromValue((p[0] << 8) | p[1])));
    }
  }

  Future<void> _readSidetone() async {
    final p = (await client.send('Sidetone_GetState')).payload;
    if (p.isNotEmpty) {
      _set(_state.copyWith(sidetone: SidetoneState.fromValue(p[0])));
    }
  }

  // ---- Writes (still candidate IDs; allowCandidate + read-back) ----

  ({List<double> bands, bool bassBoost})? _pendingEq;
  bool _applyingEq = false;

  /// Applies 3-band EQ. Calls are coalesced: while one apply is in flight,
  /// further requests only update the pending target, so a fast drag sends
  /// its start and final value rather than every intermediate one.
  Future<void> applyEq(List<double> bands, {required bool bassBoost}) async {
    final clipped = eq.clip(bands);
    _set(_state.copyWith(eqBands: clipped, bassBoost: bassBoost));
    _pendingEq = (bands: clipped, bassBoost: bassBoost);
    if (_applyingEq) return;
    _applyingEq = true;
    try {
      while (_pendingEq != null) {
        final next = _pendingEq!;
        _pendingEq = null;
        await _sendEq(next.bands, next.bassBoost);
      }
    } finally {
      _applyingEq = false;
    }
  }

  /// One EQ apply: shelf params (0x021B) then the two knob writes, mirroring
  /// the official app's `send()`.
  Future<void> _sendEq(List<double> bands, bool bassBoost) async {
    final params = eq.customEqParams(bands, bassBoost: bassBoost);
    try {
      await client.send(
        'Sound_SetCustomEQ',
        payload: Hd350EqEngine.packU16(params),
        allowCandidate: true,
      );
    } on GaiaErrorResponse catch (e) {
      // The HD 350BT answers SetCustomEQ with status 6 ("incorrect state")
      // as a matter of course; the official app ignores it and still writes
      // the knob values, which are what commit the EQ. Anything else is a
      // real failure.
      if (e.message.status != 6) rethrow;
      debugPrint('[session] SetCustomEQ status 6 (expected); writing knobs');
    }
    final knobs = eq.encodeKnobs(bands, bassBoost: bassBoost);
    await client.send(
      'Sound_SetCustomEQKnob',
      payload: Hd350EqEngine.knobPayload(0, knobs.x),
      allowCandidate: true,
    );
    await client.send(
      'Sound_SetCustomEQKnob',
      payload: Hd350EqEngine.knobPayload(1, knobs.y),
      allowCandidate: true,
    );
  }

  Future<void> setCustomEqOn(bool on) async {
    _set(_state.copyWith(customEqOn: on));
    await client.send(
      'Sound_SetCustomEQControl',
      payload: Uint8List.fromList([on ? 1 : 0]),
      allowCandidate: true,
    );
  }

  Future<void> setAudioMode(AudioMode mode) async {
    _set(_state.copyWith(audioMode: mode));
    await client.send(
      'AudioMode_Set',
      payload: Uint8List.fromList([0x00, mode.value]),
      allowCandidate: true,
    );
  }

  Future<void> setSidetone(SidetoneState s) async {
    _set(_state.copyWith(sidetone: s));
    await client.send(
      'Sidetone_SetState',
      payload: Uint8List.fromList([s.value]),
      allowCandidate: true,
    );
  }

  void _onNotification(GaiaMessage m) {
    // Event payload: [event id, ...]. Battery level = 0x83, charger = 0x09.
    if (m.payload.isEmpty) return;
    switch (m.payload[0]) {
      case 0x09: // charger event
        _guard(_readCharging);
        _guard(_readBattery);
      case 0x83: // battery level changed
        _guard(_readBattery);
    }
  }

  @override
  void dispose() {
    _notifSub.cancel();
    _stateSub.cancel();
    super.dispose();
  }
}

extension SessionProtocol on DeviceSession {
  bool get isV2 =>
      client.transport is BleGaiaTransport &&
      (client.transport as BleGaiaTransport).protocol != null;
}
