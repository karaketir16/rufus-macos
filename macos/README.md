# Rufus macOS port (in development)

This is an incomplete native port of Rufus. The source is covered by the upstream GPL-3.0 license in `../LICENSE.txt`.

The initial core parses diskutil metadata conservatively and offers read-only enumeration of external, removable physical whole disks. Some real USB devices are reported as non-removable and are omitted by default; callers may explicitly request external, ejectable USB disks. Discovery is read-only and no inference is made that a listed disk is safe to erase without explicit user confirmation and identity re-validation.

Build with `swift build` in this directory. With the command-line tools alone, run the checks using `swiftc Sources/RufusCore/*.swift Checks/main.swift -o /tmp/rufus-mac-check && /tmp/rufus-mac-check`. XCTest is unavailable on this machine without Xcode.

`WindowsAnswerFile` implements full upstream `CreateUnattendXml` (`src/wue.c`) parity across `windowsPE`, `offlineServicing`, `specialize` and `oobeSystem`: hardware-check bypass (`BypassTPMCheck`, `BypassSecureBootCheck`, `BypassRAMCheck`), `<UserData>` EULA acceptance and empty product key, internal disks offline (`SanPolicy=4`), S Mode disable (`SkuPolicyRequired=1`), online-account bypass (`BypassNRO`), privacy-prompt suppression (`ProtectYourPC=3`), opt-in upstream QoL commands (OneDrive, Outlook and Teams removal plus 15 first-logon registry settings, `VisiblePlaces` start layout and Windows 11 classic context menu), optional `SkuSiPolicy.p7b` copy (`applySkuSiPolicy`), local administrator account creation with mandatory password change at first logon, automatic BitLocker/device encryption disable (`PreventDeviceEncryption` and `TCGSecurityActivationDisabled`), silent unattended disk partitioning/image installation (`silentInstall` with `RUFUS_BOOT` GPT layout), and regional/language/timezone duplication (`regionalOptions`). Its XML is validated by `XMLParser` and structural checks, and `WindowsCustomization` places it as upstream does (see below). Real Windows Setup execution of every unattended option remains to be verified.

### Status of the "Windows User Experience" options

Every option below changes only the answer file (and, for the 2023 bootloaders, media files). None has been
validated by an actual Windows installation, so treat all of them as untested rather than guaranteed.

| Option | Answer file / media effect | Status |
| --- | --- | --- |
| Bypass TPM/Secure Boot/RAM | `LabConfig` keys in `windowsPE` via `RunSynchronousCommand` | Implemented (XML fallback path only; no offline hive edit) |
| Bypass online account | `BypassNRO` in `specialize` | Implemented; Microsoft removed `BypassNRO` in some Windows 11 builds, where it may be inert |
| Create local account | `<LocalAccounts>` + `net user`/`net accounts` | Implemented; local administrator only |
| Duplicate regional settings | `<TimeZone>` + `Microsoft-Windows-International-Core` | Implemented; `<TimeZone>` is omitted when the host zone is not in the CLDR subset |
| Skip privacy prompts | `<ProtectYourPC>3`, `<HideEULAPage>` | Implemented |
| Silent install | Disk 0 GPT layout + `/IMAGE/INDEX` + international settings | Implemented: the edition is picked from the image's `wimlib-imagex` edition list (upstream uses the host edition); Disk 0 is still wiped without asking |
| Disable BitLocker/device encryption | `PreventDeviceEncryption`, `TCGSecurityActivationDisabled`, `DisableEncryptedDiskProvisioning` | Implemented |
| QoL enhancements | OneDrive/Outlook/Teams removal, 15 registry values, `VisiblePlaces`, classic context menu | Implemented; `HKCU` values land on the first user who signs in |
| 2023 UEFI CA bootloaders | `EFI_EX` extracted from `boot.wim` and swapped in | Implemented (verified against the real build-26300 ISO at the file level) |
| SkuSiPolicy.p7b | `mountvol S: /S` + copy in `FirstLogonCommands` | **Partial**: silently does nothing when the policy file is absent |
| S Mode | `SkuPolicyRequired=1` | Implemented; offered in the sheet once "Expert mode" is enabled (as upstream does) |

