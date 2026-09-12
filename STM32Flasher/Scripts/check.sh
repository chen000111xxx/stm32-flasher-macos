#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_path="$project_dir/build/STM32 烧录器.app"
info_plist="$project_dir/Resources/Info.plist"
icon_path="$project_dir/Resources/AppIcon.icns"
icon_master="$project_dir/Assets/AppIconMaster.png"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
test_module_cache="$(mktemp -d /tmp/stm32flasher-test-module-cache.XXXXXX)"
folder_test="$(mktemp /tmp/stm32flasher-folder-tests.XXXXXX)"
editor_test="$(mktemp /tmp/stm32flasher-editor-tests.XXXXXX)"
clipboard_test="$(mktemp /tmp/stm32flasher-clipboard-tests.XXXXXX)"
icon_test_root="$(mktemp -d /tmp/stm32flasher-icon-test.XXXXXX)"
icon_test_set="$icon_test_root/AppIcon.iconset"
verification_root="$(mktemp -d /tmp/stm32flasher-signature-check.XXXXXX)"
verification_app="$verification_root/STM32 烧录器.app"

trap 'rm -rf "$test_module_cache" "$folder_test" "$editor_test" "$clipboard_test" "$icon_test_root" "$verification_root"' EXIT

"$project_dir/build.sh"
ditto --norsrc "$app_path" "$verification_app"

signature_is_valid=false
for attempt in 1 2 3; do
  xattr -cr "$verification_app"
  if codesign --verify --deep --strict "$verification_app"; then
    signature_is_valid=true
    break
  fi
done

if [[ "$signature_is_valid" != true ]]; then
  echo "验证失败：应用签名无效。"
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info_plist")
executable="$verification_app/Contents/MacOS/STM32Flasher"
if [[ ! -x "$executable" ]]; then
  echo "验证失败：应用可执行文件不存在。"
  exit 1
fi

if [[ ! -f "$icon_master" ]]; then
  echo "验证失败：缺少应用图标母版。"
  exit 1
fi

master_width="$(sips -g pixelWidth "$icon_master" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
master_height="$(sips -g pixelHeight "$icon_master" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
master_alpha="$(sips -g hasAlpha "$icon_master" 2>/dev/null | awk '/hasAlpha:/ { print $2 }')"
if [[ "$master_width" != 1024 || "$master_height" != 1024 || "$master_alpha" != yes ]]; then
  echo "验证失败：应用图标母版必须是带透明通道的 1024×1024 PNG。"
  exit 1
fi

if ! iconutil -c iconset "$icon_path" -o "$icon_test_set"; then
  echo "验证失败：AppIcon.icns 无法解包。"
  exit 1
fi

for icon_spec in \
  "icon_16x16.png:16" \
  "icon_16x16@2x.png:32" \
  "icon_32x32.png:32" \
  "icon_32x32@2x.png:64" \
  "icon_128x128.png:128" \
  "icon_128x128@2x.png:256" \
  "icon_256x256.png:256" \
  "icon_256x256@2x.png:512" \
  "icon_512x512.png:512" \
  "icon_512x512@2x.png:1024"
do
  icon_name="${icon_spec%%:*}"
  expected_size="${icon_spec##*:}"
  extracted_icon="$icon_test_set/$icon_name"
  if [[ ! -f "$extracted_icon" ]]; then
    echo "验证失败：AppIcon.icns 缺少 $icon_name。"
    exit 1
  fi

  actual_width="$(sips -g pixelWidth "$extracted_icon" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
  actual_height="$(sips -g pixelHeight "$extracted_icon" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
  actual_alpha="$(sips -g hasAlpha "$extracted_icon" 2>/dev/null | awk '/hasAlpha:/ { print $2 }')"
  if [[ "$actual_width" != "$expected_size" || "$actual_height" != "$expected_size" || "$actual_alpha" != yes ]]; then
    echo "验证失败：$icon_name 的尺寸或透明通道无效。"
    exit 1
  fi
done

if ! cmp -s "$icon_path" "$verification_app/Contents/Resources/AppIcon.icns"; then
  echo "验证失败：应用包中的图标与源图标不一致。"
  exit 1
fi

xcrun swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -sdk "$sdk_path" \
  -module-cache-path "$test_module_cache" \
  "$project_dir/Sources/WorkspaceScanner.swift" \
  "$project_dir/Sources/WorkspaceFileOperations.swift" \
  "$project_dir/Sources/BuildProcessSupport.swift" \
  "$project_dir/Tests/FolderLogicTests.swift" \
  -o "$folder_test"
"$folder_test"

xcrun swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  -sdk "$sdk_path" \
  -module-cache-path "$test_module_cache" \
  -framework SwiftUI \
  -framework AppKit \
  "$project_dir/Sources/AppearanceSettings.swift" \
  "$project_dir/Sources/SyntaxHighlightedCodeEditor.swift" \
  "$project_dir/Tests/EditorLogicTests.swift" \
  -o "$editor_test"
"$editor_test"

xcrun swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  -sdk "$sdk_path" \
  -module-cache-path "$test_module_cache" \
  "$project_dir/Sources/ClipboardCSource.swift" \
  "$project_dir/Tests/ClipboardCSourceTests.swift" \
  -o "$clipboard_test"
"$clipboard_test"

echo "验证通过：STM32 烧录器 $version ($build)"
echo "$app_path"
