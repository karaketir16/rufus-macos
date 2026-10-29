#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
app="$project_dir/.build/RufusMac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$project_dir/.build/release/RufusMac" "$app/Contents/MacOS/RufusMac"
if [[ -x "$project_dir/.deps/wimlib-1.14.5/bin/wimlib-imagex" ]]; then
    cp "$project_dir/.deps/wimlib-1.14.5/bin/wimlib-imagex" "$app/Contents/Resources/wimlib-imagex"
    chmod 0755 "$app/Contents/Resources/wimlib-imagex"
fi
if [[ -f "$project_dir/../res/uefi/uefi-ntfs.img" ]]; then
    cp "$project_dir/../res/uefi/uefi-ntfs.img" "$app/Contents/Resources/uefi-ntfs.img"
    chmod 0644 "$app/Contents/Resources/uefi-ntfs.img"
fi
for setup in setup_x64.exe setup_arm64.exe; do
    if [[ -f "$project_dir/../res/setup/$setup" ]]; then
        cp "$project_dir/../res/setup/$setup" "$app/Contents/Resources/$setup"
        chmod 0644 "$app/Contents/Resources/$setup"
    fi
done
# macOS ships no xz/zstd; bundle the pinned builds for compressed images (.xz/.lzma/.zst).
for tool in xz zstd; do
    if [[ -x "$project_dir/.deps/compressors/$tool" ]]; then
        cp "$project_dir/.deps/compressors/$tool" "$app/Contents/Resources/$tool"
        chmod 0755 "$app/Contents/Resources/$tool"
    fi
done
# Preserve third-party license notices alongside bundled decompressors.
if [[ -d "$project_dir/.deps/compressors/licenses" ]]; then
    mkdir -p "$app/Contents/Resources/licenses"
    cp -R "$project_dir/.deps/compressors/licenses/." "$app/Contents/Resources/licenses/"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>RufusMac</string><key>CFBundleIdentifier</key><string>dev.rufus.mac.experimental</string><key>CFBundleName</key><string>RufusMac</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Created development app: %s\n' "$app"
