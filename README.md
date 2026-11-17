# OpenHD350B

An open-source replacement for the Sennheiser **Smart Control** app, built with
Flutter. It targets the **HD 350BT** (model SEBT3, article 300002) and other
Qualcomm-GAIA Sennheiser headphones, so the hardware stays usable and
configurable after the official app is discontinued.

This is an interoperability and repair project for hardware you own. It talks to
the headphones with Qualcomm's GAIA protocol, reverse-engineered from the
official app and verified against a real device. It installs only **official,
signed** firmware — the chip validates the image signature itself, so nothing
here circumvents a security control.

## Status

Working against a real HD 350BT (firmware 5.8.0):

- **Connect** over BLE (GAIA service `0xFDCE`, GAIA v1/v2 framing) with explicit
  bonding, so the pairing is never disturbed.
- **Dashboard** — model, firmware, battery + charging, signal, audio mode, sidetone.
- **Equalizer** — 3-band (Bass / Mid / Treble) with the device's real shelf-filter
  math, bass boost, and custom-EQ toggle, verified by ear on the device.
- **Firmware** — list every cloud version, download, decrypt, md5-verify and save
  any version to the phone; over-the-air app self-update from GitHub Releases.
- **Debug console** — raw GAIA traffic, hex send, and a read-command verification sweep.

Planned: the GAIA VM-Upgrade firmware installer.

## Screenshots

| Device | Equalizer | Firmware |
|---|---|---|
| ![Device dashboard](docs/screenshots/device.png) | ![Equalizer](docs/screenshots/eq.png) | ![Firmware](docs/screenshots/firmware.png) |

## How it works

| Layer | Where |
|---|---|
| GAIA framing (v2 + v3) and request/response client | `lib/core/gaia/` |
| BLE / fake transports | `lib/core/transport/` |
| Command map (names → IDs, with verification status) | `lib/core/gaia/command_table.dart` |
| HD 350BT equalizer math | `lib/features/equalizer/eq_engine.dart` |
| Typed device session | `lib/features/device/` |
| UI (dashboard, EQ, console, shell) | `lib/ui/` |

Command IDs and the EQ algorithm were recovered from Smart Control 4.7.0 (a
NativeScript app; logic in `assets/app/bundle.js`) and confirmed on-device. The
reverse-engineering brief is in [`build-spec.md`](build-spec.md); the Bluetooth
HCI capture procedure is in [`docs/hci-capture.md`](docs/hci-capture.md).

`sennheiser_fw.py` is a standalone reference tool that downloads and decrypts
official firmware packages from Sennheiser's cloud.

## Build & run

```sh
flutter pub get
flutter run        # Android device with Bluetooth; pair the HD 350BT first
flutter test
```

Requires an Android device (BLE permissions are configured for Android 12+ and
legacy). The headphones must already be paired in the system Bluetooth settings.

## Supported devices (command reference)

Smart Control 4.7.0 ships a model definition for each device it supports. We
extracted the full GAIA command map (names, vendor/command IDs, parameters)
from every one so people can browse and build on them — not just the HD 350BT.
Each table is reverse-engineered reference; only the HD 350BT is verified on
real hardware here.

**GAIA**

| Device | Article | Commands | Reference |
|---|---|---|---|
| CX 350 | 300003 | 40 | [`cx350`](docs/devices/cx350.md) |
| CX 400 | 300004 | 87 | [`cx400`](docs/devices/cx400.md) |
| HD 250 | 300007 | 40 | [`hd250`](docs/devices/hd250.md) |
| HD 350 | 300002 | 42 | [`hd350`](docs/devices/hd350.md) |
| HD 450 | 508386 | 42 | [`hd450`](docs/devices/hd450.md) |
| HD 458 | 300005 | 42 | [`hd458`](docs/devices/hd458.md) |
| HD450SE | 509280 | 45 | [`hd450se`](docs/devices/hd450se.md) |
| IE 80 | 508240 | 68 | [`ie80`](docs/devices/ie80.md) |
| True Wireless | 508524 | 58 | [`tw1`](docs/devices/tw1.md) |
| True Wireless 2 | 300001 | 86 | [`tw2`](docs/devices/tw2.md) |

**GAIAV3**

| Device | Article | Commands | Reference |
|---|---|---|---|
| Accentum | 700174 | 96 | [`ac1`](docs/devices/ac1.md) |
| Accentum Plus | 700176 | 97 | [`acp1`](docs/devices/acp1.md) |
| Accentum TW | 700262 | 110 | [`atw1`](docs/devices/atw1.md) |
| CX 200 | 508973 | 85 | [`cx200`](docs/devices/cx200.md) |
| CX 200 Sports | 509299 | 86 | [`cx200sports`](docs/devices/cx200sports.md) |
| CX 500 | 700271 | 93 | [`cx500`](docs/devices/cx500.md) |
| CX400II | 509188 | 93 | [`cx400II`](docs/devices/cx400II.md) |
| Momentum 4 | 509266 | 97 | [`m4`](docs/devices/m4.md) |
| Momentum Sport 1 | 700304 | 122 | [`msport1`](docs/devices/msport1.md) |
| True Wireless 3 | 509180 | 104 | [`tw3`](docs/devices/tw3.md) |
| True Wireless 4 | 700365 | 111 | [`tw4`](docs/devices/tw4.md) |

**Nautilus**

| Device | Article | Commands | Reference |
|---|---|---|---|
| Momentum 3 | 24580 | 60 | [`m3`](docs/devices/m3.md) |
| PXC 550 | 300010 | 35 | [`pxc550`](docs/devices/pxc550.md) |
| PXC 550 2 | 24589 | 63 | [`pxc550II`](docs/devices/pxc550II.md) |

**ELMAR**

| Device | Article | Commands | Reference |
|---|---|---|---|
| Soundbar | 508682 | 77 | [`sb01`](docs/devices/sb01.md) |

## Legal & ethical note

For interoperability and repair of hardware you own. Installs official signed
firmware only; no security control is bypassed. Not affiliated with or endorsed
by Sennheiser; product names and images are the property of their respective
owners.

## License

MIT — see [`LICENSE`](LICENSE).
