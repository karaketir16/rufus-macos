// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Full XML answer-file generator matching `CreateUnattendXml` in upstream `src/wue.c`.
public enum WindowsAnswerFile {
    public enum Architecture: String { case x86, amd64, arm, arm64 }
    public enum AnswerError: Error {
        case invalidLocalAccount
        case conflictingOptions
        case invalidSilentInstallConfiguration
        case invalidRegionalConfiguration
    }

    public struct SilentInstall: Equatable {
        public let editionIndex: Int
        public let uiLanguage: String

        public init(editionIndex: Int = 1, uiLanguage: String = "en-US") {
            self.editionIndex = editionIndex
            self.uiLanguage = uiLanguage
        }
    }

    public struct RegionalOptions: Equatable {
        public let timeZone: String?
        public let inputLocale: String
        public let systemLocale: String
        public let userLocale: String
        public let uiLanguage: String
        public let uiLanguageFallback: String

        public init(
            timeZone: String? = nil,
            inputLocale: String,
            systemLocale: String,
            userLocale: String,
            uiLanguage: String,
            uiLanguageFallback: String
        ) {
            self.timeZone = timeZone
            self.inputLocale = inputLocale
            self.systemLocale = systemLocale
            self.userLocale = userLocale
            self.uiLanguage = uiLanguage
            self.uiLanguageFallback = uiLanguageFallback
        }
    }

