# Compressed-image implementation and evidence

Recorded 2026-10-29. Automated checks and a Cua GUI run passed for the scope below. This is not a claim that the entire port is complete.

## 1. Establish macOS capabilities

The isolated macOS test Space had `gzip`, `bzip2` and `bsdtar`, but neither xz nor zstd. A generated 1 MiB patterned fixture gave:

```text
plain SHA-256: fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
gzip -dc:     fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
bzip2 -dc:    fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
bsdtar xz: Error opening archive: Unrecognized archive format
bsdtar zst: Can't initialize filter; unable to run program "zstd -d -qq"
```

The system archive utility alone did not establish support for raw compressed images.

## 2. Build missing helpers

Built xz 5.6.4 and zstd 1.5.7 from pinned/checksummed source. Versions and archive hashes are in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md). The built xz used only system `libSystem`; zstd used system `libz` and `libSystem`, not a Homebrew runtime library.

`scripts/build-compressors.sh` creates local helper builds; `scripts/build-app.sh` bundles them with license notices. A clean helper build is required before the compressed checks. No helper is installed system-wide.

## 3. Streaming write and failure behavior

Core: `CompressedImage.swift`, `RawDiskWriter.swift`; checks: `Checks/main.swift`.

- Compressed inputs use DD mode, with no file-copy customization.
- gzip's modulo-4-GiB trailer and xz indexes are not trusted as output sizes. Capacity is enforced block-by-block while streaming.
- Progress is indeterminate until decompressed length is known; read-back uses the written length.
- Abort before EOF closes the pipe and terminates the decompressor. Normal EOF waits for its natural exit status; a failed exit must not report success.
- Device handles close on thrown read/write/identity errors.
- A corrupt, oversized or cancelled stream can leave a partially overwritten disk. There is no rollback.

## 4. Automated checks inside the Space

The full harness was run against a newly created disposable 128 MiB image. Its backing identity was checked before use; the historical `disk11` identifier must not be reused on another machine.

```text
Compressed format detection and single-stream decompression checks passed
Multiple-file zip rejection checks passed
Corrupt and truncated compressed stream rejection checks passed
Virtual device write, read-back and DiskMountGuard checks passed
VirtualDiskFormatter GPT/FAT32 and exFAT+UEFI:NTFS media preparation checks passed
DD mode (RawDiskWriter) write and verification checks passed
Compressed DD mode write, capacity and cancellation checks passed
```

Full output: [2026-10-29-compressed-checks.log](verification/2026-10-29-compressed-checks.log).

Coverage: gzip/bzip2/xz/zstd/single-member ZIP decode against patterned data; gzip/bzip2/xz/zstd device write/read-back; corrupt/truncated gzip; multi-member ZIP rejection; compressed capacity overflow and mid-stream cancellation. LZMA and `.Z` invocation paths are implemented but not separately exercised here.

## 5. Real GUI flow through Cua

Launched the signed development app inside the Space with virtual-disk development mode enabled. Through the real file picker, selected `sample.img.xz` (520 bytes, expanding to the patterned 1 MiB image). The UI forced DD, disabled unrelated formatting controls, and required typed erase confirmation for the disposable target.

Exact final status:

```text
DD write finished: 1 MB written, verified against the image.
```

The [publication screenshot](images/compressed-write.png) shows the compressed selection, DD mode and erase confirmation. The full completion screenshot was reviewed during testing; the public crop emphasizes the visible selection state rather than implying physical USB verification.

After the run, `hdiutil info -plist` again confirmed the scratch backing image. Independently decompressed the fixture with the bundled xz and compared its SHA-256 with the device's first 1 MiB (`dd` with a 1 MiB block count of one). Both returned:

```text
fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
```

This establishes correct decompressed device bytes for the fixture, not Linux bootability, physical USB behavior or Windows installation success. Existing larger test media was not overwritten by this run.
