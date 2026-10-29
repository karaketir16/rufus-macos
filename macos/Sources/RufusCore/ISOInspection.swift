// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension WindowsMediaInspector {
    public enum ImageError: Error {
        case invalidFile
        case commandFailed(operation: String, status: Int32, details: String)
        case inspectionAndDetachFailed(inspection: Error, detach: Error, mountPoint: URL)
    }

    /// Temporarily mounts an image read-only, inspects it, then detaches it.
    public static func inspectISO(_ image: URL, wimlib: URL? = BundledTools.locateWimlib()) throws -> WindowsMediaReport {
        try withMountedISO(image) { try inspect(root: $0, wimlib: wimlib) }
    }

    static func withMountedISO<T>(_ image: URL, body: (URL) throws -> T) throws -> T {
        let properties = try image.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw ImageError.invalidFile }
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("RufusMount-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try runHdiutil(["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path], operation: "attach")
        } catch {
            try? FileManager.default.removeItem(at: mount)
            throw error
        }
        let result = Result { try body(mount) }
        do {
            try runHdiutil(["detach", mount.path], operation: "detach")
            try FileManager.default.removeItem(at: mount)
        } catch {
            if case .failure(let inspectionError) = result {
                throw ImageError.inspectionAndDetachFailed(inspection: inspectionError, detach: error, mountPoint: mount)
            }
            throw error
        }
        return try result.get()
    }

    private static func runHdiutil(_ arguments: [String], operation: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ImageError.commandFailed(operation: operation, status: process.terminationStatus, details: String(decoding: data, as: UTF8.self))
        }
    }
}
