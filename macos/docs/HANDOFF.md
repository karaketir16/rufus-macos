# Handoff — where the Rufus macOS port stands

Last updated: 2026-10-29 (second English pass). Everything below was executed and verified in this
session; nothing is planned-but-unrun unless it says so.

## 1. Repository state

Branch `codex/macos-port`. Committed:

| Commit | Content |
| --- | --- |
| `b4bf7ae` | Windows User Experience completion: edition picker, ` (SILENT)` label, md5sum refresh, expert mode, English UI, Known-limitations sheet |
| `1d52e9c` | Docs: built-binary language check + real-ISO check run |
| (this pass) | DD image mode (`RawDiskWriter`), GUI mode picker, NTFS finding, docs |

Uncommitted at the time of writing (all intended to be committed together):

```
 M macos/Checks/main.swift
 M macos/Sources/RufusMacApp/KnownLimitationsSheet.swift
 M macos/Sources/RufusMacApp/RufusMacApp.swift
?? macos/Sources/RufusCore/RawDiskWriter.swift
?? macos/docs/HANDOFF.md            (this file)
 M macos/docs/COMPLETION.md
 M Task.md
```

## 2. What is implemented

* Disk discovery (external removable physical disks, opt-in external USB disks reported as fixed),
  identity re-validation before and after every write.
* GPT/MBR + FAT32/ExFAT formatting, Rufus' single-partition layout (macOS' ESP is removed again).
* Full `CreateUnattendXml` parity plus `ApplyWindowsCustomization`: `appraiserres.dll` placeholder,
  `setup.exe` bypass wrapper (build 26000+), `Autounattend.xml` in `boot.wim` image 2, Panther fallback,
  2023 CA bootloaders.
* Windows User Experience sheet: TPM/Secure Boot/RAM bypass, online-account bypass, local account,
  regional copy, privacy, BitLocker, QoL tweaks, silent install **with edition picker**, 2023 bootloaders,
  SkuSiPolicy, and S Mode behind an expert-mode toggle.
* ` (SILENT)` volume-label suffix, FAT label sanitisation/truncation, `md5sum.txt`/`MD5SUMS` refresh.
* **DD image mode** (`RawDiskWriter`): byte-for-byte write, `F_FULLFSYNC`, read-back comparison,
  `DiskMountGuard`, refusal of images that live on the target disk.
* English-only UI, plus an in-app "Known limitations…" sheet that lists what is and is not implemented.

## 3. Verification commands

```console
cd macos

# 1. Static checks (no disk writes)
swiftc Sources/RufusCore/*.swift Checks/main.swift -o /tmp/rufus-mac-check
/tmp/rufus-mac-check

# 2. Same checks plus the real Windows ISO
RUFUS_TEST_WINDOWS_ISO=~/Downloads/Windows11_Client_x64_en-us_26300_9457.iso /tmp/rufus-mac-check

# 3. Checks that need a scratch virtual disk (DD write, formatter, DiskMountGuard)
mkfile -n 128m /tmp/ddtest.img
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage /tmp/ddtest.img | awk '{print $1}')
RUFUS_ALLOW_VIRTUAL_DISKS=1 RUFUS_TEST_VIRTUAL_DISK=${DEV#/dev/} \
  RUFUS_TEST_VIRTUAL_BACKING=/tmp/ddtest.img /tmp/rufus-mac-check
hdiutil detach "$DEV"

# 4. App bundle
./scripts/build-app.sh           # -> .build/RufusMac.app
```

Note: stale `hdiutil` attachments to the same backing file make `VirtualDeviceWriter.inspect` fail with
`invalidTarget` (it matches the first image whose path resolves to the backing file). Detach leftovers
before running check 3.

## 4. GUI driving with Cua (how it was done)

