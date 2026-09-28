#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

swift build --configuration debug --product alexa-remote-probe --disable-keychain --disable-sandbox
binary_dir="$(swift build --configuration debug --show-bin-path --disable-keychain --disable-sandbox)"
bundle_dir="$project_dir/dist/AlexaRemoteBridge.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
rm -f "$bundle_dir/Contents/MacOS/alexa-remote-probe"
cp "$binary_dir/alexa-remote-probe" "$bundle_dir/Contents/MacOS/AlexaRemoteBridge"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$bundle_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle_dir"
print -r -- "$bundle_dir"
