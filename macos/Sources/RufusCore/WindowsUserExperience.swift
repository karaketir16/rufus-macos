// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Port of the "Windows User Experience" selection logic of upstream Rufus (`src/rufus.c:1696-1766`).
///
/// Upstream shows this dialog after START for Windows 8+ images that are Windows 10/11 and have no existing
/// `sources/$OEM$/$$/Panther/unattend.xml`. Which choices are offered depends on the image's Windows build,
/// the selection is persisted for the session (and across runs, except for the options masked out of
/// `UNATTEND_DEFAULT_MASK`), and the chosen flags are converted into an `unattend.xml` by `CreateUnattendXml`.
public enum WindowsUserExperience {
    /// Same bit values as upstream `UNATTEND_*` flags (`src/rufus.h:686-698`) so persisted values are interchangeable.
    public enum Option: Int, CaseIterable {
        case secureBootTPMMinRAM = 0x001
        case noOnlineAccount = 0x004
        case noDataCollection = 0x008
        case duplicateLocale = 0x020
        case setUser = 0x040
        case disableBitlocker = 0x080
        case forceSMode = 0x100
        case useMS2023Bootloaders = 0x200
        case applySkuSiPolicy = 0x400
        case silentInstall = 0x800
        case qolEnhancements = 0x1000
    }

    public static let defaultSelectionMask = Option.secureBootTPMMinRAM.rawValue | Option.noOnlineAccount.rawValue
    /// Upstream `UNATTEND_DEFAULT_MASK` (0x16FF): options that are remembered between runs (S Mode and silent install are not).
    public static let persistedMask = 0x16FF
    public static let settingsKey = "WindowsUserExperienceOptions"

    /// Whether the dialog applies to this image (upstream: Windows 10/11, no Panther unattend.xml already on the image).
    public static func isApplicable(_ report: WindowsMediaReport) -> Bool {
        report.isWindows1X && !report.hasPantherUnattend
    }

    /// Options offered for the image, in upstream order (`src/rufus.c:1705-1751`).
    public static func availableOptions(for report: WindowsMediaReport, expertMode: Bool = false) -> [Option] {
        var options: [Option] = []
        let build = report.windowsBuild ?? 0
        if report.isWindows11 { options.append(.secureBootTPMMinRAM) }
        if build >= 22500 { options.append(.noOnlineAccount) }
        options.append(contentsOf: [.setUser, .duplicateLocale, .noDataCollection])
        if report.isWindows11 {
            options.append(contentsOf: [.silentInstall, .disableBitlocker, .qolEnhancements])
            if build >= 26200 { options.append(contentsOf: [.useMS2023Bootloaders, .applySkuSiPolicy]) }
        }
        if expertMode { options.append(.forceSMode) }
        return options
    }

    public struct Selection: Equatable {
        public var mask: Int
        public var username: String
        /// `wimlib-imagex` image index used by the silent-install answer file (`/IMAGE/INDEX`).
        /// Upstream picks the host's edition; on macOS the user picks from the image's edition list.
        public var editionIndex: Int

        public init(mask: Int = WindowsUserExperience.defaultSelectionMask, username: String = NSUserName(), editionIndex: Int = 1) {
            self.mask = mask
            self.username = username
            self.editionIndex = editionIndex
        }

        public func contains(_ option: Option) -> Bool { mask & option.rawValue != 0 }
        public mutating func set(_ option: Option, _ enabled: Bool) {
            if enabled { mask |= option.rawValue } else { mask &= ~option.rawValue }
            // Rufus' answer file generator refuses S Mode together with the online account bypass.
            if enabled && option == .forceSMode { mask &= ~Option.noOnlineAccount.rawValue }
            if enabled && option == .noOnlineAccount { mask &= ~Option.forceSMode.rawValue }
        }

