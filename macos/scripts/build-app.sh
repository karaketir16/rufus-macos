#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

require() {
    local path="$1" kind="$2"
    local hint
    if [[ "$path" == */wimlib-imagex ]]; then
        hint='Run scripts/build-wimlib.sh first.'
    elif [[ "$path" == */.deps/compressors/* ]]; then
        hint='Run scripts/build-compressors.sh first.'
    else
        hint='Ensure the source tree is complete (res/setup and res/uefi assets must be present).'
    fi
    case "$kind" in
        file)
            if [[ ! -f "$path" ]]; then
                printf 'Required resource missing: %s\n' "$path" >&2
                printf '%s\n' "$hint" >&2
                exit 1
            fi
            ;;
        exec)
            if [[ ! -x "$path" ]]; then
                printf 'Required bundled helper missing or not executable: %s\n' "$path" >&2
                printf '%s\n' "$hint" >&2
                exit 1
            fi
            ;;
    esac
}

swift build -c release
app="$project_dir/.build/RufusMac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$project_dir/.build/release/RufusMac" "$app/Contents/MacOS/RufusMac"

wimlib="$project_dir/.deps/wimlib-1.14.5/bin/wimlib-imagex"
require "$wimlib" exec
cp "$wimlib" "$app/Contents/Resources/wimlib-imagex"
chmod 0755 "$app/Contents/Resources/wimlib-imagex"

uefi="$project_dir/../res/uefi/uefi-ntfs.img"
require "$uefi" file
cp "$uefi" "$app/Contents/Resources/uefi-ntfs.img"
chmod 0644 "$app/Contents/Resources/uefi-ntfs.img"

for setup in setup_x64.exe setup_arm64.exe; do
    src="$project_dir/../res/setup/$setup"
    require "$src" file
    cp "$src" "$app/Contents/Resources/$setup"
    chmod 0644 "$app/Contents/Resources/$setup"
done

# macOS ships no xz/zstd; bundle the pinned builds for compressed images (.xz/.lzma/.zst).
for tool in xz zstd; do
    src="$project_dir/.deps/compressors/$tool"
    require "$src" exec
    cp "$src" "$app/Contents/Resources/$tool"
    chmod 0755 "$app/Contents/Resources/$tool"
done

# Preserve third-party license notices alongside bundled helpers.
require "$project_dir/.deps/compressors/licenses/xz/COPYING" file
require "$project_dir/.deps/compressors/licenses/zstd/LICENSE" file
require "$project_dir/.deps/wimlib-1.14.5/share/licenses/wimlib/COPYING" file
mkdir -p "$app/Contents/Resources/licenses"
cp "$project_dir/../LICENSE.txt" "$app/Contents/Resources/licenses/Rufus-GPL-3.0.txt"
cp "$project_dir/../THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/licenses/THIRD_PARTY_NOTICES.md"
cp "$project_dir/../res/uefi/readme.txt" "$app/Contents/Resources/licenses/UEFI-NTFS-NOTICE.txt"
cp "$project_dir/../res/icons/license.txt" "$app/Contents/Resources/licenses/SETUP-ICON-NOTICE.txt"
if [[ -d "$project_dir/.deps/compressors/licenses" ]]; then
    cp -R "$project_dir/.deps/compressors/licenses/." "$app/Contents/Resources/licenses/"
fi
if [[ -d "$project_dir/.deps/wimlib-1.14.5/share/licenses/wimlib" ]]; then
    mkdir -p "$app/Contents/Resources/licenses/wimlib"
    cp -R "$project_dir/.deps/wimlib-1.14.5/share/licenses/wimlib/." "$app/Contents/Resources/licenses/wimlib/"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>RufusMac</string><key>CFBundleIdentifier</key><string>dev.rufus.mac.experimental</string><key>CFBundleName</key><string>RufusMac</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Created development app: %s\n' "$app"
