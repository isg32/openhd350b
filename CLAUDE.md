# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpenHD350B (package `com.isg32.openhd350b`) is an open-source Flutter/Android
replacement for Sennheiser's discontinued Smart Control app, targeting the
**HD 350BT** (article 300002). It talks to the headphones over Qualcomm's GAIA
protocol, reverse-engineered from Smart Control 4.7.0 and verified against a real
device. It installs only **official, signed** firmware — the chip verifies the
RSA signature itself (secure boot), so nothing here bypasses a security control.
This is an interoperability/repair project; keep that framing in docs and UI.

**Firmware flashing does not work over BLE** and is disabled in the UI — the
HD 350BT only accepts firmware over a Classic/RFCOMM link, which this BLE-only
app does not implement yet. The full rationale and the RFCOMM path forward are in
[`docs/firmware-flashing.md`](docs/firmware-flashing.md). Everything else
(connect, dashboard, EQ, firmware download/decrypt/verify, OTA app update) works.

Durable reverse-engineering facts live in the auto-memory files referenced in
`MEMORY.md` (GAIA on-wire details, firmware format/signing, VM-Upgrade opcodes,
the authoritative APK command source). Consult them before changing protocol code.

## Commands

```sh
flutter pub get
flutter analyze                       # lint (flutter_lints); keep clean before committing
flutter test                          # full suite (~52 tests)
flutter test test/features/upgrade_machine_test.dart   # one file
flutter test --plain-name 'byte-exact'                 # one test by name
flutter build apk --debug             # debug APK
dart run flutter_launcher_icons       # regenerate launcher icons after changing the source
```

**On-device dev — do NOT rely on `flutter run`/hot reload.** The USB link to the
test phone is flaky and keeps dropping the daemon. Install directly instead:

```sh
adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <serial> shell monkey -p com.isg32.openhd350b -c android.intent.category.LAUNCHER 1
adb -s <serial> logcat -v tag flutter:I '*:S'   # app logs; '[upgrade] ...' traces firmware flashing
```

**Signed release builds:** `./build_signed.sh` reads a gitignored `.env`
(base64 keystore + passwords; see `OPENHD_KEYSTORE_*` vars) and emits
`build/app/outputs/flutter-apk/app-*-release.apk` split per ABI. Without `.env`,
release builds fall back to the debug key. CI (`.github/workflows/release.yml`)
produces the real signed releases + the OTA `update.json` on push to `master`;
**bump `version:` in `pubspec.yaml` before any release** (CI requires a rising
versionCode). Requires `compileSdk = 37` (permission_handler).

## Architecture

Layered, bottom-up. State management is **`ChangeNotifier` + `AnimatedBuilder`**
(not Riverpod, despite the original plan). Entry point `lib/main.dart` →
`lib/ui/`.

**Transport → GAIA client → features → UI:**

- `lib/core/transport/` — abstract `GaiaTransport` (connect, `write`,
  `Stream<Uint8List> incoming`, negotiated MTU + detected protocol). BLE
  implementation plus a fake for tests.
- `lib/core/gaia/` — GAIA framing and the request/response client.
  `GaiaClient.request(vendor, command, …)` matches each reply to the oldest
  outstanding request with the same `(vendor<<16)|command` key; notifications go
  to a separate stream. `command_table.dart` maps command **names → numeric IDs
  with a verification status** (verified / candidate / unresolved); the client
  refuses to send unresolved or unverified-destructive commands. Keep new IDs
  behind that gate until confirmed on-device.
- `lib/features/` — one area per concern: `device/` (connection controller +
  typed session), `equalizer/` (the HD 350BT shelf-filter math), `controls/`,
  `firmware/` (cloud fetch + decrypt + VM-Upgrade installer), `updates/` (OTA app
  self-update from GitHub Releases).
- `lib/ui/` — home/auto-connect, a tabbed device shell (Device / EQ / Firmware /
  Console), the firmware + install screens, the OTA UI, and the About page.

### Protocol facts that bite (verified on real hardware)

- The HD 350BT speaks GAIA over BLE **GATT service `0xFDCE` with v1/v2 framing**,
  NOT the v3 UUIDs the original `build-spec.md` lists — the spec is wrong here.
  Vendor `0x000A` = Qualcomm, `0x0494` = Sennheiser-proprietary.
- **Bond before the first write.** An unbonded GAIA write can delete the system
  pairing; the connection flow bonds up front.
- Several commands answer with a non-zero status that is **normal and must be
  tolerated**, not treated as failure: EQ `Sound_SetCustomEQ` (0x021B) returns
  status 6 "incorrect state" (the official app ignores it and writes the knobs
  anyway); VM-Upgrade `connect` (0x0640) returns status 6 and `enable`
  (0x0494/0x0202) returns status 1 — both best-effort.

### Firmware pipeline

Cloud API (articleNumber 300002) lists versions → download encrypted package →
**AES-256-CTR decrypt** (`firmware_crypto.dart`; key is transport-only, not a
signing key) → md5-verify → save under the phone's
`Downloads/OpenHD350B/Firmwares/`. Installing re-uses Qualcomm's **GAIA
VM-Upgrade** state machine (`upgrade_machine.dart` driving opcodes from
`vm_upgrade.dart` through `gaia_upgrade_transport.dart`). The machine has a
**dry-run mode** (exercises the full handshake, writes zero firmware bytes) and
aborts (device rolls back) on any error — always validate changes via dry run,
and against the 13 simulated-device tests in `upgrade_machine_test.dart`, before
touching real hardware. Never rebuild-and-flash firmware; only flash official
signed images (secure boot verifies them anyway).

### Reference docs

`docs/devices/*.md` — extracted GAIA command reference for all 25 Smart Control
models (only the HD 350BT is verified live). `docs/hci-capture.md` — the
Bluetooth HCI-snoop capture procedure, the authoritative way to confirm opcodes.
`build-spec.md` — the original reverse-engineering brief (note its GAIA v3 claim
is outdated).
