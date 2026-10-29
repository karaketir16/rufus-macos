// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

public struct WindowsMediaReport {
    /// One installable edition inside `sources/install.wim` (`wimlib-imagex info` `Index`/`Name`).
    public struct Edition: Equatable, Identifiable {
        public let index: Int
        public let name: String
        public let description: String?
        public var id: Int { index }

        public init(index: Int, name: String, description: String? = nil) {
            self.index = index
            self.name = name
            self.description = description
        }
    }

    public let architectures: Set<WindowsAnswerFile.Architecture>
    public let installImage: String?
    public let oversizedFiles: [String]
    public let hasBootImage: Bool
    /// Windows build number read from the first install image (nil if unavailable). Mirrors `img_report.win_version.build`.
    public let windowsBuild: Int?
    /// Default language of the install image, e.g. `en-US`.
    public let defaultLanguage: String?
    /// True when `sources/$OEM$/$$/Panther/unattend.xml` already exists (upstream then skips the Windows User Experience dialog).
    public let hasPantherUnattend: Bool
    /// Editions available in the install image, in image order. Empty when wimlib is unavailable or the image could not be read.
    public let installEditions: [Edition]

    public init(architectures: Set<WindowsAnswerFile.Architecture>, installImage: String?, oversizedFiles: [String], hasBootImage: Bool, windowsBuild: Int? = nil, defaultLanguage: String? = nil, hasPantherUnattend: Bool = false, installEditions: [Edition] = []) {
        self.architectures = architectures
        self.installImage = installImage
        self.oversizedFiles = oversizedFiles
        self.hasBootImage = hasBootImage
        self.windowsBuild = windowsBuild
        self.defaultLanguage = defaultLanguage
        self.hasPantherUnattend = hasPantherUnattend
        self.installEditions = installEditions
    }

    /// Upstream `IS_WINDOWS_11`: build 22000 or later.
    public var isWindows11: Bool { (windowsBuild ?? 0) >= 22000 }
    /// Upstream `IS_WINDOWS_1X`: Windows 10 or 11 (build 10240+).
    public var isWindows1X: Bool { (windowsBuild ?? 0) >= 10240 }
}

/// `.sheet(item:)` needs identity: a report is fully described by the image it came from.
extension WindowsMediaReport: Identifiable {
    public var id: String {
        "\(windowsBuild ?? 0)|\(installImage ?? "-")|\(defaultLanguage ?? "-")"
    }
}

public enum WindowsMediaInspector {
    public enum InspectionError: Error { case invalidRoot, unreadable(URL), unsupportedEntry(URL), duplicatePath(String) }
    /// Inspects a mounted image or directory without modifying it. Findings are not proof of bootability.
    public static func inspect(root: URL, maximumFileBytes: UInt64 = 4_294_967_295, wimlib: URL? = BundledTools.locateWimlib()) throws -> WindowsMediaReport {
        let manager = FileManager.default
        let suppliedRoot = root.standardizedFileURL
        let rootValues = try suppliedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw InspectionError.invalidRoot }
        guard let canonical = realpath(suppliedRoot.path, nil) else { throw InspectionError.invalidRoot }
        defer { free(canonical) }
        let rootURL = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw InspectionError.invalidRoot }
        var paths: [String: String] = [:]
        var oversized: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw InspectionError.unsupportedEntry(url) }
            let relative = String(url.path.dropFirst(rootURL.path.count + (rootURL.path == "/" ? 0 : 1)))
            let key = relative.lowercased()
            guard paths[key] == nil else { throw InspectionError.duplicatePath(relative) }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0 else { throw InspectionError.unreadable(url) }
                paths[key] = relative
                if UInt64(size) > maximumFileBytes { oversized.append(relative) }
            }
        }
        if let error = enumerationError { throw error }
        var architectures = Set<WindowsAnswerFile.Architecture>()
        if paths["efi/boot/bootx64.efi"] != nil { architectures.insert(.amd64) }
        if paths["efi/boot/bootaa64.efi"] != nil { architectures.insert(.arm64) }
        if paths["efi/boot/bootia32.efi"] != nil { architectures.insert(.x86) }
        let installImage = paths["sources/install.wim"] ?? paths["sources/install.esd"] ?? paths["sources/install.swm"]
        var build: Int?
        var language: String?
        var editions: [WindowsMediaReport.Edition] = []
        if let wimlib = wimlib, let image = installImage, !image.lowercased().hasSuffix(".swm") {
            (build, language, editions) = readImageInfo(wimlib: wimlib, image: rootURL.appendingPathComponent(image))
        }
        return WindowsMediaReport(architectures: architectures, installImage: installImage, oversizedFiles: oversized.sorted(), hasBootImage: paths["sources/boot.wim"] != nil, windowsBuild: build, defaultLanguage: language, hasPantherUnattend: paths["sources/$oem$/$$/panther/unattend.xml"] != nil, installEditions: editions)
    }

    /// Reads build, default language and the edition list from `wimlib-imagex info <image>` (read-only).
    static func readImageInfo(wimlib: URL, image: URL) -> (Int?, String?, [WindowsMediaReport.Edition]) {
        let process = Process()
        process.executableURL = wimlib
        process.arguments = ["info", image.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil, []) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return (nil, nil, []) }
        return parseImageInfo(String(decoding: data, as: UTF8.self))
    }

    /// Parses the `Index:`/`Name:`/`Description:`/`Build:`/`Default Language:` fields of `wimlib-imagex info`.
    /// Fields of the first image provide the media's build and language; every image becomes an edition.
    static func parseImageInfo(_ text: String) -> (Int?, String?, [WindowsMediaReport.Edition]) {
        var editions: [WindowsMediaReport.Edition] = []
        var currentIndex: Int?
        var currentName: String?
        var currentDescription: String?
        var firstBuild: Int?
        var firstLanguage: String?
        func flush() {
            if let index = currentIndex, let name = currentName {
                editions.append(WindowsMediaReport.Edition(index: index, name: name, description: currentDescription))
            }
            currentIndex = nil
            currentName = nil
            currentDescription = nil
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Index", "Image Index":
                flush()
                currentIndex = Int(parts[1])
            case "Name":
                currentName = parts[1]
            case "Description":
                currentDescription = parts[1]
            case "Build":
                if firstBuild == nil { firstBuild = Int(parts[1]) }
            case "Default Language":
                if firstLanguage == nil { firstLanguage = parts[1] }
            default:
                break
            }
        }
        flush()
        return (firstBuild, firstLanguage, editions.sorted { $0.index < $1.index })
    }
}
