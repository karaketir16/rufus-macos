#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
    --virtual) shift ;;
    '') unset RUFUS_TEST_VIRTUAL_DISK RUFUS_TEST_VIRTUAL_BACKING RUFUS_ALLOW_VIRTUAL_DISKS ;;
    -h|--help) echo 'Usage: check.sh [--virtual] (default: no preselected device writes)'; exit 0 ;;
    *) echo 'Usage: check.sh [--virtual]' >&2; exit 1 ;;
esac
[[ $# -eq 0 ]] || { echo 'Unexpected arguments' >&2; exit 1; }
mkdir -p .build/checks
swiftc Sources/RufusCore/*.swift Checks/main.swift -o .build/checks/rufus-mac-check
exec .build/checks/rufus-mac-check
