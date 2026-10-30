# Attribution and third-party components

This independent macOS port derives from **Rufus**, copyright Pete Batard and upstream contributors, under GPL-3.0-or-later. The license text is in [LICENSE.txt](LICENSE.txt); the exact upstream baseline is in [PROVENANCE.md](PROVENANCE.md). No upstream endorsement is implied.

File-level exception: `macos/Sources/RufusCore/CompressedImage.swift` and `macos/scripts/build-compressors.sh` are offered under MIT, copyright (c) 2026 Osman Karaketir. See [the exact scope](LICENSES/README.md) and [MIT text](LICENSES/MIT.txt). The combined application remains GPL-3.0-or-later; downloaded tools, upstream assets and other source files are not covered by that MIT grant.

## Retained Rufus resources

- **Windows Setup wrappers:** `res/setup/setup_x64.exe` and `setup_arm64.exe`, retained from the recorded Rufus commit. Corresponding C source, resource definitions and Visual Studio build files are in `res/setup/`. See its original `readme.txt` and source headers. Wrapper source is GPL-3.0-or-later.
- **Setup icon:** `res/icons/setup.ico` is retained only because the setup-wrapper resource file requires it. [The original notice](res/icons/license.txt) identifies Tabler/Axialis artwork and warns about redistribution rights. No general license to reuse Axialis artwork outside this derivative is asserted. The rest of the upstream icon collection is not included in the current tree.
- **UEFI:NTFS image:** `res/uefi/uefi-ntfs.img` and its original [notice](res/uefi/readme.txt) are retained. That notice identifies signed ntfs-3g-derived drivers (release 1.9), EfiFs drivers (release 1.12), and UEFI:NTFS bootloaders (release 2.8). Source projects: [ntfs-3g](https://github.com/pbatard/ntfs-3g), [EfiFs](https://github.com/pbatard/efifs), [UEFI:NTFS](https://github.com/pbatard/uefi-ntfs). Signed images are not evidence that the macOS port creates working NTFS media.

## Locally built helper tools

| Tool | Version | Source | Build script |
| --- | --- | --- | --- |
| wimlib / wimlib-imagex | 1.14.5 | <https://wimlib.net/downloads/wimlib-1.14.5.tar.gz> | `macos/scripts/build-wimlib.sh` |
| XZ Utils / xz | 5.6.4 | <https://tukaani.org/xz/xz-5.6.4.tar.gz> | `macos/scripts/build-compressors.sh` |
| Zstandard / zstd | 1.5.7 | <https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz> | `macos/scripts/build-compressors.sh` |

The scripts pin SHA-256 checksums and build locally. wimlib-imagex reports GPLv3-or-later. XZ and Zstandard distributions contain component-specific/alternative license texts; preserve all notices copied from their source distributions rather than treating this table as a replacement license. The app build copies available helper notices under `Contents/Resources/licenses/`.

```text
84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194  wimlib-1.14.5.tar.gz
269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b  xz-5.6.4.tar.gz
eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3  zstd-1.5.7.tar.gz
```

macOS system tools/frameworks are not redistributed as part of the source tree. No Windows ISO, Windows installation file, Apple SDK, or downloaded dependency build output belongs in this repository.

## Binary distribution is a separate gate

Keep corresponding source, modifications, build material and license notices available under the applicable licenses when distributing binaries. In particular, the prebuilt UEFI image contains third-party components whose source obligations must be satisfied; a project URL alone should not be assumed to satisfy every redistribution requirement. Confirm icon redistribution rights and signing/notarization before packaging a public binary. This document is attribution and release guidance, not a claim of completed legal review.
