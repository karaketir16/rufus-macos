// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Produces a disposable sparse image for testing, never a physical USB device.
public enum VirtualMediaBuilder {
    public enum BuildError: Error {
        case invalidDestination, existingDestination, wrongFilesystem, invalidRawImage, commandFailed(String, Int32, String)
        case detachFailed(URL, Error)
    }

    public static func create(iso: URL, destination: URL, sizeGiB: Int, answerFile: String?, wimlib: URL? = nil) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "sparseimage", (4...2048).contains(sizeGiB) else { throw BuildError.invalidDestination }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw BuildError.existingDestination }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("RufusVirtual-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let image = work.appendingPathComponent("media.sparseimage")
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        var mayRemove = true
        defer { if mayRemove { try? fm.removeItem(at: work) } }
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(sizeGiB)g", "-fs", "MS-DOS", "-volname", "RUFUS", "-type", "SPARSE", "-layout", "GPTSPUD", image.path])
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        mayRemove = false
        let result = Result {
            let data = try run("/usr/sbin/diskutil", ["info", "-plist", mount.path])
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["FilesystemName"] as? String == "MS-DOS FAT32" else { throw BuildError.wrongFilesystem }
            if let wholeDisk = info["ParentWholeDisk"] as? String,
               wholeDisk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil {
                let listData = try run("/usr/sbin/diskutil", ["list", "-plist", wholeDisk])
                if let listPlist = try PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
                   let allDisks = listPlist["AllDisksAndPartitions"] as? [[String: Any]],
                   let partitions = allDisks.first?["Partitions"] as? [[String: Any]] {
                    for part in partitions where part["Content"] as? String == "EFI" {
                        if let slice = part["DeviceIdentifier"] as? String,
                           slice.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil {
                            try run("/usr/sbin/diskutil", ["eraseVolume", "free", "none", slice])
                        }
                    }
                }
            }
            try WindowsMediaStager.stageISO(image: iso, destination: mount, answerFile: answerFile, wimlib: wimlib)
        }
        do { try run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]); mayRemove = true }
        catch { throw BuildError.detachFailed(work, error) }
        try result.get()
        // moveItem fails when destination already exists; no erase or overwrite is performed.
        try fm.moveItem(at: image, to: destination)
    }

    /// Convert a generated sparse disk image to a flat GPT disk image without overwriting a destination.
    public static func exportRaw(sparseImage: URL, destination: URL) throws {
        guard sparseImage.isFileURL, destination.isFileURL,
              sparseImage.pathExtension.lowercased() == "sparseimage", destination.pathExtension.lowercased() == "img" else { throw BuildError.invalidDestination }
        let sourceValues = try sparseImage.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else { throw BuildError.invalidDestination }
        var existing = stat()
        if lstat(destination.path, &existing) == 0 { throw BuildError.existingDestination }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let work = parent.appendingPathComponent(".RufusExport-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let converted = work.appendingPathComponent("media.dmg")
        try run("/usr/bin/hdiutil", ["convert", "-quiet", sparseImage.path, "-format", "UDRW", "-o", converted.path])
        let handle = try FileHandle(forReadingFrom: converted)
        let header = try handle.read(upToCount: 1024) ?? Data()
        try handle.close()
        guard header.count >= 1024, header[510] == 0x55, header[511] == 0xaa,
              String(data: header[512..<520], encoding: .ascii) == "EFI PART" else { throw BuildError.invalidRawImage }
        // link(2) atomically fails if destination exists, including a dangling symlink.
        guard link(converted.path, destination.path) == 0 else {
            if errno == EEXIST { throw BuildError.existingDestination }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
        guard process.terminationStatus == 0 else { throw BuildError.commandFailed(executable, process.terminationStatus, String(decoding: output, as: UTF8.self)) }
        return output
    }
}
