import Foundation

/// Volume-label handling, ported from `ToValidLabel()` (`src/format.c:263`) and the silent-install
/// suffix in `FormatDrive()` (`src/format.c:1793-1796`).
public enum VolumeLabel {
    /// Characters FAT/exFAT labels may not contain (`unauthorized[]` in upstream `format.c`).
    static let unauthorized = Set("*?,;:/\\|+=<>[]\"".map { $0 })
    /// FAT and exFAT labels are limited to 11 characters; NTFS allows 32.
    public static let fatMaxLength = 11
    public static let ntfsMaxLength = 32

    /// Upstream appends " (SILENT)" to the label of fully unattended installation media.
    public static let silentSuffix = " (SILENT)"

    /// Returns the label Rufus would use, or nil when nothing usable is left.
    ///
    /// Mirrors `ToValidLabel()`: FAT labels are uppercased, unauthorized characters are dropped,
    /// tabs and dots become underscores, and the result is truncated to `maxLength`.
    /// `appendSilent` corresponds to `append_silent` in `src/format.c:1794`.
    public static func sanitize(_ raw: String, appendSilent: Bool = false, maxLength: Int = fatMaxLength) -> String? {
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if appendSilent && !label.contains(silentSuffix) {
            label += silentSuffix
        }
        if label.isEmpty { return nil }
        var scalars: [Character] = []
        for character in label {
            if unauthorized.contains(character) { continue }
            if character == "\t" || character == "." {
                scalars.append("_")
                continue
            }
            scalars.append(Character(String(character).uppercased()))
        }
        if scalars.count > maxLength { scalars = Array(scalars.prefix(maxLength)) }
        let result = String(scalars)
        // A label made of punctuation only (e.g. "***") has nothing left after filtering.
        return result.contains(where: { $0.isLetter || $0.isNumber }) ? result : nil
    }
}
