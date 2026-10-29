#!/bin/bash
set -euo pipefail

# Build the GPL-licensed dependency locally; nothing is installed system-wide.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version=1.14.5
expected=84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194
prefix="$project_dir/.deps/wimlib-$version"
work="$(mktemp -d "${TMPDIR:-/tmp}/rufus-wimlib.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
: "${PKG_CONFIG:=$(command -v pkg-config || true)}"
if [[ -z "$PKG_CONFIG" || ! -x "$PKG_CONFIG" ]]; then
    echo 'A working pkg-config is required (set PKG_CONFIG or add it to PATH).' >&2
    exit 1
fi
curl --fail --location --silent --show-error "https://wimlib.net/downloads/wimlib-$version.tar.gz" -o "$work/wimlib.tar.gz"
actual="$(shasum -a 256 "$work/wimlib.tar.gz" | awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
    echo 'wimlib source checksum mismatch; refusing to build.' >&2
    exit 1
fi
tar -xzf "$work/wimlib.tar.gz" -C "$work"
cd "$work/wimlib-$version"
PKG_CONFIG="$PKG_CONFIG" ./configure --prefix="$prefix" --disable-shared --without-fuse --without-ntfs-3g
make -j "$(sysctl -n hw.ncpu)"
make install
"$prefix/bin/wimlib-imagex" --version
printf 'Built wimlib at %s\n' "$prefix/bin/wimlib-imagex"
