import SwiftUI

/// Honest, always-available list of what this port does and does not do.
/// Kept in the UI so nobody has to read the README to learn a feature is missing.
struct KnownLimitationsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let implemented: [(String, String)] = [
        ("Disk selection", "External removable physical disks, plus external USB disks reported as fixed. Read-only inventory, identity re-validated before and after erasing."),
        ("Formatting", "GPT or MBR with FAT32 (WIM files over 4 GB are split automatically) or ExFAT."),
        ("Media layout", "Rufus' single-partition USB layout: the EFI system partition macOS creates is removed again."),
        ("Windows answer file", "Full `autounattend.xml` parity: TPM/Secure Boot/RAM bypass, online-account bypass, local account, regional copy, privacy, BitLocker, S Mode, QoL tweaks, silent install."),
        ("Silent install", "Edition is chosen from the image's edition list and written as `/IMAGE/INDEX`; the volume label gets the ` (SILENT)` suffix."),
        ("Media customization", "`appraiserres.dll` placeholder, `setup.exe` bypass wrapper for build 26000+, `Autounattend.xml` inside `boot.wim`, Panther fallback for answer files without a `windowsPE` pass."),
        ("2023 bootloaders", "`Windows\\Boot\\EFI_EX` and `Fonts_EX` are extracted from `boot.wim` and swapped in."),
        ("Checksums", "`md5sum.txt`/`MD5SUMS` at the media root are refreshed for every file the port changes."),
        ("Verification", "Every write re-validates the disk identity; ISO content is inspected before anything is erased.")
    ]

    private let missing: [(String, String)] = [
        ("Windows To Go", "Not implemented. It needs an NTFS volume and Windows' own `bcdboot`; there is no supported way to do it from macOS."),
        ("Offline registry hive edit", "`boot.wim`'s SYSTEM hive is not edited. The TPM/Secure Boot/RAM bypass is written through the answer file's `windowsPE` pass, which is also upstream's fallback."),
        ("NTFS media", "Not offered. Rufus only uses NTFS together with its `UEFI:NTFS` chain, which this port does not write to physical disks."),
        ("Linux and DD mode", "Linux ISOs, Syslinux/GRUB, FreeDOS, persistence and raw DD writing are not ported."),
        ("Other images and filesystems", "VHD/VHDX/FFU, compressed images (`.xz`, `.gz`, `.zst`, `.bz2`), ext2/3/4, UDF and ReFS are not supported."),
        ("Windows Setup verification", "No option here has been validated by a complete Windows installation, and physical USB writes have only been exercised against disk images in a VM.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Known limitations").font(.title2.bold())
            Text("What this port does today, and what it deliberately does not do.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Implemented", entries: implemented)
                    Divider()
                    section("Not implemented", entries: missing)
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, maxWidth: 620, maxHeight: 640)
    }

    private func section(_ title: String, entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(entries, id: \.0) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.0).font(.subheadline.bold())
                    Text(entry.1).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
