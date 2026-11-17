import 'dart:typed_data';

/// Qualcomm VM-Upgrade protocol for the HD 350BT, tunnelled through GAIA v2.
/// Opcodes, resume points and the PDU format were recovered from Smart
/// Control 4.7.0 (`hd350.json` gaia_upgrade_id + bundle.js). See the
/// vm-upgrade-protocol memory for the full map.
///
/// A VM PDU is `[opcode(1)][length BE16][payload]`, carried in GAIA command
/// `0x000A/0x0642` (control) or in a `0x000A/0x4003` event notification.

/// GAIA command IDs used by the upgrade.
abstract final class UpgradeGaia {
  static const vendor = 0x000A;
  static const sennheiserVendor = 0x0494;

  static const enable = 0x0202; // vendor 0x0494
  static const registerNotification = 0x4001; // + event id
  static const cancelNotification = 0x4002;
  static const connect = 0x0640;
  static const disconnect = 0x0641;
  static const control = 0x0642;
  static const eventNotification = 0x4003;

  /// Event id for VM-upgrade notifications.
  static const vmupEventId = 0x12;
}

/// VM-Upgrade message opcodes.
abstract final class UpOp {
  // app -> device
  static const startReq = 0x01;
  static const data = 0x04;
  static const abortReq = 0x07;
  static const transferCompleteRes = 0x0C;
  static const proceedToCommit = 0x0E;
  static const commitCfm = 0x10;
  static const syncReq = 0x13;
  static const startDataReq = 0x15;
  static const isValidationDoneReq = 0x16;
  static const errorRes = 0x1F;

  // device -> app
  static const startCfm = 0x02;
  static const dataBytesReq = 0x03;
  static const abortCfm = 0x08;
  static const transferCompleteInd = 0x0B;
  static const commitReq = 0x0F;
  static const errorInd = 0x11;
  static const completeInd = 0x12;
  static const syncCfm = 0x14;
  static const isValidationDoneCfm = 0x17;
}

/// SYNC_CFM resume points — where the device wants to continue.
abstract final class ResumePoint {
  static const start = 0; // transfer the whole image
  static const preValidate = 1; // data done, validate
  static const preReboot = 2; // validated, reboot
  static const postReboot = 3; // rebooted, commit
  static const postCommit = 4; // done
}

abstract final class Validation {
  static const ok = 0;
  static const fail = 1;
}

/// The unique file identifier the app sends in SYNC_REQ (constant `fwFileUID`).
const upgradeFileId = 0x12345678;

/// A decoded VM-Upgrade PDU.
class VmPdu {
  VmPdu(this.opcode, [Uint8List? payload]) : payload = payload ?? Uint8List(0);

  final int opcode;
  final Uint8List payload;

  /// `[opcode][length BE16][payload]`.
  Uint8List encode() {
    final out = Uint8List(3 + payload.length);
    out[0] = opcode;
    out[1] = (payload.length >> 8) & 0xFF;
    out[2] = payload.length & 0xFF;
    out.setRange(3, out.length, payload);
    return out;
  }

  /// Returns null if [bytes] isn't a well-formed PDU (header + declared length).
  static VmPdu? decode(List<int> bytes) {
    if (bytes.length < 3) return null;
    final len = (bytes[1] << 8) | bytes[2];
    if (bytes.length < 3 + len) return null;
    return VmPdu(bytes[0], Uint8List.fromList(bytes.sublist(3, 3 + len)));
  }

  // ---- Builders (app -> device) ----

  static VmPdu syncReq(int fileId) {
    final p = Uint8List(4);
    ByteData.sublistView(p).setUint32(0, fileId);
    return VmPdu(UpOp.syncReq, p);
  }

  static VmPdu startReq() => VmPdu(UpOp.startReq);
  static VmPdu startDataReq() => VmPdu(UpOp.startDataReq);
  static VmPdu isValidationDoneReq() => VmPdu(UpOp.isValidationDoneReq);
  static VmPdu abortReq() => VmPdu(UpOp.abortReq);

  /// `[flag][image bytes]`; flag=1 only on the final chunk of the image.
  static VmPdu data(int flag, Uint8List chunk) {
    final p = Uint8List(1 + chunk.length);
    p[0] = flag;
    p.setRange(1, p.length, chunk);
    return VmPdu(UpOp.data, p);
  }

  static VmPdu transferCompleteRes(int action) =>
      VmPdu(UpOp.transferCompleteRes, Uint8List.fromList([action]));
  static VmPdu proceedToCommit(int action) =>
      VmPdu(UpOp.proceedToCommit, Uint8List.fromList([action]));
  static VmPdu commitCfm(int action) =>
      VmPdu(UpOp.commitCfm, Uint8List.fromList([action]));

  // ---- Parsers (device -> app) ----

  /// SYNC_CFM `[resumePoint u8][fileId u32][protoVer u8]`.
  int get syncResumePoint => payload.isNotEmpty ? payload[0] : -1;

  /// START_CFM `[status u8][battery u16]`.
  int get startStatus => payload.isNotEmpty ? payload[0] : -1;

  /// DATA_BYTES_REQ `[numBytes u32][offset u32]`.
  ({int numBytes, int offset})? get dataBytesReq {
    if (payload.length < 8) return null;
    final v = ByteData.sublistView(payload);
    return (numBytes: v.getUint32(0), offset: v.getUint32(4));
  }

  /// IS_VALIDATION_DONE_CFM `[delay u16]`; >0 means wait and retry.
  int get validationDelayMs =>
      payload.length >= 2 ? (payload[0] << 8) | payload[1] : 0;

  /// ERROR_IND `[code u16]`.
  int get errorCode => payload.length >= 2 ? (payload[0] << 8) | payload[1] : 0;
}
