import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../transport/transport.dart';
import 'command_table.dart';
import 'gaia_constants.dart';
import 'gaia_frame.dart';

enum PduDirection { tx, rx }

/// One raw PDU seen on the wire, for the debug console and capture export.
class PduLogEntry {
  PduLogEntry(this.direction, this.bytes, this.message) : time = DateTime.now();

  final PduDirection direction;
  final DateTime time;
  final Uint8List bytes;

  /// Null if the bytes didn't parse as a GAIA message.
  final GaiaMessage? message;
}

class GaiaErrorResponse implements Exception {
  GaiaErrorResponse(this.message);
  final GaiaMessage message;
  @override
  String toString() => 'GAIA error (status=${message.status}) for $message';
}

class UnsendableCommandException implements Exception {
  UnsendableCommandException(this.message);
  final String message;
  @override
  String toString() => 'UnsendableCommandException: $message';
}

/// GAIA request/response layer on top of a connected [GaiaTransport].
///
/// Replies are matched to the oldest outstanding request with the same
/// vendor + command. Notifications go to [notifications].
class GaiaClient {
  GaiaClient(this.transport)
    : protocol =
          transport.protocol ??
          (throw ArgumentError('Transport protocol unknown; connect first')),
      codec = GaiaCodec.forProtocol(transport.protocol!) {
    _sub = transport.incoming.listen(_onIncoming);
  }

  final GaiaTransport transport;
  final GaiaProtocol protocol;
  final GaiaCodec codec;
  late final StreamSubscription<Uint8List> _sub;

  final _pending = <int, Queue<Completer<GaiaMessage>>>{};
  final _notifications = StreamController<GaiaMessage>.broadcast();
  final _log = StreamController<PduLogEntry>.broadcast();

  Stream<GaiaMessage> get notifications => _notifications.stream;
  Stream<PduLogEntry> get log => _log.stream;

  int get maxPayload => codec.maxPayloadForMtu(transport.mtu);

  void _onIncoming(Uint8List bytes) {
    final m = codec.decode(bytes);
    _log.add(PduLogEntry(PduDirection.rx, bytes, m));
    if (m == null) return;

    switch (m.type) {
      case GaiaPacketType.notification:
        _notifications.add(m);
      case GaiaPacketType.response:
      case GaiaPacketType.error:
        final q = _pending[m.key];
        if (q == null || q.isEmpty) return; // unsolicited; logged above
        final c = q.removeFirst();
        if (q.isEmpty) _pending.remove(m.key);
        m.type == GaiaPacketType.error
            ? c.completeError(GaiaErrorResponse(m))
            : c.complete(m);
      case GaiaPacketType.command:
        break; // device-originated command; logged only
    }
  }

  /// Writes raw bytes without expecting a reply. For the debug console.
  Future<void> sendRaw(Uint8List bytes) async {
    _log.add(PduLogEntry(PduDirection.tx, bytes, codec.decode(bytes)));
    await transport.write(bytes);
  }

  /// Sends a command and waits for its acknowledgement/response.
  Future<GaiaMessage> request(
    int vendorId,
    int commandId, {
    Uint8List? payload,
    Duration timeout = const Duration(seconds: 5),
    // Lets a caller (the firmware upgrade) send a payload larger than the ATT
    // MTU allows, relying on the transport's GATT long write. Defaults to the
    // MTU-derived limit for every ordinary command.
    int? maxPayloadOverride,
  }) async {
    final limit = maxPayloadOverride ?? maxPayload;
    if ((payload?.length ?? 0) > limit) {
      throw ArgumentError('Payload ${payload!.length} B exceeds max $limit B');
    }
    final bytes = codec.encodeCommand(vendorId, commandId, payload);
    final key = (vendorId << 16) | commandId;
    final completer = Completer<GaiaMessage>();
    _pending.putIfAbsent(key, Queue.new).add(completer);
    // A timer completes the single completer directly, rather than
    // `future.timeout()` which detaches on timeout and leaves a later error
    // on the original future unhandled.
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _forget(key, completer);
        completer.completeError(
          TimeoutException(
            'No reply to vendor 0x${vendorId.toRadixString(16)} '
            'cmd 0x${commandId.toRadixString(16)}',
            timeout,
          ),
        );
      }
    });
    try {
      await sendRaw(bytes);
    } catch (e) {
      _forget(key, completer);
      if (!completer.isCompleted) completer.completeError(e);
    }
    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  void _forget(int key, Completer<GaiaMessage> c) {
    final q = _pending[key];
    if (q == null) return;
    q.remove(c);
    if (q.isEmpty) _pending.remove(key);
  }

  /// Sends a named command from [gaiaCommands].
  ///
  /// Unresolved commands and commands for another protocol are refused.
  /// Candidate IDs require [allowCandidate]. Destructive commands require
  /// verified IDs.
  Future<GaiaMessage> send(
    String name, {
    Uint8List? payload,
    bool allowCandidate = false,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final def = gaiaCommandsByName[name];
    if (def == null) throw UnsendableCommandException('Unknown command $name');
    if (!def.hasIds || def.status == CommandStatus.unresolved) {
      throw UnsendableCommandException('$name has no resolved IDs yet');
    }
    if (def.protocol != protocol) {
      throw UnsendableCommandException(
        '$name is a ${def.protocol!.name} command; device speaks '
        '${protocol.name}',
      );
    }
    if (def.status == CommandStatus.candidate) {
      if (def.destructive) {
        throw UnsendableCommandException(
          '$name is destructive and must be verified first',
        );
      }
      if (!allowCandidate) {
        throw UnsendableCommandException(
          '$name IDs are unverified candidates; pass allowCandidate',
        );
      }
    }
    return request(
      def.vendorId!,
      def.commandId!,
      payload: payload,
      timeout: timeout,
    );
  }

  Future<void> dispose() async {
    await _sub.cancel();
    for (final q in _pending.values) {
      for (final c in q) {
        c.completeError(TransportException('Client disposed'));
      }
    }
    _pending.clear();
    await _notifications.close();
    await _log.close();
  }
}
