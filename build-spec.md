# OpenSennheiser — Build Specification

An open-source replacement for the **Sennheiser Smart Control** app, targeting the
**HD 350BT (model SEBT3, article 300002)** and other Qualcomm-GAIA Sennheiser headphones.

This document is a complete build brief. It was produced by reverse-engineering Smart
Control **4.7.0** (a NativeScript app; logic lives in `assets/app/bundle.js`). Everything
marked **[CONFIRMED]** was read directly out of that bundle. Everything marked
**[RESOLVE]** is a known gap that must be filled from the public Qualcomm GAIA v3 spec
or a one-time Bluetooth HCI capture (method in §9). Nothing here requires defeating a
security control — see §8.

---

## 0. Scope / definition of done

Build a cross-platform app (recommended: **Python + Bleak** for a reference CLI/daemon,
or **TypeScript + Web Bluetooth** for a GUI) that can, against a real HD 350BT:

1. Scan, connect, and read device data (model, serial, firmware version, battery, codec).
2. Read and write the equalizer.
3. Read/set audio mode, sidetone, device name; trigger factory reset.
4. Fetch the latest official firmware from Sennheiser's cloud and decrypt it.
5. Install that firmware onto the headphones via the GAIA VM-Upgrade protocol.

Non-goal: running **modified/unsigned** firmware. The chip validates the image signature
on-device (§8); this app installs **official signed** images only.

---

## 1. Target device facts [CONFIRMED]

| Fact | Value |
|---|---|
| Marketing name | Sennheiser HD 350BT |
| Model code | SEBT3 |
| Article number | `300002` (used by the firmware cloud API) |
| Internal device-type enum | `HD350 = 22`, `HD350_B = 23` (black), `HD350_W` (white) |
| BLE advertised name prefix | `LE-HD 350…` (also pairs as `HD 350BT`) |
| Bluetooth | 5.0, classic + BLE |
| Codecs | SBC, AAC, aptX, aptX LL |
| SoC family | Qualcomm QCC (GAIA/GAIA3 protocol; exact part TBD by teardown) |
| Control protocol | `"protocol": "GAIA"` (from `hd350.json`) |
| EQ model | custom EQ via `Sound_CustomEQControl` + `Sound_CustomEQKnobX/Y` and `Sound_SetCustomEQ` |

Per-device update parameters (from `hd350.json` → `parameters`) [CONFIRMED]:
```
updateDeviceMinBatteryLevel: 20      # refuse update below 20% on the headphones
updatePhoneMinBatteryLevel: 20       # refuse update below 20% on the phone
updateRebootTimeout: 15000 ms
updateWaitBeforeReconnect: 5000 ms
updateTimeBleSinglePartition: ~20 min (BLE transfer estimate)
single-partition upgrade, battery index [0]
```

---

## 2. Recommended architecture

```
+-------------------------------------------------------------+
|  UI layer (CLI first; GUI optional: Web Bluetooth / Flutter)|
+-------------------------------------------------------------+
|  Feature services                                           |
|   DeviceInfo | Battery | Equalizer | AudioMode | Firmware    |
+-------------------------------------------------------------+
|  GAIA core:  framing + request/response + notifications      |
|   - GAIA v3 over BLE (primary)                               |
|   - GAIA v1/v2 over RFCOMM/SPP (fallback/classic)            |
+-------------------------------------------------------------+
|  Transport:  Bleak (BLE GATT)  /  PyBluez or socket (SPP)    |
+-------------------------------------------------------------+
|  Cloud:  firmware download + AES-CTR decrypt (see §7)        |
+-------------------------------------------------------------+
```

Build the **GAIA core + DeviceInfo read** first and get a live connection printing the
firmware version. Everything else is additive.

---

## 3. Transport layer — GAIA [CONFIRMED UUIDs]

The headphones speak Qualcomm **GAIA**. Two transports; implement BLE first.

### 3a. BLE (GAIA v3) — primary
GATT service + characteristics (exact UUIDs from the bundle):

| Role | UUID |
|---|---|
| GAIA BLE service | `63331337-23C1-11E5-B696-FEFF819CDC9F` |
| GAIA v3 **write** (command → device) | `6333133B-23C1-11E5-B696-FEFF819CDC9F` |
| GAIA v3 **read/notify** (device → app) | `6333133C-23C1-11E5-B696-FEFF819CDC9F` |
| GAIA BLE data (bulk/upgrade data) | `63331337…`-family data char (enable notify) |