Also implemented in the media pipeline: the ` (SILENT)` volume-label suffix for unattended installs
(`src/format.c:1793`), FAT label sanitisation/truncation (`ToValidLabel()`), and the
`md5sum.txt`/`MD5SUMS` refresh for every file the port modifies (`UpdateMD5Sum()`); see
[`docs/COMPLETION.md`](docs/COMPLETION.md).

Two image modes are offered, as upstream does: ISO image mode (format, copy, customise) and **DD image
mode** (`RawDiskWriter`, byte-for-byte write with read-back verification, used for Linux and other hybrid
images). DD writes go through `/dev/rdiskN` behind `DiskMountGuard`, re-validate the disk identity before
and after the write, and refuse an image that lives on the target disk.

Not ported at all: Windows To Go (`SanPolicy=4` is coded but never offered), persistence,
VHD/VHDX/FFU and ext/UDF/ReFS. Compressed DD image support now includes gzip, bzip2, xz, zstd,
LZMA, compress (`.Z`) and single-member ZIP command paths; verified formats and limitations are recorded in
[`docs/COMPRESSED-IMAGES.md`](docs/COMPRESSED-IMAGES.md). Run `bash scripts/build-compressors.sh`
before building the app or running checks to provide the pinned xz/zstd helpers.
NTFS media with the `UEFI:NTFS` chainloader is
**blocked by macOS**, not merely unimplemented: Apple's `ntfs.fs` driver mounts NTFS read-only, so the
setup files cannot be copied onto it (measured in `docs/COMPLETION.md` §6). The application lists all of
this itself under "Known limitations…".

A read-only mounted-image inspector identifies common Windows UEFI bootloader names, install/boot images and files exceeding FAT32's single-file limit. It rejects symbolic links and unexpected file types. These findings do not establish that an image or device is bootable; real ISO and firmware validation remains outstanding.
The inspector can also attach a local ISO read-only with `hdiutil`, inspect it and detach it. The checks generate and mount a temporary test ISO and exercise an invalid image; no external disk is written. Detach failures are surfaced and can leave a mount point requiring manual cleanup.

Run the native SwiftUI interface with `swift run RufusMac` or build `.build/RufusMac.app` with `scripts/build-app.sh`. It follows the Rufus flow: pick a disk and an ISO, type the disk identifier to confirm, press START. For Windows 10/11 images without an existing `sources/$OEM$/$$/Panther/unattend.xml` a "Windows User Experience" sheet then offers the options Rufus offers for that image's build (`WindowsUserExperience`, port of `src/rufus.c:1696-1766`; the build is read with `wimlib-imagex info`). The choices are remembered (`UNATTEND_DEFAULT_MASK`), turned into an answer file and applied by `WindowsCustomization` (port of `ApplyWindowsCustomization`): with a `windowsPE` pass the file is added as `Autounattend.xml` to `boot.wim` image 2 and `appraiserres.dll` is replaced by an empty placeholder (plus the `setup.exe` wrapper for build >= 26000); otherwise it is copied to `sources/$OEM$/$$/Panther/unattend.xml`. Optional 2023-signed bootloaders are extracted from `boot.wim`. Not ported: offline `boot.wim` registry-hive editing, `md5sum.txt` update, Windows To Go, the ` (SILENT)` label. Physical USB erasing and Windows Setup behaviour have not been exercised by automated tests.

`WindowsMediaStager` copies a pre-inspected Windows directory or mounted ISO to an empty directory or freshly formatted volume (`allowVolumeMetadata: true` permits system-created `.fseventsd`/`.Spotlight-V100` entries), applies the answer file through `WindowsCustomization` (it is no longer copied to the media root), and splits oversized `sources/install.wim` files using `WIMSplitter` and `wimlib-imagex`.

