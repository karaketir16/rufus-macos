import Foundation

/// Resolves bundled helper tools (`wimlib-imagex`) and boot images (`uefi-ntfs.img`)
/// from the application bundle (`Contents/Resources`) or a local development build.
public enum BundledTools {
    public static func locateWimlib(from baseDirectory: URL? = nil) -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("wimlib-imagex"))
        }
        let cwd = baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".deps/wimlib-1.14.5/bin/wimlib-imagex"))
        candidates.append(cwd.appendingPathComponent("macos/.deps/wimlib-1.14.5/bin/wimlib-imagex"))
        return candidates.first(where: isSafeExecutable)
    }

    /// Bundled `xz` (`Contents/Resources/xz`) used to decompress `.xz`/`.lzma` images. macOS ships no xz.
    public static func locateXZ(from baseDirectory: URL? = nil) -> URL? {
        locateCompressor("xz", from: baseDirectory)
    }

    /// Bundled `zstd` (`Contents/Resources/zstd`) used to decompress `.zst` images. macOS ships no zstd.
    public static func locateZstd(from baseDirectory: URL? = nil) -> URL? {
        locateCompressor("zstd", from: baseDirectory)
    }

    private static func locateCompressor(_ name: String, from baseDirectory: URL?) -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(name))
        }
        let cwd = baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".deps/compressors/\(name)"))
        candidates.append(cwd.appendingPathComponent("macos/.deps/compressors/\(name)"))
        return candidates.first(where: isSafeExecutable)
    }

    public static func locateUefiNtfsImage(from baseDirectory: URL? = nil) -> URL? {        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("uefi-ntfs.img"))
        }
        let cwd = baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("../res/uefi/uefi-ntfs.img"))
        candidates.append(cwd.appendingPathComponent("res/uefi/uefi-ntfs.img"))
        return candidates.first(where: isSafeRegularFile)
    }

    /// Rufus' `setup.exe` bypass wrapper (`res/setup/setup_x64.exe` / `setup_arm64.exe`) for the given PE machine type.
    public static func locateSetupWrapper(machine: UInt16?, from baseDirectory: URL? = nil) -> URL? {
        let name: String
        switch machine {
        case 0x8664: name = "setup_x64.exe"
        case 0xAA64: name = "setup_arm64.exe"
        default: return nil
        }
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(name))
        }
        let cwd = baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("../res/setup/\(name)"))
        candidates.append(cwd.appendingPathComponent("res/setup/\(name)"))
        return candidates.first(where: isSafeRegularFile)
    }

    private static func isSafeExecutable(_ url: URL) -> Bool {
        guard isSafeRegularFile(url) else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return false
        }
        return true
    }
}
