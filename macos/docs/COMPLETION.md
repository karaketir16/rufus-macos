# Completion pass — closing the remaining Windows User Experience gaps

Date: 2026-10-29
Branch: `codex/macos-port`
Scope: native macOS SwiftUI port of Rufus (`macos/`)

This document records every change made in this pass, why it was made, and the evidence that it works.
It is written so that a reader can re-run each verification step.

---

## 1. Where the port stood before this pass

`Task.md` (section J) listed four behaviours that upstream Rufus (`src/format.c`, `src/hash.c`,
`src/rufus.c`) implements but the port did not:

| Gap | Upstream reference |
| --- | --- |
| Silent install always used `/IMAGE/INDEX` 1 | `GetHostEdition()` / `CreateUnattendXml()` |
| No ` (SILENT)` suffix on the volume label | `src/format.c:1793-1796` |
| `md5sum.txt` / `MD5SUMS` was never refreshed | `UpdateMD5Sum()` in `src/hash.c:2472` |
| S Mode was generated but not reachable from the GUI (no expert mode) | `src/rufus.c:1745-1750` |
| "Not implemented" facts lived only in the README | — |

Everything below closes those gaps, and the untestable remainder (Windows To Go) is now stated **inside
the application**, not only in a Markdown file.

---

## 2. Changes

### 2.1 Volume label: ` (SILENT)` suffix and FAT sanitisation — `Sources/RufusCore/VolumeLabel.swift` (new)

`ToValidLabel()` (`src/format.c:263`) is now ported instead of the previous strict "A-Z 0-9 _ -" check:

* FAT labels are upper-cased, unauthorised characters (`*?,;:/\|+=<>[]"`) are dropped,
  tabs and dots become underscores, and the result is truncated to 11 characters.
* When a silent install is selected, ` (SILENT)` is appended **before** truncation — exactly like
  `FormatDrive()` does. `RUFUS` therefore becomes `RUFUS (SILE` on FAT32, which is what Windows Rufus
  also produces.
* A label that leaves nothing usable (for example `***`) still fails with `CreatorError.invalidLabel`.

`PhysicalUSBMediaCreator.prepareWindowsUSB(..., silentInstall:)` uses it and no longer carries its own
validator.

### 2.2 Silent-install edition selection — `WindowsMediaInspector`, `WindowsUserExperience`

* `WindowsMediaReport.Edition` (index, name, description) and `installEditions` were added.
* `WindowsMediaInspector.readImageInfo` now runs `wimlib-imagex info <image>` once and parses
  `Index:` / `Name:` / `Description:` / `Build:` / `Default Language:` through the new, unit-tested
  `parseImageInfo(_:)`. Build and language still come from the first image.
* `WindowsUserExperience.Selection.editionIndex` is written to the answer file as `/IMAGE/INDEX`;
  `resolvedEditionIndex(for:)` falls back to the image's first edition when the chosen index is not
  in the list (or when the list is empty because wimlib is unavailable).
* The "Windows User Experience" sheet shows a **"Edition to install:"** picker as soon as
  "Silent install" is enabled. Upstream picks the host edition; macOS has no Windows edition, so the
  user chooses from the image instead.

### 2.3 `md5sum.txt` refresh — `Sources/RufusCore/MD5SumUpdater.swift` (new)

Port of `UpdateMD5Sum()` (`src/hash.c:2472`):

* Looks for `md5sum.txt`, `md5sums` or `md5sum.lst` at the media root.
* Parses `hash  ./path` (GNU), `hash *path` (binary marker) and `hash path`.
* Recomputes the MD5 of every changed file and rewrites only its line; comments and untouched
  entries are preserved byte for byte.
* Path comparison is case-insensitive (FAT/exFAT).

`WindowsCustomization.apply` now returns `ApplyResult { log, modifiedPaths }` and lists every file it
touches (`sources/appraiserres.dll`, `setup.exe`, `setup.dll`, `sources/boot.wim`, the Panther answer
file, and each replaced bootloader/font). `WindowsMediaStager.stage` feeds that list to the updater.

### 2.4 Expert mode in the sheet — `Sources/RufusMacApp/WindowsUserExperienceSheet.swift`

An **"Expert mode (show additional options)"** toggle now drives `availableOptions(expertMode:)`, which
makes **S Mode** reachable from the GUI for the first time (upstream only offers it in expert mode).
The per-option notes and the status footer were rewritten to say what is now done.

