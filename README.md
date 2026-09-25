# AlexaRemoteBridge

An experimental macOS bridge for the original Amazon Alexa Voice Remote (3rd Gen), model `L5B83G`.

The current milestone is working HID microphone activation and local Opus decoding. Live virtual-microphone output is not implemented yet.

Identity:

- BLE product name: `AR`
- Vendor ID: `0x0171`
- Product ID: `0x041E`

The HID probe opens the matching device without exclusive access by default. It does not send feature or output reports and does not save full microphone packets. Output contains only the report ID, packet length, and an eight-byte prefix for protocol classification.

Build and run:

```bash
brew install opus
swift build --disable-keychain
swift run --disable-keychain alexa-remote-probe
swift run --disable-keychain alexa-gatt-probe
```

If macOS blocks HID access, enable Input Monitoring for the terminal application and restart it.

To count microphone frames without saving speech, run `swift run --disable-keychain alexa-remote-probe --audio-test`, then hold and release the mic button. To decode speech into a local 16 kHz mono WAV, run `swift run --disable-keychain alexa-remote-probe --record-wav ./voice-test.wav`. WAV files are ignored by Git. Both modes send only HID output report `F2 01` after button-down and `F2 00` after button-up, with a ten-second safety stop. The command and frame format are documented in [tvbox's Fire TV remote implementation](https://github.com/Andy1210/tvbox/blob/main/docs/voice-satellite.md#how-the-remotes-microphone-works).

## Findings on the tested remote

- A directional button produces HID report `01 50 00 00`, followed by a zeroed release report.
- The microphone button produces HID report `02 21 02 00 00`, followed by a zeroed release report. This is Consumer Page `AC Search` (`0x0221`), which macOS interprets as Spotlight. It is a button event, not microphone audio.
- Sending output report `F2 01` immediately after the mic press started a stream of input report `F0` frames (81 bytes including report ID). One measured press produced 286 frames in about six seconds; `F2 00` after release stopped the stream. This matches the 80-byte, 20 ms Opus CELT frames documented by tvbox.
- The device exposes a proprietary GATT service `5DE20000-5E8D-11E6-8B77-86F30CA893D3` with a writable characteristic `5DE24A17-...` and notifiable characteristics `5DD24A18-...` and `5DE24A19-...`. The GATT probe subscribes and reads only; it sends no proprietary commands.
- A device-specific `hidutil` mapping did not take effect on the tested Mac. A system-wide mapping also did not suppress the Spotlight popup. Neither is presented as a working fix.
- Exclusive HID capture returned `kIOReturnNotPrivileged` on the tested Mac, even after Input Monitoring permission. The optional `--seize` mode is diagnostic only and may fail for the same reason elsewhere.

The `FE151500-...` service may be related to firmware update and is deliberately untouched. The Spotlight popup is not solved yet; the mic stream and OS shortcut are separate issues.