`WIMSplitter` invokes `wimlib-imagex` to split a WIM and verifies that resulting pieces fit FAT32. `scripts/build-wimlib.sh` builds `wimlib-1.14.5` from pinned, SHA-256-verified upstream source into `.deps/wimlib-1.14.5`, and `scripts/build-app.sh` bundles `wimlib-imagex` and `res/uefi/uefi-ntfs.img` into `RufusMac.app/Contents/Resources` (discovered at runtime via `BundledTools`).

Read-only disk identity snapshots (`DiskIdentity.Snapshot`) include the disk identifier, capacity and IOKit registry entry ID; metadata is checked between two registry reads. A live read-only check compared snapshots for currently discovered devices.

`RawImage.copy` copies a regular file to a newly created regular file in blocks, reports progress, supports cancellation and removes its own incomplete output when safely identifiable. `RawImage.verify` compares regular files byte-for-byte, supports cancellation and detects observed size or modification-time changes.

`scripts/check-virtual-fat.py` creates a fresh disposable GPT sparse image, confirms its filesystem is FAT32, stages the generated fixture ISO at the volume root, and detaches it.

`scripts/build-app.sh` creates an ad-hoc deep-signed `.build/RufusMac.app` bundle containing `wimlib-imagex` and `uefi-ntfs.img`. This is not a notarized distribution.

Real-media integration evidence (2026-10-29): an existing Windows 11 x64 ISO (8.4 GiB, build 26300.9457) was inspected and staged to the root of a newly created 16 GiB GPT/FAT32 sparse disk image. The oversized `install.wim` was split, and `wimlib-imagex verify` with all `.swm` parts completed successfully. The temporary disk image was detached and deleted.

`VirtualMediaBuilder.create` assembles an ISO into a new disposable GPT/FAT32 sparse image, strips macOS's automatic 200 MB `EFI` System Partition (`C12A7328-F81F-11D2-BA4B-00A0C93EC93B`) via `diskutil eraseVolume free none` so Windows Setup does not fail due to multiple ESPs (`src/drive.c:2512`), and optionally adds an answer file and splits a WIM.

UEFI smoke test (2026-10-29): using the real Windows 11 x64 ISO noted above, `VirtualMediaBuilder` created 16 GiB GPT/FAT32 sparse media with split WIM. The image was converted to raw and attached as QEMU USB storage. QEMU 11.1.3, x86 TCG with `-cpu max`, q35 and the bundled non-Secure-Boot OVMF firmware reached the Windows 11 Setup language screen. See `docs/verification/windows-setup-qemu.png`.

`VirtualMediaBuilder.exportRaw` converts a generated sparse image into a flat `.img`, checks its MBR and GPT signatures and verifies that no conflicting EFI System Partition entry remains in the GPT table.

`DiskMountGuard` resolves the earlier Disk Arbitration blocker (`DADiskClaim` cannot claim `hdiutil` virtual disks because `diskimagesiod` already holds a claim on them, and `kDAReturnBusy` is a negative `DAReturn` that trapped when cast to `UInt32`). `DiskMountGuard.withUnmountedGuard` registers a `DARegisterDiskMountApprovalCallback` returning `DADissenterCreate(..., DAReturn(kDAReturnBusy), ...)` for all volumes belonging to the target whole disk before calling `DADiskUnmount(..., kDADiskUnmountOptionWhole, ...)`, and verifies IOKit `registryEntryID` invariants before and after the guarded scope.

`PartitionTable` generates Rufus-compatible single-partition GPT (`PARTITION_MICROSOFT_DATA` at 1 MiB, IEEE 802.3 CRC32 headers, protective MBR), dual-partition GPT with trailing `UEFI:NTFS` (`GPT_BASIC_DATA_ATTRIBUTE_NO_DRIVE_LETTER`), and single-partition MBR (`MBR_UEFI_MARKER = 0x49464555`) layouts directly in Swift (`src/drive.c:CreatePartition`). `VirtualDiskFormatter` combines `DiskMountGuard`, `PartitionTable`, `/sbin/newfs_msdos -F 32`, `/sbin/newfs_exfat`, and `res/uefi/uefi-ntfs.img` to format and populate virtual USB disks end-to-end without leaving a conflicting second ESP.
