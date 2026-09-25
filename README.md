# AlexaRemoteBridge

An experimental macOS bridge for the original Amazon Alexa Voice Remote (3rd Gen), model `L5B83G`.

The current milestone is a read-only HID probe. Audio decoding and virtual-microphone output are not implemented yet.

Identity:

- BLE product name: `AR`
- Vendor ID: `0x0171`
- Product ID: `0x041E`

The probe opens the matching HID device without exclusive access. It does not send feature or output reports and does not save full microphone packets. Output contains only the report ID, packet length, and an eight-byte prefix for protocol classification.

Build and run:

```bash
swift build --disable-keychain
swift run --disable-keychain alexa-remote-probe
```

If macOS blocks HID access, enable Input Monitoring for the terminal application and restart it.