    public static func make(
        architecture: Architecture,
        bypassHardware: Bool,
        bypassOnlineAccount: Bool,
        disablePrivacyPrompts: Bool,
        removeBundledApps: Bool = false,
        qualityOfLife: Bool = false,
        localAccount: String? = nil,
        disableDeviceEncryption: Bool = false,
        offlineInternalDrives: Bool = false,
        forceSMode: Bool = false,
        applySkuSiPolicy: Bool = false,
        silentInstall: SilentInstall? = nil,
        regionalOptions: RegionalOptions? = nil
    ) throws -> String {
        if bypassOnlineAccount && forceSMode {
            throw AnswerError.conflictingOptions
        }
        let username = try localAccount.map(validateUsername)
        if let silent = silentInstall {
            guard silent.editionIndex >= 1, isValidLocaleTag(silent.uiLanguage) else {
                throw AnswerError.invalidSilentInstallConfiguration
            }
        }
        if let regional = regionalOptions {
            guard isValidLocaleOrKeyboard(regional.inputLocale),
                  isValidLocaleTag(regional.systemLocale),
                  isValidLocaleTag(regional.userLocale),
                  isValidLocaleTag(regional.uiLanguage),
                  isValidLocaleTag(regional.uiLanguageFallback),
                  regional.timeZone.map(isValidTimeZone) ?? true else {
                throw AnswerError.invalidRegionalConfiguration
            }
        }

        let attributes = "processorArchitecture=\"\(architecture.rawValue)\" language=\"neutral\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" publicKeyToken=\"31bf3856ad364e35\" versionScope=\"nonSxS\""
        var sections: [String] = []

        if bypassHardware || silentInstall != nil {
            var setupBody = "<UserData><AcceptEula>true</AcceptEula><ProductKey><Key /></ProductKey></UserData>"
            if let silent = silentInstall {
                let bitlockerProvisioning = disableDeviceEncryption ? "<DisableEncryptedDiskProvisioning>true</DisableEncryptedDiskProvisioning>" : ""
                setupBody +=
                    "<DiskConfiguration>" +
                    "<WillShowUI>OnError</WillShowUI>" +
                    bitlockerProvisioning +
                    "<Disk wcm:action=\"modify\"><DiskID>1</DiskID><ModifyPartitions><ModifyPartition wcm:action=\"modify\"><Order>1</Order><PartitionID>2</PartitionID><Label>RUFUS_BOOT</Label></ModifyPartition></ModifyPartitions></Disk>" +
                    "<Disk wcm:action=\"add\"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>" +
                    "<CreatePartitions>" +
                    "<CreatePartition wcm:action=\"add\"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>" +
                    "<CreatePartition wcm:action=\"add\"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>" +
                    "<CreatePartition wcm:action=\"add\"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>" +
                    "</CreatePartitions>" +
                    "<ModifyPartitions>" +
                    "<ModifyPartition wcm:action=\"add\"><Order>1</Order><PartitionID>1</PartitionID><Label>EFI</Label><Format>FAT32</Format></ModifyPartition>" +
                    "<ModifyPartition wcm:action=\"add\"><Order>2</Order><PartitionID>3</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format></ModifyPartition>" +
                    "</ModifyPartitions>" +
                    "</Disk>" +
                    "</DiskConfiguration>" +
                    "<ImageInstall><OSImage><WillShowUI>OnError</WillShowUI>" +
                    "<InstallFrom><MetaData wcm:action=\"add\"><Key>/IMAGE/INDEX</Key><Value>\(silent.editionIndex)</Value></MetaData></InstallFrom>" +
                    "<InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>" +
                    "</OSImage></ImageInstall>"
            }
            if bypassHardware {
                let keys = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"]
                let commands = keys.enumerated().map { index, key in
                    "<RunSynchronousCommand wcm:action=\"add\"><Order>\(index + 1)</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(key) /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"
                }.joined()
                setupBody += "<RunSynchronous>\(commands)</RunSynchronous>"
            }
            var winPEComponents = "<component name=\"Microsoft-Windows-Setup\" \(attributes)>\(setupBody)</component>"
            if let silent = silentInstall {
                winPEComponents += "<component name=\"Microsoft-Windows-International-Core-WinPE\" \(attributes)><UILanguage>\(silent.uiLanguage)</UILanguage></component>"
            }
            sections.append("<settings pass=\"windowsPE\">\(winPEComponents)</settings>")
        }

        var specializeCommands: [String] = []
        if bypassOnlineAccount {
            specializeCommands.append(#"reg add "HKLM\Software\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f"#)
        }
        if removeBundledApps || qualityOfLife {
            specializeCommands.append(#"reg add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f"#)
            specializeCommands.append(#"PowerShell -NonInteractive -WindowStyle Hidden -Command "Remove-Item -Path $env:SystemRoot\System32\OneDriveSetup.exe -Force -Confirm:$false; Remove-Item -Path $env:SystemRoot\SysWOW64\OneDriveSetup.exe -Force -Confirm:$false;""#)
            for name in ["Outlook", "Teams"] {
                specializeCommands.append("PowerShell -NonInteractive -WindowStyle Hidden -Command \"Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like '*\(name)*'} | Remove-AppxProvisionedPackage -Online\"")
                specializeCommands.append("PowerShell -NonInteractive -WindowStyle Hidden -Command \"Get-AppxPackage -AllUsers *\(name)* | Remove-AppxPackage -AllUsers\"")
            }
        }
        if !specializeCommands.isEmpty {
            let commands = specializeCommands.enumerated().map { index, command in
                let escaped = escapeXMLText(command)
                return "<RunSynchronousCommand wcm:action=\"add\"><Order>\(index + 1)</Order><Path>\(escaped)</Path></RunSynchronousCommand>"
            }.joined()
            sections.append("<settings pass=\"specialize\"><component name=\"Microsoft-Windows-Deployment\" \(attributes)><RunSynchronous>\(commands)</RunSynchronous></component></settings>")
        }

        if disablePrivacyPrompts || qualityOfLife || username != nil || disableDeviceEncryption || applySkuSiPolicy || silentInstall != nil || regionalOptions != nil {
            var body = ""
            if disablePrivacyPrompts || silentInstall != nil {
                let extraSilentOOBE = silentInstall != nil
                    ? "<HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>"
                    : ""
                body += "<OOBE><HideEULAPage>true</HideEULAPage><ProtectYourPC>3</ProtectYourPC>\(extraSilentOOBE)</OOBE>"
            }
            if let tz = regionalOptions?.timeZone {
                body += "<TimeZone>\(escapeXMLText(tz))</TimeZone>"
            }
            var commands: [String] = []
            if let username {
                body += "<UserAccounts><LocalAccounts><LocalAccount wcm:action=\"add\"><Name>\(username)</Name><DisplayName>\(username)</DisplayName><Group>Administrators;Power Users</Group><Password><Value>UABhAHMAcwB3AG8AcgBkAA==</Value><PlainText>false</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>"
                commands.append("net user \"\(username)\" /logonpasswordchg:yes")
                commands.append("net accounts /maxpwage:unlimited")
            }
            if applySkuSiPolicy {
                commands.append(#"cmd /c mountvol S: /S && copy %WINDIR%\system32\SecureBootUpdates\SkuSiPolicy.p7b S:\EFI\Microsoft\Boot && mountvol S: /D"#)
            }
            if qualityOfLife {
                let registry: [(String, String, Int)] = [
                    (#"HKLM\System\CurrentControlSet\Control\Session Manager\Power"#, "HiberbootEnabled", 0),
                    (#"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#, "ShowCopilotButton", 0),
                    (#"HKLM\Software\Policies\Microsoft\Windows\WindowsCopilot"#, "TurnOffWindowsCopilot", 1),
                    (#"HKCU\Software\Microsoft\Windows\CurrentVersion\Search"#, "SearchboxTaskbarMode", 1),
                    (#"HKCU\Software\Microsoft\Windows\CurrentVersion\Search"#, "SearchboxTaskbarModeCache", 1),
                    (#"HKLM\Software\Policies\Microsoft\Windows\CloudContent"#, "DisableWindowsConsumerFeatures", 1),
                    (#"HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"#, "SystemPaneSuggestionsEnabled", 0),
                    (#"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"#, "BingSearchEnabled", 0),
                    (#"HKLM\Software\Policies\Microsoft\Windows\Device Metadata"#, "PreventDeviceMetadataFromNetwork", 1),
                    (#"HKLM\Software\Policies\Microsoft\Dsh"#, "AllowNewsAndInterests", 0),
                    (#"HKLM\Software\Policies\Microsoft\Windows\Windows Feeds"#, "EnableFeeds", 0),
                    (#"HKLM\Software\Microsoft\Windows\CurrentVersion\Communications"#, "ConfigureChatAutoInstall", 0),
                    (#"HKLM\Software\Policies\Microsoft\Windows\CloudContent"#, "DisableCloudOptimizedContent", 1),
                    (#"HKLM\Software\Policies\Microsoft\Edge"#, "HideFirstRunExperience", 1),
                    (#"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"#, "Start_Layout", 1)
                ]
                commands += registry.map { path, name, value in "reg add \"\(path)\" /v \(name) /t REG_DWORD /d \(value) /f" }
                commands.append(#"PowerShell -NonInteractive -WindowStyle Hidden -Command "Set-ItemProperty -Path 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'VisiblePlaces' -Value $([convert]::FromBase64String('ztU0LVr6Q0WC8iLm6vd3PC+zZ+PeiVVDv85h83sYqTe8JIoUDNaJQqCAbtm7okiCRIF1/g0IrkKL2jTtl7ZjlEqwvXRK+WhPi9ZDmAcdqLyGCHNSqlFDQp97J3ZYRlnU')) -Type 'Binary'""#)
                commands.append(#"reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /t REG_SZ /d "" /f"#)
            }
            if !commands.isEmpty {
                let items = commands.enumerated().map { index, command in
                    let escaped = escapeXMLText(command)
                    return "<SynchronousCommand wcm:action=\"add\"><Order>\(index + 1)</Order><CommandLine>\(escaped)</CommandLine></SynchronousCommand>"
                }.joined()
                body += "<FirstLogonCommands>\(items)</FirstLogonCommands>"
            }
            var components = body.isEmpty ? "" : "<component name=\"Microsoft-Windows-Shell-Setup\" \(attributes)>\(body)</component>"
            if let regional = regionalOptions {
                components +=
                    "<component name=\"Microsoft-Windows-International-Core\" \(attributes)>" +
                    "<InputLocale>\(regional.inputLocale)</InputLocale>" +
                    "<SystemLocale>\(regional.systemLocale)</SystemLocale>" +
                    "<UserLocale>\(regional.userLocale)</UserLocale>" +
                    "<UILanguage>\(regional.uiLanguage)</UILanguage>" +
                    "<UILanguageFallback>\(regional.uiLanguageFallback)</UILanguageFallback>" +
                    "</component>"
            }
            if disableDeviceEncryption {
                components += "<component name=\"Microsoft-Windows-SecureStartup-FilterDriver\" \(attributes)><PreventDeviceEncryption>true</PreventDeviceEncryption></component>"
                components += "<component name=\"Microsoft-Windows-EnhancedStorage-Adm\" \(attributes)><TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled></component>"
            }
            sections.append("<settings pass=\"oobeSystem\">\(components)</settings>")
        }

        if offlineInternalDrives || forceSMode {
            var offlineComponents = ""
            if offlineInternalDrives {
                offlineComponents += "<component name=\"Microsoft-Windows-PartitionManager\" \(attributes)><SanPolicy>4</SanPolicy></component>"
            }
            if forceSMode {
                offlineComponents += "<component name=\"Microsoft-Windows-CodeIntegrity\" \(attributes)><SkuPolicyRequired>1</SkuPolicyRequired></component>"
            }
            sections.append("<settings pass=\"offlineServicing\">\(offlineComponents)</settings>")
        }

        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><unattend xmlns=\"urn:schemas-microsoft-com:unattend\">\(sections.joined())</unattend>"
    }

    private static func escapeXMLText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func isValidLocaleTag(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})+$"#, options: .regularExpression) != nil
    }

    private static func isValidLocaleOrKeyboard(_ value: String) -> Bool {
        isValidLocaleTag(value) || value.range(of: #"^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}(;[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8})*$"#, options: .regularExpression) != nil
    }

    private static func isValidTimeZone(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.range(of: #"^[A-Za-z0-9 _+\-()./]+$"#, options: .regularExpression) != nil
    }

    private static func validateUsername(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let reserved = ["administrator", "järjestelmänvalvoja", "administrateur", "rendszergazda", "administrador", "администратор", "administratör", "guest", "defaultaccount", "wdagutilityaccount", "helpassistant", "krbtgt", "local", "none", "system", "nul", "con", "prn", "aux"]
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " _-."))
        guard !name.isEmpty, name.utf16.count <= 20, !name.hasSuffix("."),
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }), !reserved.contains(name.lowercased()) else { throw AnswerError.invalidLocalAccount }
        return name
    }
}
