# AlexaRemoteBridge

AlexaRemoteBridge 是一款 macOS 菜单栏应用，让 Amazon Alexa Voice Remote（第 3 代，型号 L5B83G）成为 Mac 上的无线语音输入遥控器。按住遥控器的麦克风键即可说话；也可以把遥控器上的其他按键映射为打开常用 App 或发送 Return。

项目仍处于实验阶段，目前针对 Alexa Voice Remote 3rd Gen 开发和测试。

## 功能

- 将遥控器麦克风的实时音频送入 BlackHole 2ch 等虚拟音频输入设备。
- 按住麦克风键时，可触发 Fn 或 Option，配合豆包等已有语音输入应用使用。
- 在按键映射页面识别按键、显示最近按键并高亮遥控器示意图上的对应位置。
- 将可识别的遥控器按键映射为打开/切换到指定 App，或发送 Return。
- 在应用内查看输入监控、辅助功能权限状态，并提供跳转到 macOS 系统设置的入口。
- 提供简体中文和英文界面。

AlexaRemoteBridge 负责传输音频和按键操作，不包含语音识别。语音转文字由你选择的输入法或听写应用完成。

## 开始使用

1. 在 macOS 蓝牙设置中配对遥控器，并启动 AlexaRemoteBridge。
2. 安装 [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)；如果安装器提示，请重启 Mac。然后在豆包或其他语音输入应用中选择 BlackHole 2ch 作为麦克风输入。
3. 按应用提示授予“输入监控”和“辅助功能”权限。权限页面会显示各项授权状态。
4. 在按键映射页面设置所需操作。按住遥控器麦克风键说话，松开后由语音输入应用完成识别。

应用运行在菜单栏。选择“打开主界面”可打开按键映射和权限页面；麦克风触发方式可从菜单栏切换。

## 从源码构建

需要 macOS、Swift 和 [Opus](https://opus-codec.org/)：

```bash
brew install opus
zsh scripts/build-app.sh
```

构建完成后打开 `dist/AlexaRemoteBridge.app`。BlackHole 是可选的独立虚拟音频驱动，但要把遥控器音频送入其他应用时需要配置兼容的虚拟输入设备。

## 当前限制

- 目前仅针对 Alexa Voice Remote（第 3 代，L5B83G）实现和验证，按键映射仅适用于 macOS 能上报给应用的按键。
- 自动聚焦取决于目标 App 是否向 macOS 暴露可访问的文本输入框；未能聚焦时，请手动点击输入框。
- 本地构建版本为临时签名，尚未公证。重新构建、移动应用或系统权限状态变化后，macOS 可能要求重新授予权限。
- 音频识别和语音数据的处理方式由所使用的语音输入应用决定。

## 隐私

音频在使用期间实时输出到本机的虚拟音频设备；应用不会默认保存录音或转写文本。语音输入应用是否上传音频或识别结果，请参阅该应用自己的隐私说明。

## 开发资料

- [产品需求与验收说明](PRODUCT_REQUIREMENTS.md)

## English

AlexaRemoteBridge is a macOS menu bar app that turns the Amazon Alexa Voice Remote (3rd Gen, model L5B83G) into a wireless voice-input controller for your Mac. Hold the remote’s microphone button to speak, or map other remote buttons to open an app or send Return.

This project is experimental and currently developed and tested for the Alexa Voice Remote 3rd Gen.

### Features

- Routes live audio from the remote’s microphone to a virtual audio input such as BlackHole 2ch.
- Can trigger Fn or Option while the microphone button is held, for use with existing dictation apps.
- Detects remote buttons, shows recent events, and highlights the corresponding button on the remote illustration.
- Maps supported remote buttons to launch or activate an app, or send Return.
- Shows Input Monitoring and Accessibility permission status and links to the relevant macOS settings.
- Includes Simplified Chinese and English UI.

AlexaRemoteBridge handles audio transport and button actions; it does not perform speech recognition. Speech-to-text is provided by your chosen dictation app.

### Getting started

1. Pair the remote in macOS Bluetooth settings and launch AlexaRemoteBridge.
2. Install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole). Restart your Mac if prompted, then select BlackHole 2ch as the microphone input in your dictation app.
3. Grant Input Monitoring and Accessibility permissions when prompted. The Permissions page shows their status.
4. Configure button actions in the mapping page. Hold the remote’s microphone button to speak; your dictation app handles transcription after you release it.

The app runs in the menu bar. Choose “Open Main Window” to access button mapping and permissions. The microphone trigger mode can be changed from the menu bar.

### Build from source

Requires macOS, Swift, and [Opus](https://opus-codec.org/):

```bash
brew install opus
zsh scripts/build-app.sh
```

When the build finishes, open `dist/AlexaRemoteBridge.app`. BlackHole is a separate, optional virtual audio driver, but a compatible virtual input is needed to route remote audio into another app.

### Current limitations

- Currently implemented and tested for the Alexa Voice Remote 3rd Gen (L5B83G). Button mapping only works for buttons macOS exposes to the app as keyboard events.
- Automatic text-field focusing depends on whether the target app exposes an accessible input field to macOS. If focusing fails, click the field manually.
- Local builds are ad-hoc signed and not notarized. macOS may ask you to grant permissions again after rebuilding or moving the app, or when permission state changes.
- Speech recognition and handling of voice data are determined by the dictation app you use.

### Privacy

While in use, audio is streamed in real time to a virtual audio device on your Mac. The app does not save recordings or transcripts by default. Check your dictation app’s privacy information to learn whether it uploads audio or recognition results.

### Development

- [Product requirements and acceptance criteria](PRODUCT_REQUIREMENTS.md)