### 2.5 Visible limitations — `Sources/RufusMacApp/KnownLimitationsSheet.swift` (new)

A **"Known limitations…"** button on the main window opens an English sheet with two sections:

* *Implemented* — disk selection, formatting, media layout, answer file, silent install + edition,
  media customisation, 2023 bootloaders, checksums, verification.
* *Not implemented* — Windows To Go, offline registry-hive editing, NTFS media, Linux/DD mode,
  VHD/FFU/compressed images/ext/UDF/ReFS, and the fact that no option has yet been proven by a full
  Windows installation.

This replaces "the missing feature is only in the README" with "the missing feature is in the UI".

### 2.6 English throughout

Every user-visible string in `RufusMacApp.swift`, `WindowsUserExperienceSheet.swift`,
`KnownLimitationsSheet.swift` and the two progress messages in `PhysicalUSBMediaCreator.swift` is now
English. The only Turkish identifiers left in the source are the reserved Windows account names in
`WindowsAnswerFile.swift` (`administratör` and friends), which are data, not UI.

---

## 3. Automated checks

`Checks/main.swift` was extended and the whole harness passes:

```console
$ swiftc Sources/RufusCore/*.swift Checks/main.swift -o /tmp/rufus-mac-check && /tmp/rufus-mac-check
...
Windows media staging checks passed
Full upstream Windows answer file checks passed
Windows User Experience dialog logic checks passed
Volume label checks passed
md5sum update checks passed
Install edition checks passed
MS2023 bootloader replacement checks passed
```

New checks:

| Check | Assertion |
| --- | --- |
| `VolumeLabel.sanitize("rufus", appendSilent: true)` | `RUFUS (SILE` |
| `VolumeLabel.sanitize("RUFUS (SILENT)")` | no duplicate suffix |
| `VolumeLabel.sanitize("my;usb")` | `MYUSB` |
| `VolumeLabel.sanitize("a.b")` | `A_B` |
| `VolumeLabel.sanitize("***")`, `"   "` | `nil` |
| 20-character label | truncated to 11 |
| `MD5SumUpdater.update` | rewrites both `./path` and `*path` lines, keeps comments/untouched lines, no-op on an empty change list |
| `WindowsMediaInspector.parseImageInfo` | build 26300, `en-US`, editions `[1 Home, 2 Pro]` |
| Silent install with `editionIndex: 2` | `<Key>/IMAGE/INDEX</Key><Value>2</Value>`, `<WillWipeDisk>true</WillWipeDisk>`, `<WillShowUI>OnError</WillShowUI>` |
| Unknown edition index | falls back to the first image |
| No edition list at all | falls back to 1 |

---

## 4. GUI test in a Cua Space (real ISO, real version of every code path)

Environment: `cua` Space `space-57caba4ef0` (macOS 26.5.2 VM, no USB passthrough), app built by
`scripts/build-app.sh`, 16 GiB `hdiutil` raw image exposed as `disk10`, real Windows 11 ISO
(`Win11.iso`, 9.05 GB, build 26300). Because the VM has no physical external disk, the app was started
with `RUFUS_ALLOW_VIRTUAL_DISKS=1`; the orange banner in the screenshots says so.

Everything after that was driven through the GUI with `cua do` (screenshot / click / type / hotkey).

| Step | Screenshot |
| --- | --- |
| App launched, English UI, orange dev-mode banner, new "Known limitations…" button | `docs/verification/2026-10-29-main-window-en.png` |
| START → Windows User Experience sheet, English labels and per-option notes | `docs/verification/2026-10-29-wue-sheet-en.png` |
| "Silent install" enabled → "Edition to install:" picker lists all 11 editions read from the ISO | `docs/verification/2026-10-29-wue-edition-list.png` |
| "6: Windows 11 Pro" chosen | `docs/verification/2026-10-29-wue-edition-selected.png` |
| Copy in progress ("Copying the Windows setup files…") | `docs/verification/2026-10-29-copy-in-progress.png` |
| Success: "USB installation media is ready: /Volumes/RUFUS (SILE" | `docs/verification/2026-10-29-media-ready.png` |
| Known limitations → Implemented | `docs/verification/2026-10-29-known-limitations.png` |
| Known limitations → Not implemented (Windows To Go first) | `docs/verification/2026-10-29-known-limitations-not-implemented.png` |

### 4.1 Artifacts produced by that GUI run

Captured inside the Space after the run:

```console
$ diskutil list disk10
/dev/disk10 (disk image):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        +17.2 GB    disk10
   1:       Microsoft Basic Data RUFUS (SILE             17.0 GB    disk10s2

$ diskutil info "/Volumes/RUFUS (SILE" | grep -E "Volume Name|File System Personality|Partition Type"
   Volume Name:               RUFUS (SILE
   Partition Type:            Microsoft Basic Data
   File System Personality:   MS-DOS FAT32

$ ls -lh "/Volumes/RUFUS (SILE/sources/" | grep install
-rwx------  1 lume  staff   3.7G Oct 29 11:00 install.swm
-rwx------  1 lume  staff   3.7G Oct 29 11:01 install2.swm
-rwx------  1 lume  staff   133M Oct 29 11:01 install3.swm

$ ls -l "/Volumes/RUFUS (SILE/setup.exe" "/Volumes/RUFUS (SILE/setup.dll"
-rwx------@ 1 lume  staff  150888 Oct 29 10:57 /Volumes/RUFUS (SILE/setup.exe   # bypass wrapper
-rwx------  1 lume  staff   99896 Sep 13 12:40 /Volumes/RUFUS (SILE/setup.dll    # original

$ ls -l "/Volumes/RUFUS (SILE/sources/appraiserres."*
-rwx------  1 lume  staff  161256 Sep 13 12:40 .../appraiserres.bak
-rwx------  1 lume  staff       0 Oct 29 11:02 .../appraiserres.dll            # emptied placeholder

$ wimlib-imagex extract ".../sources/boot.wim" 2 /Autounattend.xml --dest-dir=/tmp/verify2
$ grep -oE "<Key>/IMAGE/INDEX</Key><Value>[0-9]+</Value>|BypassTPMCheck|BypassNRO|WillWipeDisk>true" /tmp/verify2/Autounattend.xml
<Key>/IMAGE/INDEX</Key><Value>6</Value>
<WillWipeDisk>true</WillWipeDisk>
BypassNRO
BypassTPMCheck
```

Interpretation:

* Volume label `RUFUS (SILE` — the ` (SILENT)` suffix was appended and then truncated to 11 characters,
  matching upstream's FAT behaviour.
* `/IMAGE/INDEX` = **6**, the edition the picker showed as "Windows 11 Pro" (this ISO lists Home,
  Home N, Home Single Language, Education, Education N, Pro, …). The old code always wrote 1.
* GPT with a single `Microsoft Basic Data` partition and no EFI system partition — Rufus' layout.
* `install.wim` split into three `.swm` parts, all below the 4 GiB FAT32 limit.
* `setup.exe` replaced by the 150,888-byte bypass wrapper, original preserved as `setup.dll`.
* `appraiserres.dll` emptied with the original kept as `appraiserres.bak`.

### 4.2 What could not be shown in the Space

* The Windows 11 ISO ships **no** `md5sum.txt`, so the updater had nothing to rewrite there. It is
  covered by the unit checks in section 3 (both `./path` and `*path` forms, plus comment preservation).
* The Space is a VM without USB passthrough (`diskutil list external physical` is empty), so the run
  used a disk image. The physical path differs only in the device node that `diskutil` receives.

---

## 5. Remaining known gaps (also shown in-app)

| Gap | Why it cannot be closed here |
| --- | --- |
| Windows To Go | Needs an NTFS target and Windows' `bcdboot`; there is no supported macOS equivalent. |
| Offline `SYSTEM` hive edit | No registry API on macOS. The `windowsPE` answer-file pass is used instead — upstream's own fallback. |
| NTFS media / `UEFI:NTFS` on physical disks | Would require writing Rufus' chainloader to a second partition; not part of this port's tested scope. |
| Linux/DD mode, persistence, VHD/VHDX/FFU, compressed images, ext/UDF/ReFS | Separate feature set, not started. |
| Full Windows Setup validation | Needs a machine that boots the produced media; the artifacts were verified at file level only. |

---

## 6. Reproducing this pass

```console
$ cd macos
$ swiftc Sources/RufusCore/*.swift Checks/main.swift -o /tmp/rufus-mac-check && /tmp/rufus-mac-check
$ ./scripts/build-app.sh
$ open .build/RufusMac.app          # real USB
# or, inside a VM without USB passthrough:
$ RUFUS_ALLOW_VIRTUAL_DISKS=1 open .build/RufusMac.app
```
