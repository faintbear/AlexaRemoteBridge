# Contributing

Thanks for your interest in AlexaRemoteBridge. The project is experimental and currently targets the Amazon Alexa Voice Remote 3rd Gen (L5B83G).

## Build

Requirements: macOS, Swift 6, Homebrew, and Opus.

```bash
brew install opus
zsh scripts/build-app.sh
```

The app bundle is created at `dist/AlexaRemoteBridge.app`. Hardware changes should be tested with the target remote when possible; include the remote model, macOS version, and concise reproduction steps in a report.

## Pull requests

- Keep changes focused and describe user-visible behavior and how it was tested.
- Do not include recordings, personal paths, credentials, or other private diagnostic data. Test WAV files are intentionally ignored by Git.
- Contributions are distributed under the project license, GPL-3.0-or-later.
