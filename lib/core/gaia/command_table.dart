import 'gaia_constants.dart';

/// How much we trust a command's numeric IDs.
enum CommandStatus {
  /// IDs unknown. Cannot be sent.
  unresolved,

  /// IDs taken from public Qualcomm GAIA docs but not yet seen working on
  /// this device. Sendable only with `allowCandidate` (debug console), and
  /// never for destructive commands.
  candidate,

  /// IDs confirmed against a real HD 350BT (live probe or HCI capture).
  verified,
}

class GaiaCommandDef {
  const GaiaCommandDef(
    this.name, {
    this.protocol,
    this.vendorId,
    this.commandId,
    this.status = CommandStatus.unresolved,
    this.destructive = false,
    this.note,
  });

  final String name;

  /// Which GAIA version the IDs belong to. Null while unresolved.
  final GaiaProtocol? protocol;
  final int? vendorId;

  /// v2: 15-bit command ID. v3: `featureId << 7 | commandId`.
  final int? commandId;
  final CommandStatus status;

  /// Changes persistent device state in a way that's hard to undo (reset,
  /// firmware, pairing list). Only ever sent once [CommandStatus.verified].
  final bool destructive;
  final String? note;

  bool get hasIds => protocol != null && vendorId != null && commandId != null;
}

/// Qualcomm/CSR vendor ID for standard GAIA v1/v2 commands.
const qualcommV2Vendor = 0x000A;

/// Qualcomm's GAIA v3 vendor ID for the standard feature set.
const qualcommV3Vendor = 0x001D;

const _v2Doc = 'Qualcomm GAIA v2 (public docs). Verify before relying on it.';
const _v3Doc =
    'Qualcomm GAIA v3 Core feature (public docs). Not present on '
    'HD 350BT, which speaks v2.';

/// Sennheiser's GAIA vendor ID (HD 350BT proprietary commands).
const sennheiserVendor = 0x0494;

const _apk = 'From Smart Control 4.7.0 hd350.json; not yet probed.';
const _probed = 'Verified by live probe on HD 350BT fw 5.8.0, 2026-11-16.';

