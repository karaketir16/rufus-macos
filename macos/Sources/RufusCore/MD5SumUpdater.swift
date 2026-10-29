// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Updates the `md5sum.txt` / `MD5SUMS` list some distributions ship at the media root, so the checksums
/// stay valid after Rufus changes files (port of `UpdateMD5Sum()` in `src/hash.c:2472`).
///
/// The file format is expected to be one `<32 hex digits><whitespace><path>` entry per line; paths are
/// compared case-insensitively because the media is FAT/exFAT.
public enum MD5SumUpdater {
    public static let candidateNames = ["md5sum.txt", "md5sums", "md5sum.lst"]

    /// Rewrites the entries of every `path` in `modifiedPaths` that the checksum file lists.
    /// Returns the file names that were changed. Missing files and unreadable lists are ignored.
    @discardableResult
    public static func update(mediaRoot: URL, modifiedPaths: [String]) throws -> [String] {
        guard !modifiedPaths.isEmpty else { return [] }
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: mediaRoot, includingPropertiesForKeys: nil)
        var changed: [String] = []
        for file in entries where candidateNames.contains(file.lastPathComponent.lowercased()) {
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var touched = false
            var lines = text.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                guard let parsed = parse(line: line) else { continue }
                guard let modified = modifiedPaths.first(where: { $0.caseInsensitiveCompare(parsed.path) == .orderedSame }) else { continue }
                let target = mediaRoot.appendingPathComponent(modified)
                guard fm.fileExists(atPath: target.path),
                      let digest = try? Checksum.digest(file: target, algorithm: .md5) else { continue }
                guard line.count >= 32 else { continue }
                lines[lineIndex] = String(digest) + line.dropFirst(32)
                touched = true
            }
            if touched {
                text = lines.joined(separator: "\n")
                try Data(text.utf8).write(to: file, options: .atomic)
                changed.append(file.lastPathComponent)
            }
        }
        return changed
    }

    /// Splits `hash  ./path` (GNU), `hash *path` (binary marker) and `hash path`.
    static func parse(line: String) -> (digestLength: Int, path: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digest = trimmed.prefix(32)
        guard digest.count == 32, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        var rest = trimmed.dropFirst(32)
        guard rest.first?.isWhitespace == true else { return nil }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "*" { rest = rest.dropFirst() }
        if rest.hasPrefix("./") { rest = rest.dropFirst(2) }
        let path = String(rest).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return (32, path)
    }
}