Flow: connect GATT → enable notifications on the read/notify char → write commands to the
write char → parse notifications. The bundle also references a `SONOVA_SERVICE` /
`SENNHEISER_SERVICE` alias that maps to the same GAIA service on these devices.

### 3b. Classic SPP (GAIA v1/v2) — fallback
RFCOMM service UUID (GAIA SPP): `a2129ff3-081b-4c45-8afe-469d9c4842eb`
Use for classic-Bluetooth control if BLE is unavailable. Same command semantics, older
framing.

### 3c. GAIA v3 frame format [RESOLVE numeric header; structure CONFIRMED]
Commands are built as a binary header the bundle constructs via a `DataView`:
```
setUint16(offset 0, moduleID)        # a.k.a. vendor/feature module
... submoduleID, commandID ...       # from the protocol definition object
payload bytes follow
```
In the bundle each command object exposes `moduleID`, `Nautilus_submodule_ID` (hex),
`Nautilus_command_ID` (hex), and a human `PI_command_name`. These numeric IDs are **not
literals in the JS** — they come from a protocol-definition object. **[RESOLVE]** the
exact `featureId/commandId` per command from either:
  (a) the public **Qualcomm GAIA v3 API** spec (command names below map 1:1), or
  (b) a Bluetooth HCI capture of one real session (§9).

---

## 4. Device-control command surface [CONFIRMED names]

These are the `model.*.invoke([...])` commands the app issues. Group them into services.
Names follow Qualcomm GAIA v3; resolve IDs per §3c/§9.

### 4a. Device info / service
```
Service_SystemReleaseVersion   # current firmware version string  <-- read this first
Service_ProductId / Service_ProductIdNumber
Service_DeviceId
Service_USBSerial              # serial number
Service_HardwareRevision       # -> hw_revision for the cloud API
Service_SoftwareVersion / Service_BtStackVersion / Service_VmkitVersion
Service_ProtocolVersion
Service_FactoryReset
Core_GetTransportInfo          # GAIA v3 Core feature: MTU / transport caps
Core_DataTransferSetup / Core_DataTransferGet
```

### 4b. Battery
```
Battery_Percent                # 0..100
Battery_ChargingStatus
Battery_ChargerEvent / Battery_ChargerEvent_Register
Battery_LevelChangedEvtRegister / Battery_LevelChangedEvtCancel   # subscribe to changes
```

### 4c. Equalizer (HD 350 specifics)
```
Sound_CustomEQControl          # enable/disable custom EQ
Sound_CustomEQKnobX            # HD350 uses an X/Y "warmth/bass" style control...
Sound_CustomEQKnobY
Sound_SetCustomEQ / Sound_GetCustomEQ
Sound_SetEQParamGroup / Sound_GetCustomEQParam   # generic N-band path (other models)
UserEQ_GetSliderGain
```
Behavior notes from the app [CONFIRMED]:
- Band gains are floats; the app rounds to 0.1 dB and applies a fade on change.
- "Neutral" = all bands 0. There is a device-side "store EQ + turn EQ off" path.
- Read sequence polls `Sound_GetCustomEQParam` per band until all bands returned.

### 4d. Audio / misc
```
AudioMode                      # audio mode value
SidetoneState / sidetone_value
AudioPrompt_GetAvailableAudioPromptsLanguages / VoicePrompt_Language_Reselect
PairedDevices* (GetDeviceInfo, ConnectDevice, DeleteEntry, DeleteList, ...)
Setting_TriggerWlanScan / Setting_ConnectWlan        # soundbar-family only; ignore for HD350
Statistics_GetAvailableCategories / Statistics_GetAllStatisticsInCategory
```

---

## 5. Device data read — first milestone

1. Scan for a device whose name starts with `HD 350` / `LE-HD 350`.
2. Connect GATT; discover the GAIA service `63331337-…`; enable notify on `6333133C-…`.
3. `Core_GetTransportInfo` to learn MTU/segmentation.
4. Read `Service_SystemReleaseVersion`, `Service_USBSerial`, `Service_HardwareRevision`,
   `Battery_Percent`, `System_CurrentCodec`.
5. Print them. When this works, the transport + framing are correct and everything else
   is just more commands.

---

## 6. Equalizer — second milestone

- On connect: read current band values (§4c) and render.
- On change: send new gains via `Sound_SetCustomEQ` / `Sound_SetEQParamGroup`; debounce
  ~300 ms (the app does) and apply the fade.
