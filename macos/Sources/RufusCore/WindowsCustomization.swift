// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Port of upstream `ApplyWindowsCustomization()` (`src/wue.c`) for the non-Windows-To-Go case.
///
/// Upstream does not simply drop `autounattend.xml` at the media root. After the files are copied it:
/// 1. (when the answer file has a `windowsPE` pass: TPM/SB/RAM bypass or silent install)
///    renames `sources\appraiserres.dll` to `appraiserres.bak` and creates an empty placeholder
///    (so in-place upgrades also skip the compatibility appraisal),
/// 2. (same condition, build >= 26000) renames `setup.exe` to `setup.dll` and installs Rufus' bypass wrapper,
/// 3. (same condition) adds the answer file as `\Autounattend.xml` to the root of `boot.wim` image 2
///    (image 1 for unofficial ISOs), because Windows Setup then carries it into `%WINDIR%\Panther\unattend.xml`,
/// 4. otherwise copies it to `sources\$OEM$\$$\Panther\unattend.xml` on the media.
///
/// Not ported: the offline editing of `boot.wim`'s SYSTEM registry hive (it needs a Windows registry API;
/// upstream itself falls back to the `windowsPE` pass of the answer file when it fails, which is what we always do).
public enum WindowsCustomization {
    public enum CustomizationError: Error {
        case wimlibRequired
        case bootWimMissing
        case commandFailed(String)
        case cannotCreateDirectory(URL)
    }

    /// True when the answer file contains a `windowsPE` pass (upstream `UNATTEND_WINPE_SETUP_MASK`).
    public static func needsWindowsPEPass(_ answerFile: String) -> Bool {
        answerFile.contains("pass=\"windowsPE\"")
    }

    /// Applies the customization to a freshly staged media root.
    /// `log` holds human-readable lines; `modifiedPaths` lists the media-root-relative files that changed,
    /// so `md5sum.txt` can be refreshed for them.
    public struct ApplyResult {
        public var log: [String]
        public var modifiedPaths: [String]
    }