/// Every command name the official app uses (build-spec §4, §8, §11), plus
/// standard GAIA commands confirmed on the device.
///
/// Fill IDs from the HCI capture (docs/hci-capture.md) and flip each entry to
/// [CommandStatus.verified]. Leave anything unseen as unresolved.
const List<GaiaCommandDef> gaiaCommands = [
  // ---- Standard GAIA v2 status commands (verified on HD 350BT) ----
  GaiaCommandDef(
    'V2_GetApiVersion',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0300,
    status: CommandStatus.verified,
    note: '$_probed Reply: protocol 1, API 2.5',
  ),
  GaiaCommandDef(
    'V2_GetCurrentRssi',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0301,
    status: CommandStatus.verified,
    note: '$_probed Reply: signed dBm',
  ),
  GaiaCommandDef(
    'V2_GetBatteryLevel',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0302,
    status: CommandStatus.verified,
    note: '$_probed Reply: uint16 millivolts',
  ),
  GaiaCommandDef(
    'V2_GetModuleId',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0303,
    status: CommandStatus.verified,
    note: '$_probed Reply: 8 zero bytes',
  ),
  GaiaCommandDef(
    'V2_GetApplicationVersion',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0304,
    status: CommandStatus.verified,
    note: '$_probed Reply ends in ASCII "580"',
  ),
  GaiaCommandDef(
    'V2_RegisterNotification',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x4001,
    status: CommandStatus.candidate,
    note: _v2Doc,
  ),
  GaiaCommandDef(
    'V2_CancelNotification',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x4002,
    status: CommandStatus.candidate,
    note: _v2Doc,
  ),

  // ---- Qualcomm v3 Core (kept for v3 devices) ----
  GaiaCommandDef(
    'Core_GetApiVersion',
    protocol: GaiaProtocol.v3,
    vendorId: qualcommV3Vendor,
    commandId: 0x00,
    status: CommandStatus.candidate,
    note: _v3Doc,
  ),
  GaiaCommandDef(
    'Core_GetSupportedFeatures',
    protocol: GaiaProtocol.v3,
    vendorId: qualcommV3Vendor,
    commandId: 0x01,
    status: CommandStatus.candidate,
    note: _v3Doc,
  ),
  GaiaCommandDef(
    'Core_GetSerialNumber',
    protocol: GaiaProtocol.v3,
    vendorId: qualcommV3Vendor,
    commandId: 0x03,
    status: CommandStatus.candidate,
    note: _v3Doc,
  ),
  GaiaCommandDef(
    'Core_GetVariant',
    protocol: GaiaProtocol.v3,
    vendorId: qualcommV3Vendor,
    commandId: 0x04,
    status: CommandStatus.candidate,
    note: _v3Doc,
  ),
  GaiaCommandDef(
    'Core_GetApplicationVersion',
    protocol: GaiaProtocol.v3,
    vendorId: qualcommV3Vendor,
    commandId: 0x05,
    status: CommandStatus.candidate,
    note: _v3Doc,
  ),
  GaiaCommandDef(
    'Core_GetTransportInfo',
    protocol: GaiaProtocol.v3,
    vendorId: qualcommV3Vendor,
    commandId: 0x0C,
    status: CommandStatus.candidate,
    note: _v3Doc,
  ),
  GaiaCommandDef('Core_DataTransferSetup'),
  GaiaCommandDef('Core_DataTransferGet'),

  // ---- HD 350BT commands from Smart Control 4.7.0 hd350.json ----
  // Sennheiser vendor 0x0494 unless noted. Replies are cmd | 0x8000.
  GaiaCommandDef(
    'Service_GetSystemReleaseVersion',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0280,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT fw 5.8.0: 04 94 82 80 00 0000 0005 0008 -> 5.8.0. UINT16 major, minor, patch.',
  ),
  GaiaCommandDef(
    'Battery_GetPercent',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0182,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT: 04 94 81 82 00 64 00 -> 100%. UINT8 level (+trailing byte).',
  ),
  GaiaCommandDef(
    'Battery_GetChargingStatus',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0185,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT: 04 94 81 85 00 00 00 -> disconnected. UINT8 0=disc 1=charging 2=complete.',
  ),
  GaiaCommandDef(
    'Sound_GetCustomEQKnob',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0685,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT: payload UINT16 index (0=X,1=Y); reply UINT16 value (knob X=0).',
  ),
  GaiaCommandDef(
    'Sound_SetCustomEQKnob',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0605,
    status: CommandStatus.candidate,
    note: '$_apk Payload: UINT16 index, UINT16 value',
  ),
  GaiaCommandDef(
    'Sound_GetCustomEQControl',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x02A0,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT: 00 0A 82 A0 00 01 -> on. UINT8 1=on 0=off. (Qualcomm vendor 0x000A.)',
  ),
  GaiaCommandDef(
    'Sound_SetCustomEQControl',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0220,
    status: CommandStatus.candidate,
    note: '$_apk Payload: UINT8 1=on 0=off',
  ),
  GaiaCommandDef(
    'Sound_SetCustomEQ',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x021B,
    status: CommandStatus.candidate,
    note:
        '$_apk EQ_UserParameterGroup_Set. Payload: UINT16[] '
        '(param-id/value pairs)',
  ),
  GaiaCommandDef(
    'AudioMode_Get',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0786,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT: 04 94 87 86 00 00 01 -> user EQ. UINT16 1=user EQ 2=speech.',
  ),
  GaiaCommandDef(
    'AudioMode_Set',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0706,
    status: CommandStatus.candidate,
    note: '$_apk Payload: UINT16 1=user EQ 2=speech',
  ),
  GaiaCommandDef(
    'Sidetone_GetState',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0787,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT: 04 94 87 87 00 02 -> max. UINT8 0=off 1=min 2=max. Needs fw >= 5.6.2.',
  ),
  GaiaCommandDef(
    'Sidetone_SetState',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0707,
    status: CommandStatus.candidate,
    note: '$_apk Payload: UINT8 0=off 1=min 2=max',
  ),
  GaiaCommandDef(
    'Service_FactoryReset',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0101,
    status: CommandStatus.candidate,
    destructive: true,
    note: _apk,
  ),
  GaiaCommandDef(
    'Upgrade_Enable',
    protocol: GaiaProtocol.v2Le,
    vendorId: sennheiserVendor,
    commandId: 0x0202,
    status: CommandStatus.candidate,
    destructive: true,
    note: '$_apk Reply: UINT8 upgrade status',
  ),

  // Notifications (Qualcomm 0x000A): payload = event ID.
  // Event IDs on HD 350BT: 0x09 charger, 0x83 battery level,
  // 0x81 upgrade status, 0x12 VM upgrade.
  GaiaCommandDef(
    'V2_GetNotification',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x4081,
    status: CommandStatus.verified,
    note: 'Verified on HD350BT: 00 0A C0 81 05 -> 5 registered events. Payload: UINT8 event ID.',
  ),

  // ---- Names from the spec not present in hd350.json (other models) ----
  GaiaCommandDef('Service_ProductId'),
  GaiaCommandDef('Service_USBSerial'),
  GaiaCommandDef('Service_HardwareRevision'),
  GaiaCommandDef('System_CurrentCodec'),

  // ---- VM-Upgrade (§8) — all destructive, verified-only ----
  GaiaCommandDef(
    'V2_VmUpgradeConnect',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0640,
    status: CommandStatus.candidate,
    destructive: true,
    note: _v2Doc,
  ),
  GaiaCommandDef(
    'V2_VmUpgradeDisconnect',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0641,
    status: CommandStatus.candidate,
    destructive: true,
    note: _v2Doc,
  ),
  GaiaCommandDef(
    'V2_VmUpgradeControl',
    protocol: GaiaProtocol.v2Le,
    vendorId: qualcommV2Vendor,
    commandId: 0x0642,
    status: CommandStatus.candidate,
    destructive: true,
    note: _v2Doc,
  ),
  GaiaCommandDef('Upgrade_Connect', destructive: true),
  GaiaCommandDef('RegisterNotification_upgrade', destructive: true),
  GaiaCommandDef('Upgrade_GaiaSync', destructive: true),
  GaiaCommandDef('Upgrade_GaiaStart', destructive: true),
  GaiaCommandDef('Upgrade_GaiaStartData', destructive: true),
  GaiaCommandDef('Upgrade_GaiaData', destructive: true),
  GaiaCommandDef('Upgrade_TransferComplete', destructive: true),
  GaiaCommandDef('Upgrade_TransferComplete_Trigger', destructive: true),
  GaiaCommandDef('Upgrade_GaiaIsValidationDone', destructive: true),
  GaiaCommandDef('Upgrade_ProceedToCommit', destructive: true),
  GaiaCommandDef('Upgrade_CommitCfm', destructive: true),
  GaiaCommandDef('Upgrade_Activate', destructive: true),
  GaiaCommandDef('Upgrade_Abort', destructive: true),
  GaiaCommandDef('Upgrade_ErrorConfirmation', destructive: true),
  GaiaCommandDef('Upgrade_GetPartitionHandle', destructive: true),
  GaiaCommandDef('Upgrade_GetPartitionInfo', destructive: true),
  GaiaCommandDef('Upgrade_NumPartitionHandles', destructive: true),
];

final Map<String, GaiaCommandDef> gaiaCommandsByName = {
  for (final c in gaiaCommands) c.name: c,
};

/// Reverse lookup used by the debug console to label packets.
GaiaCommandDef? lookupCommand(
  GaiaProtocol protocol,
  int vendorId,
  int commandId,
) {
  for (final c in gaiaCommands) {
    if (c.protocol == protocol &&
        c.vendorId == vendorId &&
        c.commandId == commandId) {
      return c;
    }
  }
  return null;
}
