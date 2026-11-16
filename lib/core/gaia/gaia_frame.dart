import 'dart:typed_data';

import '../hex.dart';
import 'gaia_constants.dart';

/// Kind of GAIA message, common to v2 and v3.
enum GaiaPacketType {
  command(0),
  notification(1),
  response(2),
  error(3);

  const GaiaPacketType(this.bits);

  /// v3 header encoding (bits 8..7 of the command description).
  final int bits;

  static GaiaPacketType fromBits(int bits) =>
      values.firstWhere((t) => t.bits == bits);
}

/// A decoded GAIA message, independent of protocol version.
///
/// [commandId] is the protocol-specific command number:
///  * v2: the 15-bit command ID (ack bit stripped), e.g. `0x0302`
///  * v3: `featureId << 7 | commandId`
class GaiaMessage {
  GaiaMessage({
    required this.vendorId,
    required this.commandId,
    required this.type,
    Uint8List? payload,
    this.status,
  }) : payload = payload ?? Uint8List(0);

  final int vendorId;
  final int commandId;
  final GaiaPacketType type;

  /// Payload after the header and (for replies) after the status byte.
  final Uint8List payload;

  /// GAIA status byte of a reply; 0 = success. Null for commands and
  /// notifications.
  final int? status;

  /// Matches a reply to the request that caused it.
  int get key => (vendorId << 16) | commandId;

  @override
  String toString() =>
      'GaiaMessage(v=0x${vendorId.toRadixString(16).padLeft(4, '0')}, '
      'cmd=0x${commandId.toRadixString(16).padLeft(4, '0')}, ${type.name}'
      '${status != null ? ', status=$status' : ''}, '
      'payload=[${toHex(payload)}])';
}

/// Encodes commands and decodes device messages for one GAIA version.
abstract class GaiaCodec {
  const GaiaCodec();

  factory GaiaCodec.forProtocol(GaiaProtocol p) => switch (p) {
    GaiaProtocol.v2Le => const GaiaV2Codec(),
    GaiaProtocol.v3 => const GaiaV3Codec(),
  };

  static const headerLength = 4;

  Uint8List encodeCommand(int vendorId, int commandId, [Uint8List? payload]);

  /// Returns null if [bytes] isn't a well-formed message.
  GaiaMessage? decode(List<int> bytes);

  /// Largest command payload that fits in one ATT write.
  int maxPayloadForMtu(int mtu) => mtu - 3 - headerLength;
}

/// GAIA v1/v2 PDU (no SOF/length framing over BLE):
///
/// ```
/// byte 0..1  vendor ID              (big-endian)
/// byte 2..3  command ID             (big-endian, bit 15 = acknowledgement)
/// byte 4     status                 (acknowledgements only; 0 = success)
/// byte 4/5.. payload
/// ```
///
/// Confirmed on a real HD 350BT: `00 0A 03 02` → `00 0A 83 02 00 10 3E`.
class GaiaV2Codec extends GaiaCodec {
  const GaiaV2Codec();

  static const ackFlag = 0x8000;

  /// Standard "event notification" command; unsolicited events arrive with
  /// this ID.
  static const eventNotification = 0x4003;

  @override
  Uint8List encodeCommand(int vendorId, int commandId, [Uint8List? payload]) {
    RangeError.checkValueInInterval(vendorId, 0, 0xFFFF, 'vendorId');
    RangeError.checkValueInInterval(commandId, 0, 0x7FFF, 'commandId');
    final p = payload ?? Uint8List(0);
    final out = Uint8List(GaiaCodec.headerLength + p.length);
    ByteData.sublistView(out)
      ..setUint16(0, vendorId)
      ..setUint16(2, commandId);
    out.setRange(GaiaCodec.headerLength, out.length, p);
    return out;
  }

  @override
  GaiaMessage? decode(List<int> bytes) {
    if (bytes.length < GaiaCodec.headerLength) return null;
    final data = Uint8List.fromList(bytes);
    final view = ByteData.sublistView(data);
    final vendor = view.getUint16(0);
    final raw = view.getUint16(2);
    final id = raw & 0x7FFF;
    if (raw & ackFlag != 0) {
      if (data.length < 5) return null; // ack without status byte
      final status = data[4];
      return GaiaMessage(
        vendorId: vendor,
        commandId: id,
        type: status == 0 ? GaiaPacketType.response : GaiaPacketType.error,
        status: status,
        payload: Uint8List.sublistView(data, 5),
      );
    }
    return GaiaMessage(
      vendorId: vendor,
      commandId: id,
      type: id == eventNotification
          ? GaiaPacketType.notification
          : GaiaPacketType.command,
      payload: Uint8List.sublistView(data, GaiaCodec.headerLength),
    );
  }
}

/// GAIA v3 PDU (Qualcomm public docs; not yet seen on real hardware):
///
/// ```
/// byte 0..1  vendor ID (big-endian)
/// byte 2..3  feature(7) · type(2) · command(7)
/// byte 4     status (error packets only)
/// byte 4/5.. payload
/// ```
class GaiaV3Codec extends GaiaCodec {
  const GaiaV3Codec();

  static int combine(int featureId, int commandId) {
    RangeError.checkValueInInterval(featureId, 0, 0x7F, 'featureId');
    RangeError.checkValueInInterval(commandId, 0, 0x7F, 'commandId');
    return (featureId << 7) | commandId;
  }

  @override
  Uint8List encodeCommand(int vendorId, int commandId, [Uint8List? payload]) =>
      _encode(vendorId, commandId, GaiaPacketType.command, payload);

  Uint8List _encode(
    int vendorId,
    int commandId,
    GaiaPacketType type,
    Uint8List? payload,
  ) {
    RangeError.checkValueInInterval(vendorId, 0, 0xFFFF, 'vendorId');
    RangeError.checkValueInInterval(commandId, 0, 0x3FFF, 'commandId');
    final p = payload ?? Uint8List(0);
    final feature = commandId >> 7;
    final cmd = commandId & 0x7F;
    final out = Uint8List(GaiaCodec.headerLength + p.length);
    ByteData.sublistView(out)
      ..setUint16(0, vendorId)
      ..setUint16(2, (feature << 9) | (type.bits << 7) | cmd);
    out.setRange(GaiaCodec.headerLength, out.length, p);
    return out;
  }

  /// Builds a device-side packet of any type. For tests and replay.
  Uint8List encode(
    int vendorId,
    int commandId,
    GaiaPacketType type, [
    Uint8List? payload,
  ]) => _encode(vendorId, commandId, type, payload);

  @override
  GaiaMessage? decode(List<int> bytes) {
    if (bytes.length < GaiaCodec.headerLength) return null;
    final data = Uint8List.fromList(bytes);
    final view = ByteData.sublistView(data);
    final desc = view.getUint16(2);
    final type = GaiaPacketType.fromBits((desc >> 7) & 0x03);
    final id = (((desc >> 9) & 0x7F) << 7) | (desc & 0x7F);
    final isError = type == GaiaPacketType.error;
    return GaiaMessage(
      vendorId: view.getUint16(0),
      commandId: id,
      type: type,
      status: isError && data.length > 4 ? data[4] : null,
      payload: Uint8List.sublistView(
        data,
        isError && data.length > 4 ? 5 : GaiaCodec.headerLength,
      ),
    );
  }
}
