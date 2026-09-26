# AlexaRemoteBridge

Product scope and acceptance criteria: [PRODUCT_REQUIREMENTS.md](PRODUCT_REQUIREMENTS.md).

An experimental macOS bridge for the original Amazon Alexa Voice Remote (3rd Gen), model `L5B83G`.

The current milestone is working HID microphone activation, local Opus decoding, and live output to BlackHole 2ch. On the tested Mac, BlackHole's input meter moved in sync with speech from the remote, and the live bridge prevented the mic key from opening Spotlight during a held press.

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

For live input, install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) with `brew install blackhole-2ch` and reboot if the installer asks. Grant Accessibility and Input Monitoring permission to the terminal or packaged app. Then run `swift run --disable-keychain alexa-remote-probe --live` and choose `BlackHole 2ch` as the microphone inside the receiving app. The bridge selects BlackHole for its own output without changing the Mac's system-wide audio output. While the AR mic button is held, it consumes only macOS keycode `177`, including repeats and the final release, so Spotlight stays closed. If Accessibility permission is missing, audio still runs but Spotlight may appear. Live mode has a 30-second safety stop if no release arrives. Keep other audio applications from sending sound to BlackHole, or their audio will be mixed into the same virtual input.

For an existing dictation app, add `--voice-key fn-hold`, `--voice-key fn-toggle`, `--voice-key left-option-hold`, or `--voice-key right-option-hold` to `--live`. These shortcuts are emitted only while the Alexa mic session is active. The default `--live` mode emits no shortcut. The menu-bar app defaults to left Option hold for the user's Doubao setup and lets you change the mode from its AR menu. In the dictation app, choose `BlackHole 2ch` as the input device. The dictation app, not this bridge, converts speech to text, so its privacy policy applies.

To build a local menu-bar app, run `zsh scripts/build-app.sh`, then open `dist/AlexaRemoteBridge.app`. Grant the app Input Monitoring and Accessibility permissions in System Settings, quit it fully, and reopen it. The AR menu shows connection and microphone status, a bridge pause switch, voice-key mode selection, and button-learning actions. “Button Mapping Settings” opens a mapping dashboard with a drawn remote, connection status, recent detections from raw HID button reports, saved mappings, and add/remove actions. The microphone/voice report and audio frames are excluded from the ordinary-button list. The physical remote still needs on-device testing to confirm that every button report arrives and which raw report belongs to each printed button label. To bind an app, choose the `.app` in the picker, then press the remote button when prompted; the first press is consumed while learning. Later presses suppress the original key action and run the selected action. An already-running app is unhidden and activated; a non-running app is launched. Reopening a main window after all windows were closed depends on the target app's macOS reopen behavior. Mappings are stored locally. This currently supports buttons that macOS exposes as keyboard events for actions. Packaging is ad-hoc signed for local testing, not a notarized release.

## Findings on the tested remote

- A directional button produces HID report `01 50 00 00`, followed by a zeroed release report.
- The microphone button produces HID report `02 21 02 00 00`, followed by a zeroed release report. This is Consumer Page `AC Search` (`0x0221`), which macOS interprets as Spotlight. It is a button event, not microphone audio.
- Sending output report `F2 01` immediately after the mic press started a stream of input report `F0` frames (81 bytes including report ID). One measured press produced 286 frames in about six seconds; `F2 00` after release stopped the stream. This matches the 80-byte, 20 ms Opus CELT frames documented by tvbox.
- The device exposes a proprietary GATT service `5DE20000-5E8D-11E6-8B77-86F30CA893D3` with a writable characteristic `5DE24A17-...` and notifiable characteristics `5DD24A18-...` and `5DE24A19-...`. The GATT probe subscribes and reads only; it sends no proprietary commands.
- A device-specific `hidutil` mapping did not take effect on the tested Mac. A system-wide mapping also did not suppress the Spotlight popup. Neither is presented as a working fix.
- Exclusive HID capture returned `kIOReturnNotPrivileged` on the tested Mac, even after Input Monitoring permission. The optional `--seize` mode is diagnostic only and may fail for the same reason elsewhere.

The `FE151500-...` service may be related to firmware update and is deliberately untouched. The mic stream and Spotlight shortcut are separate event paths.

The `alexa-event-probe` tool logs only key-event metadata within 300 ms of an AR mic press. It identified macOS keycode `177` immediately after the HID `0x0221` mic report. Its `--suppress` mode confirmed that a short press can be blocked with Accessibility permission. The live bridge uses a longer button-held window to also block key repeats and release; a fixed 300 ms window failed for a held press.

The first local WAV test, spoken close to the remote, had 440 clipped samples across 24 frames. Repeating at roughly 10–15 cm from the microphone produced zero clipped samples (peak 5279), supporting near-field input overload as the cause of the reported popping. A fivefold gain applied to that distant sample was heard clearly without popping. The bridge now applies up to 5× gain to decoded samples, reducing gain on loud frames to avoid introducing new clipping. Speak at a normal level from roughly 10–15 cm; software gain cannot restore a mic signal already clipped before transmission. The test WAV files are local and ignored by Git.

## Planned settings UI

A device-specific button-mapping screen is planned: remote diagram, connected/microphone status, profiles, button learning, short- and long-press actions, and a safe reset. The mic key should default to push-to-talk. No remapping UI is implemented yet.
