#!/bin/bash
# Builds the two compressors the app needs but macOS does not ship: xz (for .xz/.lzma) and
# zstd (for .zst). Both are pinned, checksummed, built statically-ish and copied to
# .deps/compressors/, from where scripts/build-app.sh bundles them into the .app.
#
# macOS does ship gzip, bzip2 and bsdtar, so .gz, .Z, .bz2 and .zip need no bundled tool.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
deps="$project_dir/.deps/compressors"
work="$(mktemp -d "${TMPDIR:-/tmp}/rufus-compressors.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$deps"
cd "$work"

fetch() { # url sha256 output
    if [[ -f "$3" ]] && echo "$2  $3" | shasum -a 256 -c - >/dev/null 2>&1; then
        return
    fi
    curl --fail -sSL --max-time 300 -o "$3" "$1"
    echo "$2  $3" | shasum -a 256 -c -
}

XZ_VERSION=5.6.4
ZSTD_VERSION=1.5.7

fetch "https://tukaani.org/xz/xz-${XZ_VERSION}.tar.gz" \
      269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b "xz.tar.gz"
fetch "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" \
      eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3 "zstd.tar.gz"

tar xzf xz.tar.gz
(
    cd "xz-${XZ_VERSION}"
    ./configure --disable-shared --enable-static --disable-nls --disable-doc --disable-scripts \
                --disable-lzmadec --disable-lzmainfo --disable-xzdec >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
)
cp "xz-${XZ_VERSION}/src/xz/xz" "$deps/xz"
chmod 0755 "$deps/xz"

tar xzf zstd.tar.gz
make -C "zstd-${ZSTD_VERSION}/programs" -j"$(sysctl -n hw.ncpu)" zstd >/dev/null
cp "zstd-${ZSTD_VERSION}/programs/zstd" "$deps/zstd"
chmod 0755 "$deps/zstd"

mkdir -p "$deps/licenses/xz" "$deps/licenses/zstd"
cp "xz-${XZ_VERSION}"/COPYING* "$deps/licenses/xz/"
cp "zstd-${ZSTD_VERSION}/LICENSE" "$deps/licenses/zstd/"
cp "zstd-${ZSTD_VERSION}/COPYING" "$deps/licenses/zstd/"

"$deps/xz" --version
"$deps/zstd" --version
echo "Compressors ready in $deps"
