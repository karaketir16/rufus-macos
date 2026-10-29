// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Formats and prepares an explicitly selected external physical USB disk after revalidating
/// its `DiskIdentity.Snapshot` (BSD identifier, capacity, and IOKit registry entry ID).
/// Never runs automatically or during tests.
public enum PhysicalUSBMediaCreator {
    public enum Scheme: String, CaseIterable {
        case gpt = "GPT"
        case mbr = "MBRFormat"
    }

    public enum Filesystem: String, CaseIterable {
        case fat32 = "MS-DOS FAT32"
        case exfat = "ExFAT"
    }

    public enum CreatorError: Error {
        case confirmationMismatch
        case identityChanged
        case invalidLabel
        case sourceOnTargetDisk
        case formattedVolumeNotFound
        case commandFailed(String, Int32, String)
    }

    public static func isSourceLocatedOnTargetDisk(source: URL, diskIdentifier: String) throws -> Bool {
        guard diskIdentifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            return true
        }
        guard let srcCanonical = realpath(source.path, nil) else {
            return true
        }
        defer { free(srcCanonical) }
        let srcPath = String(cString: srcCanonical)

        let listData = try run("/usr/sbin/diskutil", ["list", "-plist", diskIdentifier])
        guard let plist = try PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return true
        }
        for diskEntry in allDisks {
            if let mp = diskEntry["MountPoint"] as? String, pathOverlaps(sourceCanonical: srcPath, mountPoint: mp) {
                return true
            }
            if let partitions = diskEntry["Partitions"] as? [[String: Any]] {
                for part in partitions {
                    if let mp = part["MountPoint"] as? String, pathOverlaps(sourceCanonical: srcPath, mountPoint: mp) {
                        return true
                    }
                }
            }
        }
        return false
    }

    public static func prepareWindowsUSB(
        selected: DiskIdentity.Snapshot,
        confirmationIdentifier: String,
        includeExternalUSBDisks: Bool,
        iso: URL,
        scheme: Scheme = .gpt,
        filesystem: Filesystem = .fat32,
        volumeLabel: String = "RUFUS",
        answerFile: String? = nil,
        silentInstall: Bool = false,
        useMS2023Bootloaders: Bool = false,
        wimlib: URL? = nil,
        statusUpdate: (String) -> Void = { _ in }
    ) throws -> URL {
        guard confirmationIdentifier == selected.identifier,
              selected.identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw CreatorError.confirmationMismatch
        }
        // Upstream appends " (SILENT)" to the label for unattended installation media (src/format.c:1794).
        guard let label = VolumeLabel.sanitize(volumeLabel, appendSilent: silentInstall) else {
            throw CreatorError.invalidLabel
        }

        let beforeSnapshot = try DiskIdentity.snapshot(identifier: selected.identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: selected, current: beforeSnapshot) else {
            throw CreatorError.identityChanged
        }

        if try isSourceLocatedOnTargetDisk(source: iso, diskIdentifier: selected.identifier) {
            throw CreatorError.sourceOnTargetDisk
        }

        statusUpdate("Formatting USB disk (\(selected.identifier), \(scheme == .gpt ? "GPT" : "MBR"), \(filesystem.rawValue))…")
        try run("/usr/sbin/diskutil", ["eraseDisk", filesystem.rawValue, label, scheme.rawValue, selected.identifier])

        let afterEraseSnapshot = try DiskIdentity.snapshot(identifier: selected.identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: selected, current: afterEraseSnapshot) else {
            throw CreatorError.identityChanged
        }

        let listData = try run("/usr/sbin/diskutil", ["list", "-plist", selected.identifier])
        guard let listPlist = try PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
              let allDisks = listPlist["AllDisksAndPartitions"] as? [[String: Any]],
              let partitions = allDisks.first?["Partitions"] as? [[String: Any]] else {
            throw CreatorError.formattedVolumeNotFound
        }

        if scheme == .gpt {
            for part in partitions where part["Content"] as? String == "EFI" {
                if let efiSlice = part["DeviceIdentifier"] as? String,
                   efiSlice.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil {
                    try run("/usr/sbin/diskutil", ["eraseVolume", "free", "none", efiSlice])
                }
            }
        }

        guard let dataSlice = partitions.first(where: { ($0["Content"] as? String) != "EFI" })?["DeviceIdentifier"] as? String,
              dataSlice.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else {
            throw CreatorError.formattedVolumeNotFound
        }

        let sliceInfoData = try run("/usr/sbin/diskutil", ["info", "-plist", dataSlice])
        guard let sliceInfo = try PropertyListSerialization.propertyList(from: sliceInfoData, format: nil) as? [String: Any],
              sliceInfo["ParentWholeDisk"] as? String == selected.identifier,
              let mountPoint = sliceInfo["MountPoint"] as? String, !mountPoint.isEmpty else {
            throw CreatorError.formattedVolumeNotFound
        }

        let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let maxFileBytes: UInt64 = (filesystem == .fat32) ? 4_294_967_295 : UInt64.max
        let resolvedWimlib = wimlib ?? BundledTools.locateWimlib()

        statusUpdate("Copying the Windows setup files to the USB disk (large WIM files are split if needed)…")
        try WindowsMediaStager.stageISO(
            image: iso,
            destination: mountURL,
            answerFile: answerFile,
            wimlib: resolvedWimlib,
            maximumFileBytes: maxFileBytes,
            allowVolumeMetadata: true,
            useMS2023Bootloaders: useMS2023Bootloaders
        )
        sync()

        let finalSnapshot = try DiskIdentity.snapshot(identifier: selected.identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: selected, current: finalSnapshot) else {
            throw CreatorError.identityChanged
        }
        return mountURL
    }

    private static func pathOverlaps(sourceCanonical: String, mountPoint: String) -> Bool {
        guard !mountPoint.isEmpty, let mpCanonical = realpath(mountPoint, nil) else { return false }
        defer { free(mpCanonical) }
        let mp = String(cString: mpCanonical)
        return sourceCanonical == mp || sourceCanonical.hasPrefix(mp + "/")
    }

    @discardableResult private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CreatorError.commandFailed(executable, process.terminationStatus, String(decoding: output, as: UTF8.self))
        }
        return output
    }
}
