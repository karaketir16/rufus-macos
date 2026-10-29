# macOS implementation

Native SwiftUI application and Swift core for the experimental Rufus macOS port. Start with the [repository README](../README.md) for status, screenshots, provenance and safety warnings.

## Build from source

Requirements: macOS 13 or later, Swift 5.9 or later (Xcode Command Line Tools), a C compiler, Make, and `pkg-config` for the wimlib configuration step. Helper builds download pinned source archives; nothing is installed system-wide. The recorded development build was Apple silicon. Intel builds are not validated.

```sh
cd macos
bash scripts/build-wimlib.sh
bash scripts/build-compressors.sh
bash scripts/build-app.sh
```

Output: `.build/RufusMac.app`. This is an **ad-hoc-signed development bundle**, not a notarized distribution. `swift build` builds the Swift targets only; it does not assemble the required helper tools and resources into an app.

To launch the assembled app:

```sh
open .build/RufusMac.app
```

Do not start a physical disk write unless you intend to erase the entire selected device and have an independent backup. Recorded end-to-end write tests used disposable disk images, not real USB hardware.

## Checks

After building helpers:

```sh
bash scripts/check.sh
```

The normal harness creates temporary fixture files and disk images; it does not write physical USB devices. It uses macOS disk-image utilities and can require permission to mount its disposable test images. The harness has additional environment-gated virtual-device integration checks: use only with a verified disposable image in an isolated macOS VM. Never copy a historical `diskN` identifier into a current write command.

## Implementation map

| Area | Files |
| --- | --- |
| Conservative disk enumeration and identity | `DiskInventory.swift`, `DiskIdentity.swift` |
| Mount exclusion during writes | `DiskMountGuard.swift` |
| Raw and compressed DD writes/read-back | `RawDiskWriter.swift`, `CompressedImage.swift` |
| GPT/MBR layout and virtual media | `PartitionTable.swift`, `VirtualDiskFormatter.swift`, `VirtualMediaBuilder.swift` |
| Windows image inspection and WIM splitting | `WindowsMediaInspector.swift`, `WIMSplitter.swift` |
| Windows setup choices and customization | `WindowsUserExperience.swift`, `WindowsAnswerFile.swift`, `WindowsCustomization.swift` |
| Labels and modified-file checksums | `VolumeLabel.swift`, `MD5SumUpdater.swift` |
| Native interface | `Sources/RufusMacApp/` |

Core files are under `Sources/RufusCore/`; the standalone check harness is `Checks/main.swift`.

## Verification and limitations

- Windows file-copy media: recorded Cua GUI run with a real build-26300 Windows ISO, GPT/FAT32, split WIM parts, selected edition and customized `boot.wim` inspected at file level.
- Raw DD: full application read-back comparison plus independent prefix/suffix hashes of the recorded image.
- Compressed DD: gzip/bzip2/xz/zstd virtual-device checks, corruption/ZIP/capacity/cancellation checks, and an xz GUI write with an independent full-fixture hash match.
- An earlier QEMU smoke test reached Windows Setup; that is **not** a completed Windows installation.
- `.lzma` and `.Z` decompressor command paths exist but were not separately exercised by the recorded compressed harness.

See [compressed-image evidence](docs/COMPRESSED-IMAGES.md), [publication checklist](docs/PUBLISHING.md), and the root README's unsupported-feature list. Do not interpret code coverage, generated XML, or a successful virtual-device write as physical USB or Windows Setup certification.
