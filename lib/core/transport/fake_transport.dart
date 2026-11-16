import 'dart:async';
import 'dart:typed_data';

import '../gaia/gaia_constants.dart';
import 'transport.dart';

/// In-memory transport for tests and for replaying captured sessions.
///
/// [responder] is called for every written PDU and may return PDUs that the
/// "device" sends back.
class FakeGaiaTransport implements GaiaTransport {
  FakeGaiaTransport({
    this.responder,
    this.mtu = 247,
    this.protocol = GaiaProtocol.v2Le,
  });

  @override
  final GaiaProtocol protocol;

  List<Uint8List> Function(Uint8List written)? responder;
  @override
  final int mtu;

  final written = <Uint8List>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _state = StreamController<TransportState>.broadcast();
  TransportState _current = TransportState.disconnected;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;
  @override
  Stream<TransportState> get state => _state.stream;
  @override
  TransportState get currentState => _current;
  @override
  List<String> get discoveryReport => const ['fake transport'];

  /// Push an unsolicited PDU (e.g. a notification) from the device.
  void inject(Uint8List pdu) => _incoming.add(pdu);

  @override
  Future<void> connect() async {
    _current = TransportState.connected;
    _state.add(_current);
  }

  @override
  Future<void> write(Uint8List pdu) async {
    if (_current != TransportState.connected) {
      throw TransportException('Not connected');
    }
    written.add(pdu);
    final replies = responder?.call(pdu) ?? const [];
    for (final r in replies) {
      scheduleMicrotask(() => _incoming.add(r));
    }
  }

  @override
  Future<void> disconnect() async {
    _current = TransportState.disconnected;
    _state.add(_current);
  }
}
