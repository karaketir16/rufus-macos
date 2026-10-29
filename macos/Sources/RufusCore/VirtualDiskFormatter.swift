// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Formats an unmounted hdiutil-backed virtual device using Rufus's partition layout (`PartitionTable`)
/// and macOS filesystem tools (`/sbin/newfs_msdos`, `/sbin/newfs_exfat`) while guarded by `DiskMountGuard`.
public enum VirtualDiskFormatter {
    public enum FormatError: Error {
        case invalidTarget
        case changed
        case invalidLabel
        case unsupportedFilesystem
        case invalidUefiNtfsImage
        case sliceUnavailable
        case commandFailed(String, Int32, String)
        case system(Int32)
    }

    public static func format(
        target: VirtualDeviceWriter.Target,
        backingImage: URL,
        scheme: PartitionTable.Scheme = .gpt(),
        filesystem: PartitionTable.FilesystemKind = .fat32,
        volumeLabel: String = "RUFUS",
        uefiNTFSImage: URL? = nil
    ) throws -> PartitionTable.LayoutPlan {
        let label = try validateVolumeLabel(volumeLabel)
        guard filesystem == .fat32 || filesystem == .exfat else {
            throw FormatError.unsupportedFilesystem
        }

        let uefiData: Data?
        let uefiAlignedBytes: UInt64
        if let uefiURL = uefiNTFSImage {
            let values = try uefiURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 else {
                throw FormatError.invalidUefiNtfsImage
            }
            let raw = try Data(contentsOf: uefiURL)
            guard !raw.isEmpty else { throw FormatError.invalidUefiNtfsImage }
            let rem = UInt64(raw.count) % target.blockSize
            if rem == 0 {
                uefiData = raw
            } else {
                var padded = raw
                padded.append(Data(count: Int(target.blockSize - rem)))
                uefiData = padded
            }
            uefiAlignedBytes = UInt64(uefiData!.count)
        } else {
            uefiData = nil
            uefiAlignedBytes = 0
        }

        let plan = try PartitionTable.plan(
            scheme: scheme,
            totalBytes: target.capacity,
            blockSize: target.blockSize,
            filesystem: filesystem,
            uefiNTFSSizeBytes: uefiAlignedBytes
        )

        try DiskMountGuard.withUnmountedGuard(identifier: target.identifier) {
            guard try VirtualDeviceWriter.inspect(identifier: target.identifier, backingImage: backingImage) == target else {
                throw FormatError.changed
            }

            let rawWholePath = "/dev/r\(target.identifier)"
            var pathInfo = stat()
            guard lstat(rawWholePath, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFCHR else {
                throw FormatError.invalidTarget
            }
            let fd = open(rawWholePath, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
            guard fd >= 0 else { throw FormatError.system(errno) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFCHR,
                  opened.st_rdev == pathInfo.st_rdev,
                  try VirtualDeviceWriter.inspect(identifier: target.identifier, backingImage: backingImage) == target else {
                close(fd)
                throw FormatError.changed
            }

            do {
                let clearBytes = Data(count: Int(min(64 * 1024, target.capacity)))
                for part in plan.partitions {
                    try pwriteAll(fd: fd, data: clearBytes, offset: part.firstLBA * target.blockSize)
                }
                if case .mbr = scheme {
                    let gptHeaderClear = Data(count: Int(34 * target.blockSize))
                    try pwriteAll(fd: fd, data: gptHeaderClear, offset: 0)
                    if target.capacity > 34 * target.blockSize {
                        try pwriteAll(fd: fd, data: gptHeaderClear, offset: target.capacity - 34 * target.blockSize)
                    }
                }
                try pwriteAll(fd: fd, data: plan.primaryRegion, offset: 0)
                if let backupOffset = plan.backupRegionOffset, let backupData = plan.backupRegion {
                    try pwriteAll(fd: fd, data: backupData, offset: backupOffset)
                }
                if let uefiOffset = plan.uefiNTFSOffset, let uefiData {
                    try pwriteAll(fd: fd, data: uefiData, offset: uefiOffset)
                }
                guard fsync(fd) == 0 else { throw FormatError.system(errno) }
                close(fd)
            } catch {
                close(fd)
                throw error
            }

            let rawSlicePath = "/dev/r\(target.identifier)s1"
            try waitForCharacterDevice(path: rawSlicePath, timeout: 5.0)
            switch filesystem {
            case .fat32:
                try runTool("/sbin/newfs_msdos", ["-F", "32", "-v", label, rawSlicePath])
            case .exfat:
                try runTool("/sbin/newfs_exfat", ["-v", label, rawSlicePath])
            default:
                throw FormatError.unsupportedFilesystem
            }

            guard try VirtualDeviceWriter.inspect(identifier: target.identifier, backingImage: backingImage) == target else {
                throw FormatError.changed
            }
        }

        return plan
    }

    public static func prepareWindowsMedia(
        iso: URL,
        target: VirtualDeviceWriter.Target,
        backingImage: URL,
        scheme: PartitionTable.Scheme = .gpt(),
        filesystem: PartitionTable.FilesystemKind = .fat32,
        volumeLabel: String = "RUFUS",
        answerFile: String? = nil,
        wimlib: URL? = nil,
        uefiNTFSImage: URL? = nil
    ) throws -> PartitionTable.LayoutPlan {
        let plan = try format(
            target: target,
            backingImage: backingImage,
            scheme: scheme,
            filesystem: filesystem,
            volumeLabel: volumeLabel,
            uefiNTFSImage: uefiNTFSImage
        )
        let fm = FileManager.default
        let mountDir = fm.temporaryDirectory.appendingPathComponent("RufusDeviceMount-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: mountDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var mounted = false
        defer {
            if mounted {
                _ = try? DiskMountGuard.withUnmountedGuard(identifier: target.identifier) {}
            }
            try? fm.removeItem(at: mountDir)
        }
        try runTool("/usr/sbin/diskutil", ["mount", "-mountOptions", "nobrowse", "-mountPoint", mountDir.path, "\(target.identifier)s1"])
        mounted = true
        let maxFileBytes: UInt64 = (filesystem == .fat32) ? 4_294_967_295 : UInt64.max
        try WindowsMediaInspector.withMountedISO(iso) { isoMount in
            try WindowsMediaStager.stage(
                source: isoMount,
                destination: mountDir,
                answerFile: answerFile,
                wimlib: wimlib,
                maximumFileBytes: maxFileBytes
            )
        }
        try DiskMountGuard.withUnmountedGuard(identifier: target.identifier) {
            guard try VirtualDeviceWriter.inspect(identifier: target.identifier, backingImage: backingImage) == target else {
                throw FormatError.changed
            }
        }
        mounted = false
        return plan
    }

    private static func validateVolumeLabel(_ raw: String) throws -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !label.isEmpty, label.count <= 11,
              label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw FormatError.invalidLabel
        }
        return label
    }

    private static func pwriteAll(fd: Int32, data: Data, offset: UInt64) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let currentOffset = off_t(offset) + off_t(totalWritten)
                let written = Darwin.pwrite(fd, base.advanced(by: totalWritten), rawBuffer.count - totalWritten, currentOffset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FormatError.system(errno)
                }
                totalWritten += written
            }
        }
    }

    private static func waitForCharacterDevice(path: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var info = stat()
        while Date() < deadline {
            if lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFCHR {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw FormatError.sliceUnavailable
    }

    private static func runTool(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FormatError.commandFailed(executable, process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
}
