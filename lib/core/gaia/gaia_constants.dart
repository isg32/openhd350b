/// GAIA transport identifiers confirmed from Smart Control 4.7.0 (build-spec §3, §11).
abstract final class GaiaUuids {
  /// GAIA BLE service.
  static const service = '63331337-23c1-11e5-b696-feff819cdc9f';

  /// GAIA v3 command characteristic (app -> device).
  static const write = '6333133b-23c1-11e5-b696-feff819cdc9f';

  /// GAIA v3 response/notification characteristic (device -> app).
  static const notify = '6333133c-23c1-11e5-b696-feff819cdc9f';

  /// Classic RFCOMM/SPP GAIA service (v1/v2 fallback).
  static const spp = 'a2129ff3-081b-4c45-8afe-469d9c4842eb';
}

/// GAIA v1/v2-over-BLE layout observed on a real HD 350BT (2026-11-16).
/// The spec's v3 service above is NOT present on that device.
abstract final class GaiaLeV2Uuids {
  /// 16-bit SIG-assigned service 0xFDCE.
  static const service = '0000fdce-0000-1000-8000-00805f9b34fb';

  /// Command endpoint [write].
  static const command = '63331338-23c1-11e5-b696-feff819cdc9f';

  /// Response endpoint [read, notify].
  static const response = '63331339-23c1-11e5-b696-feff819cdc9f';

  /// Data endpoint [read, writeNoRsp, notify] — likely bulk/upgrade data.
  static const data = '6333133a-23c1-11e5-b696-feff819cdc9f';

  /// Unknown [read, write, notify]. Purpose TBD from the HCI capture.
  static const unknown = '63331379-23c1-11e5-b696-feff819cdc9f';
}

/// Which GAIA flavour the connected device speaks.
enum GaiaProtocol { v3, v2Le }

/// Standard GATT Device Information (0x180A) and Battery (0x180F) fields.
const standardReadableChars = {
  '00002a29-0000-1000-8000-00805f9b34fb': 'Manufacturer',
  '00002a24-0000-1000-8000-00805f9b34fb': 'Model number',
  '00002a25-0000-1000-8000-00805f9b34fb': 'Serial number',
  '00002a27-0000-1000-8000-00805f9b34fb': 'Hardware revision',
  '00002a26-0000-1000-8000-00805f9b34fb': 'Firmware revision',
  '00002a28-0000-1000-8000-00805f9b34fb': 'Software revision',
  '00002a23-0000-1000-8000-00805f9b34fb': 'System ID',
  '00002a50-0000-1000-8000-00805f9b34fb': 'PnP ID',
  '00002a19-0000-1000-8000-00805f9b34fb': 'Battery level',
};

/// Advertised-name prefixes for the HD 350BT.
const hd350NamePrefixes = ['HD 350', 'LE-HD 350'];

/// HD 350BT update parameters from `hd350.json` (build-spec §1).
abstract final class Hd350Params {
  static const articleNumber = '300002';
  static const minDeviceBatteryPercent = 20;
  static const minPhoneBatteryPercent = 20;
  static const rebootTimeout = Duration(milliseconds: 15000);
  static const waitBeforeReconnect = Duration(milliseconds: 5000);
}