    public static func apply(mediaRoot: URL, answerFile: String, windowsBuild: Int?, wimlib: URL?, useMS2023Bootloaders: Bool = false) throws -> ApplyResult {
        let fm = FileManager.default
        var log: [String] = []
        var modified: [String] = []
        let sources = try childDirectory(named: "sources", in: mediaRoot)

        if needsWindowsPEPass(answerFile) {
            // 1. appraiserres.dll placeholder
            if let sources {
                let appraiser = try child(named: "appraiserres.dll", in: sources) ?? sources.appendingPathComponent("appraiserres.dll")
                let backup = sources.appendingPathComponent("appraiserres.bak")
                if fm.fileExists(atPath: appraiser.path) {
                    if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                    try fm.moveItem(at: appraiser, to: backup)
                    log.append("Renamed 'sources/appraiserres.dll' → 'appraiserres.bak'")
                }
                guard fm.createFile(atPath: appraiser.path, contents: Data()) else {
                    throw CustomizationError.commandFailed("Could not create appraiserres.dll placeholder")
                }
                modified.append("sources/appraiserres.dll")
                log.append("Created 'sources/appraiserres.dll' placeholder")
            }

            // 2. setup.exe wrapper for Windows 11 24H2+ in-place upgrades
            if (windowsBuild ?? 0) >= 26000, let setupExe = try child(named: "setup.exe", in: mediaRoot) {
                let arch = peMachine(of: setupExe)
                if let wrapper = BundledTools.locateSetupWrapper(machine: arch) {
                    let setupDll = mediaRoot.appendingPathComponent("setup.dll")
                    if fm.fileExists(atPath: setupDll.path) { try fm.removeItem(at: setupDll) }
                    try fm.moveItem(at: setupExe, to: setupDll)
                    try fm.copyItem(at: wrapper, to: mediaRoot.appendingPathComponent("setup.exe"))
                    modified.append(contentsOf: ["setup.exe", "setup.dll"])
                    log.append("Renamed 'setup.exe' → 'setup.dll' and created bypass wrapper")
                } else {
                    log.append("WARNING: Unsupported or unavailable setup.exe wrapper (machine 0x\(String(arch ?? 0, radix: 16))) - in-place upgrade wrapper not added")
                }
            }

            // 3. Autounattend.xml at the root of boot.wim
            guard let sources, let bootWim = try child(named: "boot.wim", in: sources) else { throw CustomizationError.bootWimMissing }
            guard let wimlib else { throw CustomizationError.wimlibRequired }
            let imageCount = try wimImageCount(wimlib: wimlib, wim: bootWim)
            let index = imageCount >= 2 ? 2 : 1
            if index == 1 { log.append("WARNING: boot.wim has no image 2 (unofficial ISO?) - using image 1") }
            let temp = fm.temporaryDirectory.appendingPathComponent("RufusWUE-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: temp) }
            let xmlFile = temp.appendingPathComponent("Autounattend.xml")
            try Data(answerFile.utf8).write(to: xmlFile, options: .withoutOverwriting)
            try runWimlib(wimlib, ["update", bootWim.path, String(index), "--unsafe-compact"], stdin: "add \"\(xmlFile.path)\" \"/Autounattend.xml\"\n")
            modified.append("sources/boot.wim")
            log.append("Added 'Autounattend.xml' to 'boot.wim' image \(index)")
        }
        if useMS2023Bootloaders {
            let replaced = try replaceWithMS2023Bootloaders(mediaRoot: mediaRoot, sources: sources, wimlib: wimlib)
            log += replaced.log
            modified += replaced.modifiedPaths
        }
        if !needsWindowsPEPass(answerFile) {
            // 4. \sources\$OEM$\$$\Panther\unattend.xml
            let sourcesDir = try sources ?? {
                let created = mediaRoot.appendingPathComponent("sources", isDirectory: true)
                try fm.createDirectory(at: created, withIntermediateDirectories: false)
                return created
            }()
            let panther = sourcesDir.appendingPathComponent("$OEM$/$$/Panther", isDirectory: true)
            try fm.createDirectory(at: panther, withIntermediateDirectories: true)
            try Data(answerFile.utf8).write(to: panther.appendingPathComponent("unattend.xml"), options: .withoutOverwriting)
            modified.append("sources/$OEM$/$$/Panther/unattend.xml")
            log.append("Created 'sources/$OEM$/$$/Panther/unattend.xml'")
        }
        return ApplyResult(log: log, modifiedPaths: modified)
    }

    /// Upstream `UNATTEND_USE_MS2023_BOOTLOADERS`: extracts `Windows\Boot\EFI_EX` and `Windows\Boot\Fonts_EX` from
    /// the Windows Setup image of `boot.wim` and replaces the media's bootloaders, fonts and `bootmgr.efi` with the
    /// 'Windows UEFI CA 2023' signed versions (`src/wue.c:1355-1444`).
    private static func replaceWithMS2023Bootloaders(mediaRoot: URL, sources: URL?, wimlib: URL?) throws -> (log: [String], modifiedPaths: [String]) {
        let fm = FileManager.default
        guard let sources, let bootWim = try child(named: "boot.wim", in: sources) else { throw CustomizationError.bootWimMissing }
        guard let wimlib else { throw CustomizationError.wimlibRequired }
        let index = try wimImageCount(wimlib: wimlib, wim: bootWim) >= 2 ? "2" : "1"
        let temp = fm.temporaryDirectory.appendingPathComponent("RufusEX-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        do {
            try runWimlib(wimlib, ["extract", bootWim.path, index, "/Windows/Boot/EFI_EX", "/Windows/Boot/Fonts_EX", "--dest-dir=\(temp.path)", "--no-acls"])
        } catch {
            return (["WARNING: Could not extract 2023 signed UEFI bootloaders - Ignoring option"], [])
        }
        var replaced = 0
        var log: [String] = []
        var modified: [String] = []
        let efiBoot = try ensureDirectory(mediaRoot, ["efi", "microsoft", "boot"])
        // Copy/override the font files (dropping every "_EX" from the name, as upstream does).
        if let fonts = try child(named: "Fonts_EX", in: temp) {
            for sub in try fm.subpathsOfDirectory(atPath: fonts.path) {
                let file = fonts.appendingPathComponent(sub)
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = ("Fonts_EX/" + sub).replacingOccurrences(of: "_EX", with: "")
                let target = efiBoot.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: file, to: target)
                modified.append("efi/microsoft/boot/" + relative)
                replaced += 1
            }
        }
        // Replace /EFI/Boot/boot###.efi (first architecture present, same order as upstream's efi_archname[1...]).
        if let efiEx = try child(named: "EFI_EX", in: temp), let bootmgfw = try child(named: "bootmgfw_EX.efi", in: efiEx),
           let efiDir = try child(named: "efi", in: mediaRoot), let bootDir = try child(named: "boot", in: efiDir) {
            for arch in ["ia32", "x64", "arm", "aa64", "ia64", "riscv64", "loongarch64", "ebc"] {
                guard let existing = try child(named: "boot\(arch).efi", in: bootDir) else { continue }
                try fm.removeItem(at: existing)
                try fm.copyItem(at: bootmgfw, to: existing)
                modified.append("efi/boot/boot\(arch).efi")
                replaced += 1
                break
            }
            // Replace /bootmgr.efi (26H2 has no bootmgr_EX.efi).
            if let bootmgr = try child(named: "bootmgr_EX.efi", in: efiEx) {
                let target = mediaRoot.appendingPathComponent("bootmgr.efi")
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: bootmgr, to: target)
                modified.append("bootmgr.efi")
                replaced += 1
            }
        }
        if replaced != 0 {
            log.append("Replaced \(replaced) EFI bootloader/font files with 'Windows UEFI CA 2023' compatible versions.")
            log.append("To boot this media the target must have the 'Windows UEFI CA 2023' Secure Boot certificate installed.")
        }
        return (log, modified)
    }

    private static func ensureDirectory(_ root: URL, _ components: [String]) throws -> URL {
        var current = root
        for name in components {
            if let existing = try child(named: name, in: current) { current = existing } else {
                current = current.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        return current
    }

    // MARK: helpers

    private static func child(named name: String, in directory: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.lowercased() == name.lowercased() }
    }

    private static func childDirectory(named name: String, in directory: URL) throws -> URL? {
        try child(named: name, in: directory)
    }

    /// Reads `IMAGE_FILE_HEADER.Machine` of a PE file (0x8664 amd64, 0xAA64 arm64).
    static func peMachine(of file: URL) -> UInt16? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), head.count == 64, head[0] == 0x4D, head[1] == 0x5A else { return nil }
        let offset = UInt64(head[60]) | UInt64(head[61]) << 8 | UInt64(head[62]) << 16 | UInt64(head[63]) << 24
        guard (try? handle.seek(toOffset: offset)) != nil, let pe = try? handle.read(upToCount: 6), pe.count == 6,
              pe[0] == 0x50, pe[1] == 0x45, pe[2] == 0, pe[3] == 0 else { return nil }
        return UInt16(pe[4]) | UInt16(pe[5]) << 8
    }

    private static func wimImageCount(wimlib: URL, wim: URL) throws -> Int {
        let output = try runWimlib(wimlib, ["info", wim.path, "--header"])
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "Image Count", let n = Int(parts[1]) { return n }
        }
        throw CustomizationError.commandFailed("Could not read boot.wim image count")
    }

    @discardableResult
    private static func runWimlib(_ tool: URL, _ arguments: [String], stdin: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CustomizationError.commandFailed("wimlib-imagex \(arguments.first ?? ""): \(text)")
        }
        return text
    }
}
