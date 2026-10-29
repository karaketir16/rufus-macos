import Foundation
import Darwin

/// Rufus' "DD mode": write an image byte for byte to a whole disk instead of copying its files.
///
/// Upstream offers this for images that are not Windows installation media (Linux ISOs and every other
/// hybrid image), and also as an explicit user choice. The device is written through `/dev/rdiskN` while
/// `DiskMountGuard` blocks Disk Arbitration from mounting anything on it, and the disk identity
/// (`DiskIdentity.Snapshot`) is re-validated before the device is opened and again after the write.
public enum RawDiskWriter {
    public enum WriteError: Error, Equatable {
        case invalidImage
        case imageLargerThanDisk
        case sourceOnTargetDisk
        case identityChanged
        case notWritable
        case cancelled
        case verificationFailed
        case system(Int32)
    }

    public struct Result {
        public let bytesWritten: UInt64
        public let verified: Bool
    }

    /// How the selected image is written: Rufus' two image modes.
    public enum Mode: String, CaseIterable, Identifiable {
        /// "ISO image mode": format the disk, copy the files, customise the media.
        case fileCopy
        /// "DD image mode": write the image byte for byte. Required for Linux and other hybrid images.
        case dd
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .fileCopy: return "ISO image mode (copy files)"
            case .dd: return "DD image mode (write the image byte for byte)"
            }
        }
    }

    /// Upstream preselects DD for images that are not Windows installation media (`img_report.is_windows`).
    public static func recommendsDD(for report: WindowsMediaReport) -> Bool {
        !(report.hasBootImage && report.installImage != nil)
    }

    /// Whole-disk size check: a raw image has to fit, be non-empty and be block aligned.
    public static func validate(imageSize: UInt64, diskSize: UInt64, blockSize: UInt64 = 512) -> WriteError? {
        guard imageSize > 0, blockSize > 0, imageSize % blockSize == 0 else { return .invalidImage }
        guard imageSize <= diskSize else { return .imageLargerThanDisk }
        return nil
    }

    public static func write(
        image: URL,
        selected: DiskIdentity.Snapshot,
        includeExternalUSBDisks: Bool,
        verify: Bool = true,
        statusUpdate: (String) -> Void = { _ in },
        progress: (Double) -> Void = { _ in },
        cancelled: () -> Bool = { false }
    ) throws -> Result {
        guard image.isFileURL else { throw WriteError.invalidImage }
        if try PhysicalUSBMediaCreator.isSourceLocatedOnTargetDisk(source: image, diskIdentifier: selected.identifier) {
            throw WriteError.sourceOnTargetDisk
        }
        let sourceFD = open(image.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw WriteError.invalidImage }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG else { throw WriteError.invalidImage }
        let imageSize = UInt64(sourceInfo.st_size)
        if let problem = validate(imageSize: imageSize, diskSize: selected.size) { throw problem }

        return try DiskMountGuard.withUnmountedGuard(identifier: selected.identifier) {
            let current = try DiskIdentity.snapshot(identifier: selected.identifier, includeExternalUSBDisks: includeExternalUSBDisks)
            guard DiskIdentity.matches(selected: selected, current: current) else { throw WriteError.identityChanged }

            statusUpdate("Writing image in DD mode to \(selected.identifier)…")
            let written = try writeDevice(image: image, imageSize: imageSize, identifier: selected.identifier,
                                          expected: selected, includeExternalUSBDisks: includeExternalUSBDisks,
                                          progress: progress, cancelled: cancelled)

            guard verify else { return Result(bytesWritten: written, verified: false) }
            statusUpdate("Verifying \(selected.identifier) against the image…")
            guard try verifyUnguarded(image: image, imageSize: imageSize, identifier: selected.identifier,
                                      expected: selected, includeExternalUSBDisks: includeExternalUSBDisks,
                                      progress: progress, cancelled: cancelled) else {
                throw WriteError.verificationFailed
            }
            return Result(bytesWritten: written, verified: true)
        }
    }

    /// Opens the raw device exclusively, streams the image and closes the handle again.
    /// Verification must happen afterwards: a second `O_EXLOCK` open of the same device fails with `EBUSY`.
    private static func writeDevice(
        image: URL,
        imageSize: UInt64,
        identifier: String,
        expected: DiskIdentity.Snapshot,
        includeExternalUSBDisks: Bool,
        progress: (Double) -> Void,
        cancelled: () -> Bool
    ) throws -> UInt64 {
        let sourceFD = open(image.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw WriteError.invalidImage }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, UInt64(sourceInfo.st_size) == imageSize else { throw WriteError.invalidImage }

        let path = "/dev/r\(identifier)"
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFCHR else { throw WriteError.notWritable }
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
        guard fd >= 0 else { throw WriteError.system(errno) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFCHR, opened.st_rdev == pathInfo.st_rdev else {
            try? output.close()
            throw WriteError.notWritable
        }
        let afterOpen = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: afterOpen) else {
            try? output.close()
            throw WriteError.identityChanged
        }

        var written: UInt64 = 0
        while written < imageSize {
            if cancelled() { try? output.close(); throw WriteError.cancelled }
            let chunk = Int(min(4 * 1024 * 1024, imageSize - written))
            guard let data = try input.read(upToCount: chunk), !data.isEmpty else {
                try? output.close()
                throw WriteError.invalidImage
            }
            try output.write(contentsOf: data)
            written += UInt64(data.count)
            progress(Double(written) / Double(imageSize))
        }
        // Flush the drive cache, not just the kernel buffer.
        _ = fcntl(fd, F_FULLFSYNC)
        try output.synchronize()
        try output.close()

        let afterWrite = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: afterWrite) else { throw WriteError.identityChanged }
        return written
    }

    /// Compares the image-sized prefix of the device with the image, 1 MiB at a time.
    static func verifyUnguarded(
        image: URL,
        imageSize: UInt64,
        identifier: String,
        expected: DiskIdentity.Snapshot,
        includeExternalUSBDisks: Bool,
        progress: (Double) -> Void = { _ in },
        cancelled: () -> Bool = { false }
    ) throws -> Bool {
        let sourceFD = open(image.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw WriteError.invalidImage }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, UInt64(sourceInfo.st_size) == imageSize else { throw WriteError.invalidImage }
        let deviceFD = open("/dev/r\(identifier)", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
        guard deviceFD >= 0 else { throw WriteError.system(errno) }
        let device = FileHandle(fileDescriptor: deviceFD, closeOnDealloc: true)
        defer { try? device.close() }
        let current = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: current) else { throw WriteError.identityChanged }
        var compared: UInt64 = 0
        while compared < imageSize {
            if cancelled() { throw WriteError.cancelled }
            let count = Int(min(1024 * 1024, imageSize - compared))
            guard let a = try input.read(upToCount: count), let b = try device.read(upToCount: count),
                  a.count == count, b.count == count else { throw WriteError.invalidImage }
            if a != b { return false }
            compared += UInt64(count)
            progress(Double(compared) / Double(imageSize))
        }
        let afterVerify = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: afterVerify) else { throw WriteError.identityChanged }
        return true
    }
}
