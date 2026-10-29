// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Creates a new raw image file. This API does not write block devices.
public enum RawImage {
    public enum CopyError: Error { case invalidSource, sourceChanged, cancelled, system(Int32) }

    public static func copy(source: URL, destination: URL, progress: (UInt64) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws {
        guard source.isFileURL, destination.isFileURL else { throw CopyError.invalidSource }
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw CopyError.system(errno) }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceStat = stat()
        guard fstat(inputFD, &sourceStat) == 0, (sourceStat.st_mode & S_IFMT) == S_IFREG, sourceStat.st_size >= 0 else { throw CopyError.invalidSource }
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw CopyError.system(errno) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        var outputStat = stat()
        guard fstat(outputFD, &outputStat) == 0 else { let error = errno; try? output.close(); throw CopyError.system(error) }
        var completed = false
        defer {
            try? output.close()
            if !completed {
                var current = stat()
                if lstat(destination.path, &current) == 0 && current.st_dev == outputStat.st_dev && current.st_ino == outputStat.st_ino {
                    _ = unlink(destination.path)
                }
            }
        }
        var copied: UInt64 = 0
        while true {
            if cancelled() { throw CopyError.cancelled }
            guard let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty else { break }
            try output.write(contentsOf: block)
            copied += UInt64(block.count)
            progress(copied)
        }
        var endStat = stat()
        guard fstat(inputFD, &endStat) == 0, endStat.st_size == sourceStat.st_size,
              endStat.st_mtimespec.tv_sec == sourceStat.st_mtimespec.tv_sec,
              endStat.st_mtimespec.tv_nsec == sourceStat.st_mtimespec.tv_nsec,
              copied == UInt64(sourceStat.st_size) else { throw CopyError.sourceChanged }
        if cancelled() { throw CopyError.cancelled }
        try output.synchronize()
        completed = true
    }
    /// Compare regular files byte for byte without loading images into memory.
    public static func verify(source: URL, destination: URL, progress: (UInt64) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> Bool {
        guard source.isFileURL, destination.isFileURL else { throw CopyError.invalidSource }
        func openRegular(_ url: URL) throws -> (FileHandle, stat) {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw CopyError.system(errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { try? handle.close(); throw CopyError.invalidSource }
            return (handle, info)
        }
        let (left, leftStart) = try openRegular(source)
        defer { try? left.close() }
        let (right, rightStart) = try openRegular(destination)
        defer { try? right.close() }
        if leftStart.st_size != rightStart.st_size { return false }
        var compared: UInt64 = 0
        while true {
            if cancelled() { throw CopyError.cancelled }
            let a = try left.read(upToCount: 1024 * 1024) ?? Data()
            let b = try right.read(upToCount: 1024 * 1024) ?? Data()
            if a != b { return false }
            if a.isEmpty { break }
            compared += UInt64(a.count)
            progress(compared)
        }
        var leftEnd = stat(), rightEnd = stat()
        guard fstat(left.fileDescriptor, &leftEnd) == 0, fstat(right.fileDescriptor, &rightEnd) == 0,
              leftEnd.st_size == leftStart.st_size, rightEnd.st_size == rightStart.st_size,
              leftEnd.st_mtimespec.tv_sec == leftStart.st_mtimespec.tv_sec,
              leftEnd.st_mtimespec.tv_nsec == leftStart.st_mtimespec.tv_nsec,
              rightEnd.st_mtimespec.tv_sec == rightStart.st_mtimespec.tv_sec,
              rightEnd.st_mtimespec.tv_nsec == rightStart.st_mtimespec.tv_nsec,
              compared == UInt64(leftStart.st_size) else { throw CopyError.sourceChanged }
        return true
    }

}