```console
cua sb ls                                   # find the Space
cua do switch space-57caba4ef0              # the VM used for testing
cua sb cp /tmp/RufusMac.tar.gz local:space-57caba4ef0:/tmp/RufusMac.tar.gz
cua sb exec space-57caba4ef0 'pkill -f RufusMac; rm -rf ~/RufusMac.app; cd ~ && tar xzf /tmp/RufusMac.tar.gz && xattr -dr com.apple.quarantine RufusMac.app'
cua sb exec space-57caba4ef0 'launchctl setenv RUFUS_ALLOW_VIRTUAL_DISKS 1; open ~/RufusMac.app'
cua do screenshot                           # then click/type/hotkey at the coordinates seen in the shot
cua sb exec space-57caba4ef0 '<verification commands>'
```

The Space is a macOS VM with no USB passthrough, hence `RUFUS_ALLOW_VIRTUAL_DISKS=1` (orange banner in
the screenshots) and a `hdiutil` raw image as the target. Physical disks differ only in the device node.

## 5. Space state at handoff

`space-57caba4ef0` is running with the latest build. `~/usb.img` (16 GiB, `disk10`) currently contains the
raw Windows 11 ISO from the DD test:

```
/Users/lume/usb.img        17,179,869,184 bytes
disk10                     no partition table (raw ISO bytes)
Win11.iso                  9,047,330,816 bytes
first/last 64 MiB of device = first/last 64 MiB of ISO (SHA-256)
```

The last full-image SHA-256 comparison was started from the shell and interrupted by a CLI shutdown; the
app's own verification (read-back of the whole image) had already reported success, and the 64 MiB prefix
and suffix hashes match independently. Re-run if desired:

```console
cua sb exec space-57caba4ef0 'ISO=~/Win11.iso; SZ=$(stat -f%z $ISO); shasum -a 256 $ISO; head -c $SZ /dev/rdisk10 | shasum -a 256'
```

## 6. Open items and known blockers

1. **NTFS / `UEFI:NTFS` on physical disks — blocked by macOS.** Apple's `ntfs.fs` mounts NTFS read-only;
   a formatter was built (`mkntfs` from ntfs-3g 2022.10.3) and it does format a slice, but
   `touch /Volumes/NTFSVOL/x` returns "Read-only file system". Options: accept macFUSE + ntfs-3g as a
   dependency (needs the user's approval to install a kernel extension) or perform NTFS writes on Windows.
   Evidence: `docs/COMPLETION.md` §6.
2. **Windows To Go** — needs NTFS plus Windows' `bcdboot`; no macOS equivalent.
3. **Offline `SYSTEM` hive editing** — no registry API; the answer file's `windowsPE` pass is used instead
   (upstream's own fallback).
4. **Not started:** persistence partition, VHD/VHDX/FFU, compressed images (`.xz`, `.gz`, `.zst`, `.bz2`),
   ext2/3/4, UDF, ReFS, Syslinux/GRUB menus, badblocks, Fido (ISO download), localisation.
5. **No write has been performed on real USB hardware.** All writes so far targeted `hdiutil` disk images
   inside the Space. The physical path is the same code with a different device node, but the first real
   run should be watched: `diskutil` may ask for authorisation and every byte of the target disk is erased.

## 7. Screenshot index

`macos/docs/verification/`:

| File | What it shows |
| --- | --- |
| `2026-10-29-main-window-en.png` | English main window, dev-mode banner, "Known limitations…" |
| `2026-10-29-wue-sheet-en.png` | Windows User Experience sheet with per-option notes |
| `2026-10-29-wue-edition-list.png` | Edition list read from the ISO (11 editions) |
| `2026-10-29-wue-edition-selected.png` | "6: Windows 11 Pro" selected |
| `2026-10-29-copy-in-progress.png` | File-copy mode in progress |
| `2026-10-29-media-ready.png` | File-copy mode finished (`/Volumes/RUFUS (SILE`) |
| `2026-10-29-known-limitations*.png` | In-app limitations sheet, both sections |
| `2026-10-29-dd-mode-picker.png` | Image-mode picker (ISO vs DD) |
| `2026-10-29-dd-mode-selected.png` | DD selected, caption |
| `2026-10-29-dd-verifying.png`, `...-99.png` | Read-back verification at 50 % and 99 % |
| `2026-10-29-dd-complete.png` | "DD write finished: 9.05 GB written, verified against the image." |
| `windows-setup-qemu.png` | Earlier QEMU UEFI boot of a produced media |