- Presets: the app stores presets app-side (JSON) and just pushes band values; replicate
  by shipping a presets file. `EQUALIZER_PRESETS` is an app concept, not a device command.

---

## 7. Firmware — fetch + decrypt [FULLY CONFIRMED]

### 7a. Cloud API
Base: `https://api.s-consumer-cloud.com/firmware/api/v2`
(QA base: `https://api.quality.s-consumer-cloud.com/firmware/api/v2`)

Check for updates (GET; **no API key** is attached for firmware functions):
```
GET {base}/updates/{hardwareIdentifier}/{currentSystemRelease}
      ?hw_revision={rev}
      &osType=android&osVersion={v}&appVersion=4.7.0&appFlavor=prod
```
- `hardwareIdentifier` / `currentSystemRelease` / `hw_revision` come from the device
  (§4a: `Service_*`). `articleNumber=300002` is used for `availableSystemReleases`.
- Response: `data.packages[]`, each with `url`, `filename`, `identifier`, `version`,
  `size`, plus `data.smartctrl_compatibility`.
- Other functions on the same base: `systemRelease`, `packages`, `package`,
  `availableSystemReleases`, `firmwarecompatibility`, `appUpdate`.

Download: GET the package `url` (a `*.zip.enc` on `firmware.s-consumer-cloud.com`).

### 7b. Decrypt  [CONFIRMED — key is hardcoded in the app]
```
cipher     = AES-256-CTR
key  (hex) = ed3b78a474c2acabb812407b97065649bf190e3d758e86f17b920aa41d8c271e
counter    = 128-bit, initial value = 5 (big-endian)
```
`decrypt(.zip.enc) -> .zip -> unzip -> firmware image` (+ a sibling `.md5`).
A tested reference implementation is in the companion file `sennheiser_fw.py`
(`check` / `fetch` / `decrypt` subcommands). Reuse its `decrypt_enc()` verbatim.

---

## 8. Firmware INSTALL — GAIA VM-Upgrade [sequence CONFIRMED; opcodes RESOLVE]

This is Qualcomm's standard **VM Upgrade** sub-protocol tunnelled through GAIA. The app's
state machine (names all CONFIRMED from the bundle) runs in this order:

```
preconditions: headphone battery >= 20%, phone battery >= 20%, charging checks
1.  Upgrade_Connect / Upgrade_Enable / RegisterNotification_upgrade
2.  Upgrade_GaiaSync          -> returns a RESUME POINT (supports resuming a partial update)
3.  Upgrade_GaiaStart
4.  Upgrade_GaiaStartData
5.  loop: device sends Upgrade_GaiaDataBytesRequest(offset,len)
         app replies Upgrade_GaiaData(<chunk>)        # chunked image transfer
6.  Upgrade_TransferComplete  (device: Upgrade_CompleteInd)
7.  Upgrade_TransferComplete_Trigger([1,0])           # tell device to validate
8.  poll Upgrade_GaiaIsValidationDone  until Upgrade_GaiaIsValidationDone_Cfm
       -> VALIDATION_RESULT_OK (0)  or  VALIDATION_RESULT_FAIL (1)
9.  if OK: Upgrade_ProceedToCommit -> Upgrade_CommitReq (device) -> Upgrade_CommitCfm (app)
10. Upgrade_Activate ; device reboots (wait updateRebootTimeout=15s, reconnect after 5s)
    on error at any point: Upgrade_Abort / Upgrade_ErrorConfirmation, device ROLLS BACK
```

Progress states [CONFIRMED values]:
```
UPGRADE_MODE_IDLE = 0
UPGRADE_READY_FOR_UPGRADE = 1
UPGRADE_PROGRESS_RECEIVING = 2
UPGRADE_PROGRESS_SENDING = 3
UPGRADE_PROGRESS_VALIDATING = 4
UPGRADE_PROGRESS_FINISHED = 5
VALIDATION_RESULT_OK = 0 ; VALIDATION_RESULT_FAIL = 1
```
Partition handling commands exist (`Upgrade_GetPartitionHandle/Info`,
`Upgrade_NumPartitionHandles`) — HD350 is single-partition per its config.

**[RESOLVE]** the numeric VM-Upgrade message opcodes (UPGRADE_START_REQ, _DATA_BYTES_REQ,
_DATA, _TRANSFER_COMPLETE_IND, _COMMIT_REQ, _IS_VALIDATION_DONE_REQ, …). These are fixed
by Qualcomm's VM-Upgrade spec; take them from that spec and **verify against a capture**
(§9) before writing to the device.

