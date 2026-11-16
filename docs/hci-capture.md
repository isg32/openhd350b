# Recording the GAIA command IDs (HCI snoop capture)

We know every command *name* Smart Control uses but not its numeric IDs. This
procedure records the official app talking to your HD 350BT so we can read
the IDs out of the Bluetooth traffic. You need: an Android phone, the HD 350BT,
Smart Control installed, a computer with `adb` and Wireshark (`tshark`).

## 1. Turn on the snoop log

1. Settings → About phone → tap **Build number** 7× to unlock Developer options.
2. Developer options → **Enable Bluetooth HCI snoop log** → choose **Enabled**
   (not "Filtered": filtered mode strips the payload bytes we need).
3. Turn Bluetooth **off and on again**. The log only starts after a restart,
   and we want the GATT service discovery included so Wireshark can label
   the characteristics.

## 2. Run the official app — one action at a time

Pause ~10 s between steps and **write down the clock time of each step**.
That's how we pair packets with command names.

| # | Action in Smart Control | Expected commands |
|---|---|---|
| 1 | Open app, let it connect to the HD 350BT | `Core_GetTransportInfo`, `Service_*` reads, `Battery_Percent` |
| 2 | Open the device info / about screen | `Service_SystemReleaseVersion`, `Service_USBSerial`, `Service_HardwareRevision` |
| 3 | Open the EQ screen | `Sound_GetCustomEQ` / `Sound_GetCustomEQParam` |
| 4 | Move the EQ to the far left, then the far right, then centre | `Sound_CustomEQKnobX/Y`, `Sound_SetCustomEQ` |
| 5 | Turn custom EQ off, then on | `Sound_CustomEQControl` |
| 6 | Change the audio mode (if offered) | `AudioMode` |
| 7 | Change sidetone (if offered) | `SidetoneState` |
| 8 | Rename the headphones, then rename them back | device name |
| 9 | Unplug/plug the charger with the app open | `Battery_ChargerEvent` notifications |
| 10 | *Only if an update is offered:* run the firmware update | the whole `Upgrade_*` sequence |

**Don't** run factory reset during the capture. We'll fill that ID in from the
pattern of its neighbours, or capture it separately later if you're OK resetting.

## 3. Pull the log

```sh
adb bugreport bugreport.zip
unzip -o bugreport.zip 'FS/data/misc/bluetooth/logs/*' -d capture
ls capture/FS/data/misc/bluetooth/logs/   # btsnoop_hci.log
```

(Some phones put it at `/sdcard/btsnoop_hci.log` instead: `adb pull /sdcard/btsnoop_hci.log`.)

Turn the snoop log back **off** when you're done.

## 4. Extract GAIA traffic

Open the log in Wireshark and check the service discovery at the start: find the
handles of characteristics `6333133B…` (write) and `6333133C…` (notify). Then
dump every write and notification:

```sh
tshark -r btsnoop_hci.log \
  -Y 'btatt.opcode == 0x12 || btatt.opcode == 0x52 || btatt.opcode == 0x1b' \
  -T fields -e frame.time -e btatt.opcode -e btatt.handle -e btatt.value \
  > gaia-traffic.tsv
```

- `0x12` / `0x52` = app → headphones (write request / write command)
- `0x1b` = headphones → app (notification)

## 5. What to send back

- `gaia-traffic.tsv`
- your list of step timestamps
- the handle numbers of `…133B` and `…133C`
- anything also on other handles of the `63331337…` service (the bulk-data
  characteristic mentioned in build-spec §3a)

The file contains your headphones' Bluetooth address and serial number. Keep
it out of the public repo; we'll commit only sanitized fixtures.

## How the IDs get decoded

If the device uses Qualcomm GAIA v3 framing, each value starts with
`VVVV DDDD`: a 16-bit vendor ID, then a 16-bit description split into
feature (7 bits) · type (2 bits) · command (7 bits). See
`lib/core/gaia/gaia_frame.dart`. The in-app debug console decodes PDUs the same
way, so you can also send a captured command back to the headphones and
compare the replies.