        /// The edition actually written to the answer file: the chosen one when the image offers it,
        /// otherwise the image's first edition (or 1 when the list could not be read).
        public func resolvedEditionIndex(for report: WindowsMediaReport) -> Int {
            if report.installEditions.contains(where: { $0.index == editionIndex }) { return editionIndex }
            return report.installEditions.first?.index ?? 1
        }

        /// Restores persisted choices (upstream `SETTING_WUE_OPTIONS`, `(UNATTEND_DEFAULT_MASK << 16) | mask`).
        public static func restored(from defaults: UserDefaults = .standard) -> Selection {
            var selection = Selection()
            let stored = defaults.integer(forKey: settingsKey)
            if (stored >> 16) != 0 {
                let persisted = stored >> 16
                selection.mask = (selection.mask & ~persisted) | (stored & persisted)
            }
            return selection
        }

        public func persist(to defaults: UserDefaults = .standard) {
            defaults.set((persistedMask << 16) | (mask & persistedMask), forKey: settingsKey)
        }
    }

    /// Keeps only options that are offered for the image (upstream `remap16(i, map, TRUE)`) and builds the answer file.
    public static func makeAnswerFile(selection: Selection, report: WindowsMediaReport, regional: WindowsAnswerFile.RegionalOptions? = nil) throws -> String {
        let offered = Set(availableOptions(for: report, expertMode: true))
        func on(_ option: Option) -> Bool { offered.contains(option) && selection.contains(option) }
        let architecture: WindowsAnswerFile.Architecture
        if report.architectures.contains(.amd64) { architecture = .amd64 }
        else if report.architectures.contains(.arm64) { architecture = .arm64 }
        else if report.architectures.contains(.x86) { architecture = .x86 }
        else { architecture = .amd64 }
        let username = selection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return try WindowsAnswerFile.make(
            architecture: architecture,
            bypassHardware: on(.secureBootTPMMinRAM),
            bypassOnlineAccount: on(.noOnlineAccount),
            disablePrivacyPrompts: on(.noDataCollection),
            qualityOfLife: on(.qolEnhancements),
            // Upstream only creates the account when a name is provided.
            localAccount: (on(.setUser) && !username.isEmpty) ? username : nil,
            disableDeviceEncryption: on(.disableBitlocker),
            forceSMode: on(.forceSMode),
            applySkuSiPolicy: on(.applySkuSiPolicy),
            silentInstall: on(.silentInstall) ? .init(editionIndex: selection.resolvedEditionIndex(for: report), uiLanguage: report.defaultLanguage ?? "en-US") : nil,
            regionalOptions: on(.duplicateLocale) ? regional : nil
        )
    }

    public static func usesMS2023Bootloaders(selection: Selection, report: WindowsMediaReport) -> Bool {
        availableOptions(for: report, expertMode: true).contains(.useMS2023Bootloaders) && selection.contains(.useMS2023Bootloaders)
    }

    /// Upstream `UNATTEND_DUPLICATE_LOCALE` copies the running system's time zone and locales.
    /// Returns nil when the host's locale cannot be represented (the option is then ignored, as upstream does on failure).
    public static func hostRegionalOptions(locale: Locale = .current, timeZone: TimeZone = .current) -> WindowsAnswerFile.RegionalOptions? {
        guard let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier else { return nil }
        let tag = "\(language)-\(region)"
        let ui = Locale.preferredLanguages.first.map { $0.split(separator: "-").prefix(2).joined(separator: "-") } ?? tag
        let uiTag = ui.contains("-") ? ui : "\(ui)-\(region)"
        return WindowsAnswerFile.RegionalOptions(
            timeZone: windowsTimeZoneNames[timeZone.identifier],
            inputLocale: tag,
            systemLocale: tag,
            userLocale: tag,
            uiLanguage: uiTag,
            uiLanguageFallback: uiTag
        )
    }

