# Firmware flashing status

**Short version: installing firmware on the HD 350BT is not possible over
Bluetooth LE, and this app currently only speaks BLE. Flashing is therefore
disabled in the UI.** Downloading, decrypting, md5-verifying and saving any
firmware version works and is useful for study and backup.

## What works

The full Qualcomm **VM-Upgrade** handshake runs correctly against a real
HD 350BT over GAIA/BLE: `connect → enable → SYNC (resume point) → START
(battery ok) → data transfer begins`. The firmware pipeline (cloud download →
AES-256-CTR decrypt → md5 verify → save) is also verified, and the saved image
is a valid `APPUHDR5` / `QCC5121Xx` DFU.

## What fails, and why

The **data transfer cannot complete over BLE.** The device streams requests for
the DFU header in small chunks (12, 36, 8 … bytes — these match the header
fields), then requests **268 bytes**, and there is no way to answer that the
device accepts over BLE:

- Sending it as several MTU-sized fragments → the device stops requesting and
  the transfer times out.
- Sending one packet and waiting for a re-request → the device stays silent.
- A single GATT **long write** → the device's GATT server returns
  `GATT_REQUEST_NOT_SUPPORTED`.
- A larger MTU → the device **hard-caps the ATT MTU at 64** (≈53 data bytes per
  packet), even on an explicit `requestMtu`.

### Root cause

Decompiling Smart Control 4.7.0 (`bundle.js`) shows it sizes upgrade packets as
`getMaxOTAPayloadSize()`:

```
BLE:     maxPayload = negotiatedMTU - 11
CLASSIC: maxPayload = min(MTU, 255) - 13     // RFCOMM / SPP
```

The HD 350BT is a **dual-mode** device (Classic BR/EDR + BLE). Its firmware
updater expects large logical packets — which only the **Classic BR/EDR
(RFCOMM/SPP)** link can carry — and that is where the official app flashes
firmware. Over BLE at MTU 64 only 53-byte fragments are possible, and the
device's BLE upgrade path stalls on them. The transfer bytes produced here are
byte-for-byte identical to the official app's; this is a device/transport
limitation, not a defect in the upgrade state machine.

The headphones are never at risk: the image is RSA-signed and verified on-chip
(secure boot), and any failure aborts the upgrade so the chip rolls back. The
installed firmware is never touched until the very end of a successful transfer,
which is never reached.

## The path forward

Add an **RFCOMM/SPP GAIA transport** (Classic Bluetooth):

- `flutter_blue_plus` is BLE-only, so this needs a Classic-Bluetooth plugin or a
  small Android platform channel using
  `BluetoothSocket.createRfcommSocketToServiceRecord` with the GAIA SPP service
  UUID.
- GAIA framing over RFCOMM is the length-prefixed v1/v2 header (not the 4-byte
  BLE header).
- `UpgradeMachine` and `VmPdu` are transport-agnostic and reuse unchanged — only
  a new `UpgradeTransport` implementation (sibling to `GaiaUpgradeTransport`,
  with `maxChunkBytes ≈ 242`) is required.
- A Bluetooth HCI capture of the official app mid-flash (see
  [`hci-capture.md`](hci-capture.md)) would confirm the exact RFCOMM channel,
  service UUID and framing.
