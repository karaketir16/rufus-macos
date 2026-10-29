import SwiftUI
import RufusCore

/// Equivalent of Rufus' "Windows User Experience" dialog (`SelectionDialog` in `src/rufus.c:1754`).
/// Shown after the user starts the operation; only the choices upstream offers for this image's build are listed.
struct WindowsUserExperienceSheet: View {
    let report: WindowsMediaReport
    @Binding var selection: WindowsUserExperience.Selection
    let onAccept: () -> Void
    let onCancel: () -> Void
    @State private var expertMode = false

    private var options: [WindowsUserExperience.Option] {
        WindowsUserExperience.availableOptions(for: report, expertMode: expertMode)
    }

    private func title(_ option: WindowsUserExperience.Option) -> String {
        switch option {
        case .secureBootTPMMinRAM: return "Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0"
        case .noOnlineAccount: return "Remove requirement for an online Microsoft account"
        case .setUser: return "Create a local account with username:"
        case .duplicateLocale: return "Set regional options to the same values as this user's"
        case .noDataCollection: return "Disable data collection (Skip privacy questions)"
        case .silentInstall: return "Silent install (⚠️ wipes the target Disk 0 without asking)"
        case .disableBitlocker: return "Disable automatic BitLocker device encryption"
        case .qolEnhancements: return "Quality-of-life improvements (OneDrive, Outlook, Teams, Copilot, ads, …)"
        case .useMS2023Bootloaders: return "Use 'Windows UEFI CA 2023' signed bootloaders"
        case .applySkuSiPolicy: return "Apply the SkuSiPolicy.p7b Secure Boot revocation policy"
        case .forceSMode: return "Force S Mode"
        }
    }

    private func tip(_ option: WindowsUserExperience.Option) -> String {
        switch option {
        case .secureBootTPMMinRAM: return "Skips the TPM, Secure Boot and RAM checks during setup."
        case .noOnlineAccount: return "Removes the internet/Microsoft account requirement during OOBE (BypassNRO)."
        case .setUser: return "Creates a local administrator with an empty password; you are asked to change it at first sign-in."
        case .duplicateLocale: return "Copies this Mac's time zone, language and region settings to Windows."
        case .noDataCollection: return "Hides the privacy screens and turns data collection off by default."
        case .silentInstall: return "Skips the language/edition/disk questions. Erases the first disk of the target computer."
        case .disableBitlocker: return "Prevents automatic encryption on Windows 11 24H2 and later."
        case .qolEnhancements: return "Extra tweaks suggested by Rufus (Start suggestions, Bing search, Copilot, news feed, …)."
        case .useMS2023Bootloaders: return "This media only boots on systems that have the 'Windows UEFI CA 2023' certificate."
        case .applySkuSiPolicy: return "Applies the policy that blocks old, revoked bootloaders."
        case .forceSMode: return "Restricts the installation to S Mode."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Windows User Experience").font(.title2.bold())
            Text("Customize the Windows installation? (Windows build \(report.windowsBuild.map(String.init) ?? "?"))")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(options, id: \.rawValue) { option in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(title(option), isOn: Binding(get: { selection.contains(option) }, set: { selection.set(option, $0) }))
                                .help(tip(option))
                            if let note = note(option) {
                                Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                            }
                            if option == .setUser && selection.contains(.setUser) {
                                TextField("Username", text: $selection.username).frame(maxWidth: 260).padding(.leading, 20)
                            }
                            if option == .silentInstall && selection.contains(.silentInstall) && !report.installEditions.isEmpty {
                                Picker("Edition to install:", selection: Binding(
                                    get: { selection.resolvedEditionIndex(for: report) },
                                    set: { selection.editionIndex = $0 }
                                )) {
                                    ForEach(report.installEditions) { edition in
                                        Text("\(edition.index): \(edition.name)").tag(edition.index)
                                    }
                                }
                                .frame(maxWidth: 420)
                                .padding(.leading, 20)
                            }
                        }
                    }
                    Divider()
                    Toggle("Expert mode (show additional options)", isOn: $expertMode)
                        .font(.caption)
                    Text("Status: these options only change the answer file (autounattend.xml) and the media. None of them has been verified end to end by an actual Windows installation, so none is guaranteed to work. Not implemented in this port: Windows To Go. LabConfig keys are written through the answer file instead of editing boot.wim's registry hive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("OK", action: onAccept).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, maxWidth: 620, maxHeight: 640)
    }

    /// Honest per-option caveats: what works only partially or depends on the machine being installed.
    private func note(_ option: WindowsUserExperience.Option) -> String? {
        switch option {
        case .silentInstall:
            return "Partial: Disk 0 is erased without asking. Rufus picks the host's edition; here you choose it from the image."
        case .applySkuSiPolicy:
            return "Partial: the command silently fails when SkuSiPolicy.p7b is missing on the target."
        case .useMS2023Bootloaders:
            return "Partial: the media only boots on devices with the 'Windows UEFI CA 2023' certificate installed."
        case .duplicateLocale:
            return "Partial: <TimeZone> is omitted for time zones that are not recognized."
        case .qolEnhancements:
            return "Partial: user registry (HKCU) values apply to the first account that signs in."
        case .noOnlineAccount:
            return "Partial: Microsoft removed BypassNRO in some Windows 11 builds, where it may have no effect."
        case .secureBootTPMMinRAM:
            return "LabConfig keys are written during setup through RunSynchronous (the registry hive is not edited directly)."
        case .setUser, .noDataCollection, .disableBitlocker, .forceSMode:
            return nil
        }
    }
}
