// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Rufus' "DD mode": write an image byte for byte to a whole disk instead of copying its files.
///
/// Upstream offers this for images that are not Windows installation media (Linux ISOs and every other
/// hybrid image), and also as an explicit user choice. The device is written through `/dev/rdiskN` while
/// `DiskMountGuard` blocks Disk Arbitration from mounting anything on it, and the disk identity
/// (`DiskIdentity.Snapshot`) is re-validated before the device is opened and again after the write.
///
/// Compressed images (`.gz`, `.bz2`, `.xz`, `.lzma`, `.zst`, `.Z`, `.zip`) go through the same path;
/// their bytes are decompressed on the fly and the resulting stream is verified by decompressing it a
/// second time and comparing it with the device, exactly like an uncompressed image.
public enum RawDiskWriter {
    public enum WriteError: Error, Equatable {
        case invalidImage
        case imageLargerThanDisk
        case sourceOnTargetDisk
        case identityChanged
        case notWritable
        case cancelled
        case verificationFailed
        case streamFailed
        case decompressor(CompressedImage.DecompressError)
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

    /// Upstream preselects DD for images that are not Windows installation media (`img_report.is_windows`),
    /// and always for compressed images, which cannot be inspected as file systems.
    public static func recommendsDD(for report: WindowsMediaReport) -> Bool {
        !(report.hasBootImage && report.installImage != nil)
    }

    /// A compressed image can only be written in DD mode; there is nothing to browse.
    public static func requiresDD(imageURL: URL) -> Bool {
        CompressedImage.Format.detect(imageURL) != nil
    }

    /// Whole-disk size check: a raw image has to fit, be non-empty and be block aligned.
    public static func validate(imageSize: UInt64, diskSize: UInt64, blockSize: UInt64 = 512) -> WriteError? {
        guard imageSize > 0, blockSize > 0, imageSize % blockSize == 0 else { return .invalidImage }
        guard imageSize <= diskSize else { return .imageLargerThanDisk }
        return nil
    }

    // MARK: - Public entry points

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
        let source = try fileSource(image)
        if let problem = validate(imageSize: source.size ?? 0, diskSize: selected.size) { throw problem }

        return try performWrite(
            makeSource: { try fileSource(image) },
            knownSize: source.size,
            selected: selected,
            includeExternalUSBDisks: includeExternalUSBDisks,
            verify: verify,
            statusUpdate: statusUpdate,
            progress: progress,
            cancelled: cancelled,
            runningSource: source
        )
    }

    /// Rufus' handling of compressed images: decompress to the device and verify against the same
    /// decompressed stream. The uncompressed size is checked up front when the format records it.
    public static func writeCompressed(
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
        let command: CompressedImage.Command
        do {
            command = try CompressedImage.command(for: image)
        } catch let error as CompressedImage.DecompressError {
            throw WriteError.decompressor(error)
        }
        if let estimated = command.estimatedSize, estimated > selected.size {
            throw WriteError.imageLargerThanDisk
        }
        return try performWrite(
            makeSource: { try decompressorSource(command) },
            knownSize: command.estimatedSize,
            selected: selected,
            includeExternalUSBDisks: includeExternalUSBDisks,
            verify: verify,
            statusUpdate: statusUpdate,
            progress: progress,
            cancelled: cancelled,
            runningSource: nil
        )
    }

    // MARK: - Streams

    /// One image source: a plain file or the stdout of a decompressor.
    private final class StreamSource {
        let size: UInt64?
        let read: (Int) throws -> Data
        let finish: () throws -> Void

        init(size: UInt64?, read: @escaping (Int) throws -> Data, finish: @escaping () throws -> Void) {
            self.size = size
            self.read = read
            self.finish = finish
        }
    }

