#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/STM32 烧录器.app"
stage_dir="$(mktemp -d /tmp/stm32flasher-build.XXXXXX)"
stage_app="$stage_dir/STM32 烧录器.app"
contents_dir="$stage_app/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
module_cache="$stage_dir/ModuleCache"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$macos_dir" "$resources_dir" "$module_cache"

xcrun swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  -sdk "$sdk_path" \
  -module-cache-path "$module_cache" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$project_dir/Sources/STM32FlasherApp.swift" \
  "$project_dir/Sources/AppearanceSettings.swift" \
  "$project_dir/Sources/CodexComponents.swift" \
  "$project_dir/Sources/WorkspaceScanner.swift" \
  "$project_dir/Sources/WorkspaceFileOperations.swift" \
  "$project_dir/Sources/BuildProcessSupport.swift" \
  "$project_dir/Sources/ExplorerInlineEditing.swift" \
  "$project_dir/Sources/ExplorerComponents.swift" \
  "$project_dir/Sources/MoveDestinationSheet.swift" \
  "$project_dir/Sources/ClipboardCSource.swift" \
  "$project_dir/Sources/FlasherModel.swift" \
  "$project_dir/Sources/ToolchainResolver.swift" \
  "$project_dir/Sources/SyntaxHighlightedCodeEditor.swift" \
  -o "$macos_dir/STM32Flasher"

cp -X "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp -RX "$project_dir/Resources/Toolchain" "$resources_dir/Toolchain"
cp -X "$project_dir/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"

xattr -cr "$stage_app"
find "$stage_app" -name '._*' -delete

codesign \
  --force \
  --deep \
  --sign - \
  --entitlements "$project_dir/Resources/STM32Flasher.entitlements" \
  "$stage_app"

codesign --verify --deep --strict "$stage_app"

rm -rf "$app_dir"
ditto "$stage_app" "$app_dir"
xattr -cr "$app_dir"

echo "$app_dir"
