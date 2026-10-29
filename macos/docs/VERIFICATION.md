# Recorded verification

These results describe an experimental development build, not a stable release certification. All recorded end-to-end writes used disposable disk images in a macOS Cua Space. Device identifiers are ephemeral.

## Windows file-copy media

A Cua GUI run used a real Windows 11 x64 ISO (build 26300) and a 16 GiB image target. File-level inspection found:

- GPT with one Microsoft Basic Data FAT32 partition, without the extra ESP that macOS normally creates.
- `install.wim` split into approximately 3.7 GiB + 3.7 GiB + 133 MiB `.swm` parts.
- The selected Windows 11 Pro edition written as `/IMAGE/INDEX` 6 in the answer file embedded in `boot.wim`.
- Rufus' setup wrapper installed as `setup.exe`, original saved as `setup.dll`.
- Empty `appraiserres.dll` placeholder with its original backup retained.
- Hardware-check and online-account bypass settings present in the generated answer file.

These are artifact checks, not proof that each setting works during a complete Windows installation. The [options screenshot](images/windows-options.png) retains the silent-install Disk 0 warning.

## Raw DD

A Cua GUI run wrote a 9,047,330,816-byte ISO to a 16 GiB image target. The app's complete read-back comparison succeeded. Independent first/last 64 MiB SHA-256 comparisons also matched:

```text
first: 682311289c867596792c13e091b68af350fad81a26042b6cd5de4b8c46ff89e1
last:  f8c50ea16dd2955b6b815c9a64d496ce91db7cc782797eb3c3591b765d13c346
```

## Compressed DD

The full check harness passed in the Space, including virtual-device writes, capacity and cancellation. The xz GUI run wrote and verified a 1 MiB patterned fixture; its decompressed contents and device prefix produced the same SHA-256:

```text
fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
```

See the [step-by-step compressed-image record](COMPRESSED-IMAGES.md) and [full check output](verification/2026-10-29-compressed-checks.log). Raw screenshots were replaced by publication crops to avoid exposing surrounding desktop content; original development records remain in earlier commits.

## Firmware smoke test

An earlier QEMU x86 UEFI test reached the Windows Setup language screen using generated FAT32 media. It did not complete installation, validate Secure Boot, or establish physical USB compatibility.

## What remains unverified

Repository-publication validation additionally rebuilt every helper and the app from a fresh source snapshot. All 34 normal check groups passed and the ad-hoc signature verified. See [the preparation record](REPOSITORY-PREPARATION.md) and [publication check output](verification/2026-10-29-publication-checks.log). This does not replace device/firmware validation.

Physical USB writes, authorization behavior on clean Macs, failing/removed-device recovery, complete Windows installation, representative real firmware and Intel builds are not established. `.lzma` and `.Z` decompressor paths have not been individually exercised by the compressed harness. See [safety boundaries](SAFETY.md) and [publication gates](PUBLISHING.md).
