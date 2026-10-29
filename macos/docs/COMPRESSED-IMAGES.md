# Compressed image implementation and evidence

Date: 2026-10-29. Status: automated checks and Cua GUI verification passed for the scope below.

## Scope and safety

Add streaming decompression to the existing DD path, without installing drivers or touching physical USB media. GUI tests use Space `space-57caba4ef0` and a newly created scratch disk image. `disk4` and the T7 must never be targeted. NTFS remains a separate unresolved dependency decision.

## 1. Establish platform capabilities

The Space has `/usr/bin/gzip`, `/usr/bin/bzip2`, and `/usr/bin/bsdtar`, but neither `xz` nor `zstd`. A generated 1 MiB patterned fixture produced:

```text
plain SHA-256: fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
gzip -dc:     fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
bzip2 -dc:    fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
bsdtar xz: Error opening archive: Unrecognized archive format
bsdtar zst: Can't initialize filter; unable to run program "zstd -d -qq"
```

Therefore macOS's archive utility alone does not establish support for raw compressed images.

## 2. Build bundled helpers

Built xz 5.6.4 and zstd 1.5.7 from source. Download hashes:

```text
269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b  xz-5.6.4.tar.gz
eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3  zstd-1.5.7.tar.gz
```

`scripts/build-compressors.sh` pins and verifies those archives. `scripts/build-app.sh` bundles the helpers and their upstream license notices when present. No Homebrew runtime path is required by these builds:

```text
xz:   /usr/lib/libSystem.B.dylib
zstd: /usr/lib/libz.1.dylib, /usr/lib/libSystem.B.dylib
bash -n scripts/build-compressors.sh scripts/build-app.sh: exit 0
```

## 3. Implementation and verification gates

Core scope: `CompressedImage.swift`, `RawDiskWriter.swift`, and `Checks/main.swift`. Check successful decode/write/read-back, corrupted input, capacity enforcement, cancellation, and multi-file ZIP rejection. Resource cleanup must stop a decompressor on early failure rather than wait indefinitely for stdout to drain.

UI scope: image selection, forced compressed DD mode, English status messages, and disabling settings that do not apply to DD. The GUI must be exercised through Cua in the Space after checks pass.

Size handling: the implementation deliberately does not trust gzip's modulo-4-GiB trailer or parse xz indexes. Decompressed length is unknown until EOF; capacity is enforced on each write. Progress is indeterminate during decompression and becomes determinate during read-back. A corrupt or oversized stream can leave a partially written target; it must never report success.

Cleanup: aborting before EOF closes the pipe and terminates the child. At normal EOF, the writer waits for the decompressor's natural exit status. Device handles are closed with `defer`, including thrown read/write/identity errors.

## 4. Full check harness in the Space

Built the final release app with `scripts/build-app.sh` (release build and signature verification passed), compiled `Checks/main.swift` with all core sources, and transferred the binary, app, bundled tools, and upstream boot resources into the scratch directory.

Ran from its `macos/` directory:

```sh
RUFUS_ALLOW_VIRTUAL_DISKS=1 RUFUS_TEST_VIRTUAL_DISK=disk11 \
  RUFUS_TEST_VIRTUAL_BACKING=/Users/lume/rufus-compressed-test.q6XKcC/target.img \
  .build/rufus-mac-check
```

Exit status: 0. Full output: [`verification/2026-10-29-compressed-checks.log`](verification/2026-10-29-compressed-checks.log).

```text
Compressed format detection and single-stream decompression checks passed
Multiple-file zip rejection checks passed
Corrupt and truncated compressed stream rejection checks passed
Virtual device write, read-back and DiskMountGuard checks passed
VirtualDiskFormatter GPT/FAT32 and exFAT+UEFI:NTFS media preparation checks passed
DD mode (RawDiskWriter) write and verification checks passed
Compressed DD mode write, capacity and cancellation checks passed
```

Tests cover gzip, bzip2, xz, zstd and single-member ZIP decoding against a patterned fixture; gzip/bzip2/xz/zstd virtual-device write/read-back; corrupt/truncated gzip; multi-member ZIP rejection; compressed capacity overflow and mid-stream cancellation. `.lzma` and `.Z` command paths are present but not separately exercised by this harness. These tests do not establish bootability or physical USB support.

## 5. Cua GUI write and independent read-back

Launched the newly built app from the scratch directory in Space `space-57caba4ef0` with `RUFUS_ALLOW_VIRTUAL_DISKS=1`. Selected `sample.img.xz` through the file picker. The UI selected and locked DD mode, disabled partition/filesystem/label controls, and targeted `disk11 · 134.2 MB` after typed confirmation. Disk10 was briefly selected while navigating the list, but no confirmation or write was started on it.

Screenshots independently reviewed:

- [`2026-10-29-compressed-selected.png`](verification/2026-10-29-compressed-selected.png): compressed fixture selected, DD mode forced, irrelevant controls disabled.
- [`2026-10-29-compressed-complete.png`](verification/2026-10-29-compressed-complete.png): exact status `DD write finished: 1 MB written, verified against the image.`

After the GUI completed, `hdiutil info -plist` confirmed `/dev/disk11` still belonged to `/Users/lume/rufus-compressed-test.q6XKcC/target.img`. Independent shell verification:

```sh
APP=/Users/lume/rufus-compressed-test.q6XKcC/macos/.build/RufusMac.app
"$APP/Contents/Resources/xz" -dc /Users/lume/rufus-compressed-test.q6XKcC/sample.img.xz | shasum -a 256
dd if=/dev/rdisk11 bs=1m count=1 2>/dev/null | shasum -a 256
```

Both returned:

```text
fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
```

This establishes decompression and correct device bytes, not Linux bootability, Windows installation success, or physical USB operation. NTFS, Windows To Go, persistence and other remaining port gaps are not closed by this change.

GUI fixture preparation: created `/Users/lume/rufus-compressed-test.q6XKcC` inside the Space. Its `sample.img.xz` is 520 bytes and expands to the patterned 1 MiB fixture above. A fresh 128 MiB `target.img` was attached as `/dev/disk11`; `hdiutil info` confirms that exact backing path. Existing `/Users/lume/usb.img` (`disk10`) was left unchanged. Device identifiers must be rechecked if attachments change.
