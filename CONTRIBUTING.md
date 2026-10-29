# Contributing

This is an experimental independent macOS derivative of Rufus. Keep changes focused on supported workflows and preserve GPL attribution and component notices.

1. Read the [status](README.md), [safety boundaries](macos/docs/SAFETY.md) and [upstream baseline](PROVENANCE.md).
2. Build the pinned helpers, run `bash scripts/check.sh`, and assemble the app from `macos/` as documented.
3. Include a regression check for behavior changes. State which claims were tested and which remain unverified.
4. Exercise changed GUI flows in a disposable macOS VM/Space. Never automate writes to a contributor's physical disks. Development mode permits virtual targets but is not a virtual-only safety boundary.
5. Do not submit ISOs, disk images, dependency/build output, secrets, personal transcripts or machine-specific paths. Crop screenshots to relevant application content while retaining safety warnings.

For bugs, include macOS version, CPU architecture, source commit, helper versions, selected write mode and a redacted error message. Do not include volume serials, private paths or full disk inventories unless reviewed for personal data. Do not report issues with this port as upstream Rufus bugs without first reproducing them in upstream's supported product.

Changes to device discovery, authorization, erase operations or cleanup need explicit failure-path review. Do not weaken identity checks to make a test pass.
