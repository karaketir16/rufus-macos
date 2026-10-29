// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Experimental writer for unmounted hdiutil-backed virtual devices only.
/// This API refuses physical devices and is not exposed in the app.
public enum VirtualDeviceWriter {
    public struct Target: Equatable {
        public let identifier: String
        public let capacity: UInt64
        public let blockSize: UInt64
        public let registryID: UInt64
    }
    public enum WriterError: Error { case invalidTarget, changed, invalidSource, cancelled, system(Int32) }

    public static func inspect(identifier: String, backingImage: URL) throws -> Target {
        guard identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              backingImage.isFileURL else { throw WriterError.invalidTarget }
        let registry = try DiskIdentity.registryID(identifier)
        let images = try plist(command: "/usr/bin/hdiutil", arguments: ["info", "-plist"])
        guard let all = images["images"] as? [[String: Any]],
              let image = all.first(where: { item in
                  guard let path = item["image-path"] as? String, let actual = realpath(path, nil), let expected = realpath(backingImage.path, nil) else { return false }
                  defer { free(actual); free(expected) }
                  return String(cString: actual) == String(cString: expected)
              }), image["writeable"] as? Bool == true,
              let entities = image["system-entities"] as? [[String: Any]],
              entities.contains(where: { $0["dev-entry"] as? String == "/dev/\(identifier)" }),
              entities.allSatisfy({ $0["mount-point"] == nil }) else { throw WriterError.invalidTarget }
        let info = try plist(command: "/usr/sbin/diskutil", arguments: ["info", "-plist", identifier])
        guard info["DeviceIdentifier"] as? String == identifier, info["WholeDisk"] as? Bool == true,
              info["Internal"] as? Bool == false, info["VirtualOrPhysical"] as? String == "Virtual",
              let size = info["TotalSize"] as? UInt64, size > 0,
              let block = info["DeviceBlockSize"] as? UInt64, block > 0, block <= 1024 * 1024, (1024 * 1024) % block == 0,
              try DiskIdentity.registryID(identifier) == registry else { throw WriterError.invalidTarget }
        return Target(identifier: identifier, capacity: size, blockSize: block, registryID: registry)
    }

    public static func write(source: URL, target: Target, backingImage: URL, progress: (UInt64) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws {
        try DiskMountGuard.withUnmountedGuard(identifier: target.identifier) {
            try writeUnguarded(source: source, target: target, backingImage: backingImage, progress: progress, cancelled: cancelled)
        }
    }

    private static func writeUnguarded(source: URL, target: Target, backingImage: URL, progress: (UInt64) -> Void, cancelled: () -> Bool) throws {
        guard source.isFileURL else { throw WriterError.invalidSource }
        guard try inspect(identifier: target.identifier, backingImage: backingImage) == target else { throw WriterError.changed }
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw WriterError.system(errno) }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG, sourceInfo.st_size > 0,
              UInt64(sourceInfo.st_size) <= target.capacity, UInt64(sourceInfo.st_size) % target.blockSize == 0 else { throw WriterError.invalidSource }
        let path = "/dev/r\(target.identifier)"
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFCHR else { throw WriterError.invalidTarget }
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
        guard fd >= 0 else { throw WriterError.system(errno) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFCHR,
              opened.st_rdev == pathInfo.st_rdev,
              try inspect(identifier: target.identifier, backingImage: backingImage) == target else { throw WriterError.changed }
        var written: UInt64 = 0
        while written < UInt64(sourceInfo.st_size) {
            if cancelled() { throw WriterError.cancelled }
            guard let data = try input.read(upToCount: Int(min(1024 * 1024, UInt64(sourceInfo.st_size) - written))), !data.isEmpty, UInt64(data.count) % target.blockSize == 0 else { throw WriterError.invalidSource }
            try output.write(contentsOf: data)
            written += UInt64(data.count)
            progress(written)
        }
        var final = stat()
        guard fstat(sourceFD, &final) == 0, final.st_size == sourceInfo.st_size,
              final.st_mtimespec.tv_sec == sourceInfo.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == sourceInfo.st_mtimespec.tv_nsec else { throw WriterError.changed }
        try output.synchronize()
        guard try inspect(identifier: target.identifier, backingImage: backingImage) == target else { throw WriterError.changed }
    }

    /// Read back the image-sized prefix from an unmounted virtual disk.
    public static func verify(source: URL, target: Target, backingImage: URL, progress: (UInt64) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> Bool {
        try DiskMountGuard.withUnmountedGuard(identifier: target.identifier) {
            try verifyUnguarded(source: source, target: target, backingImage: backingImage, progress: progress, cancelled: cancelled)
        }
    }

    private static func verifyUnguarded(source: URL, target: Target, backingImage: URL, progress: (UInt64) -> Void, cancelled: () -> Bool) throws -> Bool {
        guard source.isFileURL else { throw WriterError.invalidSource }
        guard try inspect(identifier: target.identifier, backingImage: backingImage) == target else { throw WriterError.changed }
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw WriterError.system(errno) }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG, sourceInfo.st_size > 0,
              UInt64(sourceInfo.st_size) <= target.capacity, UInt64(sourceInfo.st_size) % target.blockSize == 0 else { throw WriterError.invalidSource }
        let path = "/dev/r\(target.identifier)"
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFCHR else { throw WriterError.invalidTarget }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK)
        guard fd >= 0 else { throw WriterError.system(errno) }
        let device = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? device.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFCHR, opened.st_rdev == pathInfo.st_rdev,
              try inspect(identifier: target.identifier, backingImage: backingImage) == target else { throw WriterError.changed }
        var compared: UInt64 = 0
        var equal = true
        while compared < UInt64(sourceInfo.st_size) {
            if cancelled() { throw WriterError.cancelled }
            let count = Int(min(1024 * 1024, UInt64(sourceInfo.st_size) - compared))
            guard let a = try input.read(upToCount: count), let b = try device.read(upToCount: count),
                  a.count == count, b.count == count else { throw WriterError.invalidSource }
            if a != b { equal = false; break }
            compared += UInt64(count)
            progress(compared)
        }
        var final = stat()
        guard fstat(sourceFD, &final) == 0, final.st_size == sourceInfo.st_size,
              final.st_mtimespec.tv_sec == sourceInfo.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == sourceInfo.st_mtimespec.tv_nsec,
              try inspect(identifier: target.identifier, backingImage: backingImage) == target else { throw WriterError.changed }
        return equal
    }

    private static func plist(command: String, arguments: [String]) throws -> [String: Any] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw WriterError.invalidTarget }
        return dict
    }
}
