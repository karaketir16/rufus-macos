import Foundation
import Darwin

/// Compressed disk images, as upstream Rufus accepts them (`src/rufus.c:2629` lists
/// `*.bz2 *.bzip2 *.gz *.lzma *.xz *.Z *.zip *.zst`).
///
/// Rufus never opens these as file systems: a compressed image is always written in DD mode,
/// because its bytes have to be decompressed before they can reach the device. This type only
/// answers three questions — which format is this, which program decompresses it, and how big is
/// the result — so `RawDiskWriter` can stream it.
public enum CompressedImage {
    public enum Format: String, CaseIterable {
        case gzip
        case bzip2
        case xz
        case lzma
        case zstd
        case compress
        case zip

        /// Extensions Rufus recognises, mapped to this format.
        public static func detect(_ url: URL) -> Format? {
            switch url.pathExtension.lowercased() {
            case "gz", "gzip": return .gzip
            case "bz2", "bzip2": return .bzip2
            case "xz": return .xz
            case "lzma": return .lzma
            case "zst", "zstd": return .zstd
            case "z": return .compress
            case "zip": return .zip
            default: return nil
            }
        }

        public var displayName: String {
            switch self {
            case .gzip: return "gzip"
            case .bzip2: return "bzip2"
            case .xz: return "xz"
            case .lzma: return "lzma"
            case .zstd: return "zstd"
            case .compress: return "compress (.Z)"
            case .zip: return "zip"
            }
        }
    }

    public enum DecompressError: Error, Equatable {
        case unsupported
        case toolMissing(String)
        case archiveHasMultipleFiles([String])
        case launchFailed
        case decompressionFailed(Int32)
        /// The decompressor produced more bytes than the target disk can hold.
        case largerThanDisk
        /// The stream ended before the decompressor reported success (truncated or corrupt).
        case truncatedStream
    }

    /// A decompressor invocation: run `executable` with `arguments`, read the image from stdout.
    public struct Command {
        public let executable: URL
        public let arguments: [String]
        /// Uncompressed size is not estimated for any supported format; the writer streams blindly
        /// and enforces the disk capacity while reading decompressed blocks.
        public let estimatedSize: UInt64?
    }

    /// Builds the decompressor invocation for a compressed image.
    ///
    /// macOS has `gzip` (which also handles `.Z`), `bzip2` and `bsdtar`, but no xz or zstd, so those
    /// two come from the application bundle (see `scripts/build-compressors.sh`).
    public static func command(for url: URL, fileManager: FileManager = .default) throws -> Command {
        guard let format = Format.detect(url) else { throw DecompressError.unsupported }
        guard fileManager.isReadableFile(atPath: url.path) else { throw DecompressError.launchFailed }

        func system(_ path: String) throws -> URL {
            guard fileManager.isExecutableFile(atPath: path) else { throw DecompressError.toolMissing(path) }
            return URL(fileURLWithPath: path)
        }

        let executable: URL
        var arguments: [String]
        switch format {
        case .gzip, .compress:
            executable = try system("/usr/bin/gzip")
            arguments = ["-dc", url.path]
        case .bzip2:
            executable = try system("/usr/bin/bzip2")
            arguments = ["-dc", url.path]
        case .xz:
            guard let tool = BundledTools.locateXZ() else { throw DecompressError.toolMissing("xz") }
            executable = tool
            arguments = ["-dc", url.path]
        case .lzma:
            guard let tool = BundledTools.locateXZ() else { throw DecompressError.toolMissing("xz") }
            executable = tool
            arguments = ["-dc", "--format=lzma", url.path]
        case .zstd:
            guard let tool = BundledTools.locateZstd() else { throw DecompressError.toolMissing("zstd") }
            executable = tool
            arguments = ["-dc", "--quiet", url.path]
        case .zip:
            // A zip can hold several files; Rufus only writes single-image archives.
            executable = try system("/usr/bin/bsdtar")
            let members = try listZipMembers(executable: executable, url: url)
            guard members.count == 1, let member = members.first, !member.hasSuffix("/") else {
                throw DecompressError.archiveHasMultipleFiles(members)
            }
            arguments = ["-xOf", url.path, member]
        }

        return Command(executable: executable, arguments: arguments, estimatedSize: nil)
    }

    /// Lists the members of a zip archive with `bsdtar -tf` (read-only).
    static func listZipMembers(executable: URL, url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-tf", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { throw DecompressError.launchFailed }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DecompressError.decompressionFailed(process.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

