# AlexaRemoteBridge

<img width="1075" height="651" alt="image" src="https://github.com/user-attachments/assets/72db3a87-aa6b-4686-9009-b2a1d2799f46" />



<p align="right"><a href="README.zh-CN.md">简体中文</a> &nbsp;·&nbsp; <a href="README.md">English</a></p>

AlexaRemoteBridge is a macOS menu bar app that turns the Amazon Alexa Voice Remote (3rd Gen, model L5B83G) into a wireless voice-input controller for your Mac. Hold the remote’s microphone button to speak, or map other remote buttons to open an app or send Return.

This project is experimental and currently developed and tested for the Alexa Voice Remote 3rd Gen.
It is an independent project and is not affiliated with Amazon.

## Features

- Routes live audio from the remote’s microphone to a virtual audio input such as BlackHole 2ch.
- Can trigger Fn or Option while the microphone button is held, for use with existing dictation apps.
- Detects remote buttons, shows recent events, and highlights the corresponding button on the remote illustration.
- Maps supported remote buttons to launch or activate an app, or send Return.
- Shows Input Monitoring and Accessibility permission status and links to the relevant macOS settings.
- Includes Simplified Chinese and English UI.

AlexaRemoteBridge handles audio transport and button actions; it does not perform speech recognition. Speech-to-text is provided by your chosen dictation app.

## Getting started

1. Pair the remote in macOS Bluetooth settings and launch AlexaRemoteBridge.
2. Install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole). Restart your Mac if prompted, then select BlackHole 2ch as the microphone input in your dictation app.
3. Grant Input Monitoring and Accessibility permissions when prompted. The Permissions page shows their status.
4. Configure button actions in the mapping page. Hold the remote’s microphone button to speak; your dictation app handles transcription after you release it.

The app runs in the menu bar. Choose “Open Main Window” to access button mapping and permissions. The microphone trigger mode can be changed from the menu bar.

## Build from source

Requires macOS, Swift, and [Opus](https://opus-codec.org/):

```bash
brew install opus
zsh scripts/build-app.sh
```

When the build finishes, open `dist/AlexaRemoteBridge.app`. BlackHole is a separate, optional virtual audio driver, but a compatible virtual input is needed to route remote audio into another app.

## Current limitations

- Currently implemented and tested for the Alexa Voice Remote 3rd Gen (L5B83G). Button mapping only works for buttons macOS exposes to the app as keyboard events.
- Automatic text-field focusing depends on whether the target app exposes an accessible input field to macOS. If focusing fails, click the field manually.
- Local builds are ad-hoc signed and not notarized. macOS may ask you to grant permissions again after rebuilding or moving the app, or when permission state changes.
- Speech recognition and handling of voice data are determined by the dictation app you use.

## Privacy

While in use, audio is streamed in real time to a virtual audio device on your Mac. The app does not save recordings or transcripts by default. Check your dictation app’s privacy information to learn whether it uploads audio or recognition results.

## Development

- [Product scope and implementation status (Chinese)](PRODUCT_REQUIREMENTS.md)

## License

This project is licensed under the GNU General Public License, version 3 or (at your option) any later version. See [LICENSE](LICENSE) for the full text.

## Contributing and security

- [Contributing guide](CONTRIBUTING.md)
- [Security reporting](SECURITY.md)