    /// IANA → Windows time zone key names (CLDR `windowsZones.xml`, primary territory) for common zones.
    /// Unlisted zones are skipped: the answer file then simply omits `<TimeZone>`.
    static let windowsTimeZoneNames: [String: String] = [
        "Europe/Istanbul": "Turkey Standard Time", "Europe/London": "GMT Standard Time", "Europe/Dublin": "GMT Standard Time",
        "Europe/Lisbon": "GMT Standard Time", "Europe/Paris": "Romance Standard Time", "Europe/Madrid": "Romance Standard Time",
        "Europe/Brussels": "Romance Standard Time", "Europe/Copenhagen": "Romance Standard Time", "Europe/Berlin": "W. Europe Standard Time",
        "Europe/Amsterdam": "W. Europe Standard Time", "Europe/Rome": "W. Europe Standard Time", "Europe/Vienna": "W. Europe Standard Time",
        "Europe/Zurich": "W. Europe Standard Time", "Europe/Stockholm": "W. Europe Standard Time", "Europe/Oslo": "W. Europe Standard Time",
        "Europe/Prague": "Central Europe Standard Time", "Europe/Budapest": "Central Europe Standard Time", "Europe/Warsaw": "Central European Standard Time",
        "Europe/Athens": "GTB Standard Time", "Europe/Bucharest": "GTB Standard Time", "Europe/Helsinki": "FLE Standard Time",
        "Europe/Kiev": "FLE Standard Time", "Europe/Kyiv": "FLE Standard Time", "Europe/Sofia": "FLE Standard Time",
        "Europe/Moscow": "Russian Standard Time", "Europe/Minsk": "Belarus Standard Time",
        "Asia/Dubai": "Arabian Standard Time", "Asia/Riyadh": "Arab Standard Time", "Asia/Baghdad": "Arabic Standard Time",
        "Asia/Tehran": "Iran Standard Time", "Asia/Jerusalem": "Israel Standard Time", "Asia/Karachi": "Pakistan Standard Time",
        "Asia/Kolkata": "India Standard Time", "Asia/Dhaka": "Bangladesh Standard Time", "Asia/Bangkok": "SE Asia Standard Time",
        "Asia/Jakarta": "SE Asia Standard Time", "Asia/Shanghai": "China Standard Time", "Asia/Hong_Kong": "China Standard Time",
        "Asia/Singapore": "Singapore Standard Time", "Asia/Taipei": "Taipei Standard Time", "Asia/Seoul": "Korea Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time", "Australia/Sydney": "AUS Eastern Standard Time", "Australia/Melbourne": "AUS Eastern Standard Time",
        "Australia/Brisbane": "E. Australia Standard Time", "Australia/Perth": "W. Australia Standard Time", "Australia/Adelaide": "Cen. Australia Standard Time",
        "Pacific/Auckland": "New Zealand Standard Time", "Africa/Cairo": "Egypt Standard Time", "Africa/Johannesburg": "South Africa Standard Time",
        "Africa/Lagos": "W. Central Africa Standard Time", "Africa/Nairobi": "E. Africa Standard Time", "Africa/Casablanca": "Morocco Standard Time",
        "America/New_York": "Eastern Standard Time", "America/Toronto": "Eastern Standard Time", "America/Chicago": "Central Standard Time",
        "America/Denver": "Mountain Standard Time", "America/Phoenix": "US Mountain Standard Time", "America/Los_Angeles": "Pacific Standard Time",
        "America/Vancouver": "Pacific Standard Time", "America/Anchorage": "Alaskan Standard Time", "Pacific/Honolulu": "Hawaiian Standard Time",
        "America/Halifax": "Atlantic Standard Time", "America/Mexico_City": "Central Standard Time (Mexico)", "America/Bogota": "SA Pacific Standard Time",
        "America/Lima": "SA Pacific Standard Time", "America/Sao_Paulo": "E. South America Standard Time", "America/Argentina/Buenos_Aires": "Argentina Standard Time",
        "America/Santiago": "Pacific SA Standard Time", "America/Caracas": "Venezuela Standard Time", "UTC": "UTC", "GMT": "UTC"
    ]
}
