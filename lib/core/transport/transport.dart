import 'dart:typed_data';

import '../gaia/gaia_constants.dart';

enum TransportState { disconnected, connecting, connected }

/// A byte pipe to a GAIA device. One `write` = one GAIA PDU; each item on
/// [incoming] = one GAIA PDU from the device.
abstract class GaiaTransport {
  Stream<Uint8List> get incoming;
  Stream<TransportState> get state;
  TransportState get currentState;

  /// GAIA version spoken by the device. Known once connected.
  GaiaProtocol? get protocol;

  /// Negotiated ATT MTU (BLE). Used to size payloads.
  int get mtu;

  /// Human-readable lines describing what was discovered on connect
  /// (services/characteristics/properties). Shown in the debug console to
  /// help resolve unknowns such as the bulk-data characteristic.
  List<String> get discoveryReport;

  Future<void> connect();
  Future<void> write(Uint8List pdu);
  Future<void> disconnect();
}

class TransportException implements Exception {
  TransportException(this.message);
  final String message;
  @override
  String toString() => 'TransportException: $message';
}