    private static func fileSource(_ url: URL) throws -> StreamSource {
        let sourceFD = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw WriteError.invalidImage }
        let handle = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        var info = stat()
        guard fstat(sourceFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw WriteError.invalidImage
        }
        let size = UInt64(info.st_size)
        return StreamSource(
            size: size,
            read: { count in try readFully(handle, count) },
            finish: { try? handle.close() }
        )
    }

    private static func decompressorSource(_ command: CompressedImage.Command) throws -> StreamSource {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw WriteError.decompressor(.launchFailed)
        }
        let output = pipe.fileHandleForReading
        let stateLock = NSLock()
        var finished = false
        var eofReached = false
        return StreamSource(
            size: command.estimatedSize,
            read: { count in
                let data = try readFully(output, count)
                if data.count < count {
                    stateLock.lock()
                    eofReached = true
                    stateLock.unlock()
                }
                return data
            },
            finish: {
                stateLock.lock()
                defer { stateLock.unlock() }
                guard !finished else { return }
                finished = true
                // Close the reading end first so an abandoned child is unblocked by SIGPIPE
                // instead of hanging in a write() while we wait for it below.
                try? output.close()
                // Only terminate if we are cleaning up before reaching EOF. At EOF the child
                // has already closed stdout and we should wait for its natural exit status.
                if !eofReached && process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw WriteError.decompressor(.decompressionFailed(process.terminationStatus))
                }
            }
        )
    }

    /// Reads up to `count` bytes, looping over short reads. Returns fewer bytes only at end of stream.
    private static func readFully(_ handle: FileHandle, _ count: Int) throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: count - buffer.count)
            } catch {
                throw WriteError.streamFailed
            }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
        }
        return buffer
    }

    // MARK: - Write and verify

    private static func performWrite(
        makeSource: () throws -> StreamSource,
        knownSize: UInt64?,
        selected: DiskIdentity.Snapshot,
        includeExternalUSBDisks: Bool,
        verify: Bool,
        statusUpdate: (String) -> Void,
        progress: (Double) -> Void,
        cancelled: () -> Bool,
        runningSource: StreamSource?
    ) throws -> Result {
        return try DiskMountGuard.withUnmountedGuard(identifier: selected.identifier) {
            let current = try DiskIdentity.snapshot(identifier: selected.identifier, includeExternalUSBDisks: includeExternalUSBDisks)
            guard DiskIdentity.matches(selected: selected, current: current) else { throw WriteError.identityChanged }

            let source: StreamSource
            if let runningSource {
                source = runningSource
            } else {
                source = try makeSource()
            }
            statusUpdate("Writing image in DD mode to \(selected.identifier)…")
            let written: UInt64
            do {
                written = try writeStream(
                    source: source,
                    knownSize: knownSize,
                    diskSize: selected.size,
                    identifier: selected.identifier,
                    expected: selected,
                    includeExternalUSBDisks: includeExternalUSBDisks,
                    progress: progress,
                    cancelled: cancelled
                )
                try source.finish()
            } catch {
                try? source.finish()
                throw error
            }

            guard verify else { return Result(bytesWritten: written, verified: false) }
            statusUpdate("Verifying \(selected.identifier) against the image…")
            let verificationSource = try makeSource()
            let matches: Bool
            do {
                matches = try compareStream(
                    source: verificationSource,
                    written: written,
                    identifier: selected.identifier,
                    expected: selected,
                    includeExternalUSBDisks: includeExternalUSBDisks,
                    progress: progress,
                    cancelled: cancelled
                )
                try verificationSource.finish()
            } catch {
                try? verificationSource.finish()
                throw error
            }
            guard matches else { throw WriteError.verificationFailed }
            return Result(bytesWritten: written, verified: true)
        }
    }

    /// Streams the source to `/dev/rdiskN`, padding the final partial block with zeros (a raw device
    /// only accepts whole blocks). Aborts as soon as the stream no longer fits on the disk.
    private static func writeStream(
        source: StreamSource,
        knownSize: UInt64?,
        diskSize: UInt64,
        identifier: String,
        expected: DiskIdentity.Snapshot,
        includeExternalUSBDisks: Bool,
        progress: (Double) -> Void,
        cancelled: () -> Bool
    ) throws -> UInt64 {
        let path = "/dev/r\(identifier)"
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFCHR else { throw WriteError.notWritable }
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
        guard fd >= 0 else { throw WriteError.system(errno) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFCHR, opened.st_rdev == pathInfo.st_rdev else {
            throw WriteError.notWritable
        }
        let afterOpen = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: afterOpen) else {
            throw WriteError.identityChanged
        }

        let blockSize: UInt64 = 512
        let chunkSize = 4 * 1024 * 1024
        var written: UInt64 = 0
        if knownSize == nil { progress(-1) } // indeterminate: the decompressed size is not recorded
        while true {
            if cancelled() { throw WriteError.cancelled }
            var block = try source.read(chunkSize)
            if block.isEmpty { break }
            if block.count % Int(blockSize) != 0 {
                block.append(Data(count: Int(blockSize) - block.count % Int(blockSize)))
            }
            guard written + UInt64(block.count) <= diskSize else {
                throw WriteError.imageLargerThanDisk
            }
            try output.write(contentsOf: block)
            written += UInt64(block.count)
            if let knownSize, knownSize > 0 {
                progress(min(0.999, Double(written) / Double(max(knownSize, written))))
            }
        }
        guard written > 0 else { throw WriteError.invalidImage }
        // Flush the drive cache, not just the kernel buffer.
        _ = fcntl(fd, F_FULLFSYNC)
        try output.synchronize()

        let afterWrite = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: afterWrite) else { throw WriteError.identityChanged }
        progress(1)
        return written
    }

    /// Compares the freshly regenerated image stream with the first `written` bytes of the device.
    private static func compareStream(
        source: StreamSource,
        written: UInt64,
        identifier: String,
        expected: DiskIdentity.Snapshot,
        includeExternalUSBDisks: Bool,
        progress: (Double) -> Void,
        cancelled: () -> Bool
    ) throws -> Bool {
        let deviceFD = open("/dev/r\(identifier)", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
        guard deviceFD >= 0 else { throw WriteError.system(errno) }
        let device = FileHandle(fileDescriptor: deviceFD, closeOnDealloc: true)
        defer { try? device.close() }
        let current = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: current) else { throw WriteError.identityChanged }

        let blockSize = 512
        let chunkSize = 1024 * 1024
        var compared: UInt64 = 0
        while true {
            if cancelled() { throw WriteError.cancelled }
            var block = try source.read(chunkSize)
            if block.isEmpty { break }
            if block.count % blockSize != 0 {
                block.append(Data(count: blockSize - block.count % blockSize))
            }
            let deviceData = try readFully(device, block.count)
            guard deviceData.count == block.count, deviceData == block else { return false }
            compared += UInt64(block.count)
            if written > 0 { progress(min(1, Double(compared) / Double(written))) }
        }
        guard compared == written else { return false }
        let afterVerify = try DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
        guard DiskIdentity.matches(selected: expected, current: afterVerify) else { throw WriteError.identityChanged }
        return true
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
        let source = try fileSource(image)
        guard source.size == imageSize else {
            try? source.finish()
            throw WriteError.invalidImage
        }
        defer { try? source.finish() }
        return try compareStream(
            source: source,
            written: imageSize,
            identifier: identifier,
            expected: expected,
            includeExternalUSBDisks: includeExternalUSBDisks,
            progress: progress,
            cancelled: cancelled
        )
    }
}
