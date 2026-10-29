import Foundation
import Darwin

/// Experimental directory staging only. Not a USB writer or an authorization boundary.
public enum WindowsMediaStager {
    public enum StagingError: Error {
        case invalidDestination, destinationNotEmpty, overlappingDirectories
        case unsupportedLargeFiles([String]), incompleteSource, answerFileConflict, splitOutputTooLarge
    }

    public static func stageISO(image: URL, destination: URL, answerFile: String?, wimlib: URL? = nil, maximumFileBytes: UInt64 = 4_294_967_295, allowVolumeMetadata: Bool = false, useMS2023Bootloaders: Bool = false) throws {
        try WindowsMediaInspector.withMountedISO(image) { mounted in
            try stage(source: mounted, destination: destination, answerFile: answerFile, wimlib: wimlib, maximumFileBytes: maximumFileBytes, allowVolumeMetadata: allowVolumeMetadata, useMS2023Bootloaders: useMS2023Bootloaders)
        }
    }

    public static func stage(source: URL, destination: URL, answerFile: String?, wimlib: URL? = nil, maximumFileBytes: UInt64 = 4_294_967_295, partSizeMiB: Int = 3800, allowVolumeMetadata: Bool = false, useMS2023Bootloaders: Bool = false) throws {
        let fm = FileManager.default
        let dstValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard dstValues.isDirectory == true, dstValues.isSymbolicLink != true else { throw StagingError.invalidDestination }
        guard let srcPath = realpath(source.path, nil) else { throw StagingError.incompleteSource }
        defer { free(srcPath) }
        guard let dstPath = realpath(destination.path, nil) else { throw StagingError.invalidDestination }
        defer { free(dstPath) }
        let src = String(cString: srcPath), dst = String(cString: dstPath)
        guard src != dst, !dst.hasPrefix(src + "/"), !src.hasPrefix(dst + "/") else { throw StagingError.overlappingDirectories }
        let systemMetadata: Set<String> = [".fseventsd", ".spotlight-v100", ".trashes", ".temporaryitems"]
        let existingEntries = try fm.contentsOfDirectory(atPath: dst)
        if allowVolumeMetadata {
            guard existingEntries.allSatisfy({ systemMetadata.contains($0.lowercased()) }) else {
                throw StagingError.destinationNotEmpty
            }
        } else {
            guard existingEntries.isEmpty else { throw StagingError.destinationNotEmpty }
        }
        let report = try WindowsMediaInspector.inspect(root: source, maximumFileBytes: maximumFileBytes)
        guard report.hasBootImage, let installImage = report.installImage else { throw StagingError.incompleteSource }
        let needsSplit = report.oversizedFiles.contains(installImage)
        guard report.oversizedFiles.allSatisfy({ $0 == installImage }), !needsSplit || (installImage.lowercased() == "sources/install.wim" && wimlib != nil) else { throw StagingError.unsupportedLargeFiles(report.oversizedFiles) }
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        if answerFile != nil {
            if entries.contains(where: { $0.lastPathComponent.lowercased() == "autounattend.xml" }) ||
               fm.fileExists(atPath: source.appendingPathComponent("sources/$OEM$/$$/Panther/unattend.xml").path) {
                throw StagingError.answerFileConflict
            }
        }
        var splitDir: URL?
        defer { if let splitDir { try? fm.removeItem(at: splitDir) } }
        if needsSplit, let wimlib {
            let temp = fm.temporaryDirectory.appendingPathComponent("RufusSplit-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: false)
            splitDir = temp
            try WIMSplitter.split(input: source.appendingPathComponent(installImage), destination: temp, tool: wimlib, partSizeMiB: partSizeMiB)
            for file in try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.fileSizeKey]) {
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0, UInt64(size) <= maximumFileBytes else { throw StagingError.splitOutputTooLarge }
            }
        }
        for entry in entries {
            if needsSplit && entry.lastPathComponent.lowercased() == "sources" {
                let target = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                for child in try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) where child.lastPathComponent.lowercased() != "install.wim" {
                    try fm.copyItem(at: child, to: target.appendingPathComponent(child.lastPathComponent))
                }
                if let splitDir {
                    for part in try fm.contentsOfDirectory(at: splitDir, includingPropertiesForKeys: nil) { try fm.copyItem(at: part, to: target.appendingPathComponent(part.lastPathComponent)) }
                }
            } else {
                try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
        }
        if let answerFile {
            let applied = try WindowsCustomization.apply(mediaRoot: destination, answerFile: answerFile, windowsBuild: report.windowsBuild, wimlib: wimlib ?? BundledTools.locateWimlib(), useMS2023Bootloaders: useMS2023Bootloaders)
            // Keep an existing md5sum.txt/MD5SUMS list valid for the files we just changed (src/hash.c:2472).
            _ = try MD5SumUpdater.update(mediaRoot: destination, modifiedPaths: applied.modifiedPaths)
        }
    }
}