### Security reality (do not design around this)
The **headphones validate the image signature themselves** at step 8 and only commit if it
passes; a bad/modified image yields `VALIDATION_RESULT_FAIL` and an automatic rollback.
The app is not the gatekeeper and never was, so no app-side change enables unsigned
firmware. This project therefore installs **official signed images only**. (Running custom
firmware would require board-level access to the QCC debug port and is explicitly out of
scope for this app.)

---

## 9. Resolving the [RESOLVE] gaps — one HCI capture

The only missing pieces are the numeric GAIA/VM-Upgrade opcodes. Capture them once:

1. On an Android phone: Developer Options → **Enable Bluetooth HCI snoop log**.
2. Run the real Smart Control app: connect, change EQ, read battery, and (if an update is
   available) run a firmware update. This exercises every command.
3. Pull the log (`adb bugreport` or the snoop file) and open in **Wireshark**.
4. Filter ATT writes to char `6333133C/6333133B`; each frame's header gives the
   `feature/command` IDs that pair with the names in §4 and §8. Build your opcode table
   from that. Cross-check against the public Qualcomm GAIA v3 documentation.

This is standard interop practice and needs the user's own phone + headphones.

---

## 10. Build phases (suggested milestones for Claude Code)

1. **Transport + framing**: GAIA v3 BLE client (Bleak), connect, notify, send one command.
2. **DeviceInfo**: read firmware version/serial/battery (§5). Validates framing.
3. **HCI-capture pass**: fill the opcode table (§9). (Human step; provide the Wireshark how-to.)
4. **Equalizer**: read/write bands (§6).
5. **Misc control**: audio mode, sidetone, rename, factory reset.
6. **Firmware fetch/decrypt**: port `sennheiser_fw.py` into the app (§7).
7. **Firmware install**: VM-Upgrade state machine (§8) with resume + battery guards.
8. **GUI** (optional) + classic-SPP fallback.

---

## 11. Reference appendix

**Constants**
```
FW API base         https://api.s-consumer-cloud.com/firmware/api/v2
FW CDN host         firmware.s-consumer-cloud.com
AES-256-CTR key     ed3b78a474c2acabb812407b97065649bf190e3d758e86f17b920aa41d8c271e
AES-CTR counter     initial value 5 (128-bit)
GAIA BLE service    63331337-23C1-11E5-B696-FEFF819CDC9F
GAIA3 write char    6333133B-23C1-11E5-B696-FEFF819CDC9F
GAIA3 read/notify   6333133C-23C1-11E5-B696-FEFF819CDC9F
GAIA SPP (classic)  a2129ff3-081b-4c45-8afe-469d9c4842eb
HD350 article no.   300002
min battery (both)  20%
```

**Full model-command list** (resolve IDs per §9): Service_SystemReleaseVersion,
Service_ProductId, Service_ProductIdNumber, Service_DeviceId, Service_USBSerial,
Service_HardwareRevision, Service_SoftwareVersion, Service_BtStackVersion,
Service_VmkitVersion, Service_ProtocolVersion, Service_ReleaseInfo, Service_FactoryReset,
Core_GetTransportInfo, Core_DataTransferSetup, Core_DataTransferGet, Battery_Percent,
Battery_ChargingStatus, Battery_ChargerEvent(_Register), Battery_LevelChangedEvtRegister/Cancel,
Sound_CustomEQControl, Sound_CustomEQKnobX, Sound_CustomEQKnobY, Sound_SetCustomEQ,
Sound_GetCustomEQ, Sound_SetEQParamGroup, Sound_GetCustomEQParam, UserEQ_GetSliderGain,
AudioMode, SidetoneState, AudioPrompt_GetAvailableAudioPromptsLanguages,
VoicePrompt_Language_Reselect, PairedDevicesGetDeviceInfo, PairedDevicesConnectDevice,
PairedDevicesDisconnectDevice, PairedDevicesDeleteEntry, PairedDevicesDeleteList,
Statistics_GetAvailableCategories, Statistics_GetAllStatisticsInCategory,
Firmware_Update_Status, Firmware_Update_Trigger, MCU_Get_FW_Version, MCU_GetUpgradeInfo,
and the full `Upgrade_*` set listed in §8.

**Companion file**: `sennheiser_fw.py` — working firmware download + AES-CTR decrypt tool.

**Legal/ethical note**: interop/repair for hardware the user owns; installs official signed
firmware only; no security control is bypassed. Do not ship Sennheiser trademarks/branding
in a way that implies official endorsement.
```
