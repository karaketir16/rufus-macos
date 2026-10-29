import SwiftUI
import AppKit
import RufusCore

@main
struct RufusMacApp: App {
    var body: some Scene {
        WindowGroup { MainView() }
            .windowResizability(.contentMinSize)
    }
}

struct MainView: View {
    @State private var disks: [DiskTarget] = []
    @State private var selectedDiskID = ""
    @State private var selectedSnapshot: DiskIdentity.Snapshot?
    @State private var includeFixed = false
    @State private var imageURL: URL?
    @State private var scheme: PhysicalUSBMediaCreator.Scheme = .gpt
    @State private var filesystem: PhysicalUSBMediaCreator.Filesystem = .fat32
    @State private var volumeLabel = "RUFUS"
    @State private var confirmDiskID = ""
    @State private var result = ""
    @State private var status = "No ISO selected yet."
    @State private var busy = false
    @State private var uxSelection = WindowsUserExperience.Selection.restored()
    @State private var uxReport: WindowsMediaReport?
    @State private var uxHandled = false
    @State private var showLimitations = false
    @State private var imageMode: RawDiskWriter.Mode = .fileCopy
    @State private var writeProgress: Double = 0
    @State private var lastReport: WindowsMediaReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rufus macOS").font(.largeTitle.bold())
                Text("Windows 11 USB preparation, WIM splitting and setup customization tool (development build).")
                    .foregroundStyle(.secondary)
                if DiskInventory.allowsVirtualDisks {
                    Text("DEVELOPMENT MODE (RUFUS_ALLOW_VIRTUAL_DISKS=1): virtual disks can be targeted too. This is not a real USB test.")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                GroupBox("USB and external disks") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Also list external USB disks reported as fixed", isOn: $includeFixed)
                            .onChange(of: includeFixed) { _ in refreshDisks() }
                        if disks.isEmpty {
                            Text("No suitable disk found.").foregroundStyle(.secondary)
                        } else {
                            Picker("Target USB disk", selection: $selectedDiskID) {
                                Text("Select a disk…").tag("")
                                ForEach(disks, id: \.identifier) { disk in
                                    Text("\(disk.identifier) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: disk.size), countStyle: .file))")
                                        .tag(disk.identifier)
                                }
                            }
                            .onChange(of: selectedDiskID) { newValue in
                                captureSnapshot(for: newValue)
                            }
                        }
                        Button("Refresh disks", action: refreshDisks).disabled(busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("Windows ISO inspection and formatting") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Select ISO…", action: chooseISO).disabled(busy)
                            Text(imageURL?.lastPathComponent ?? "No file selected").lineLimit(1)
                        }
                        Button("Inspect ISO", action: inspectISO).disabled(imageURL == nil || busy)
                        Picker("Image mode", selection: $imageMode) {
                            ForEach(RawDiskWriter.Mode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }.frame(maxWidth: 460)
                        Text(imageMode == .dd
                             ? "DD images are written byte for byte and cannot be customised. Use it for Linux and other hybrid images."
                             : "Files are copied to a formatted disk so Windows setup files can be split and the Windows User Experience options applied.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Partition scheme", selection: $scheme) {
                            Text("GPT (UEFI)").tag(PhysicalUSBMediaCreator.Scheme.gpt)
                            Text("MBR (BIOS or UEFI-CSM)").tag(PhysicalUSBMediaCreator.Scheme.mbr)
                        }.frame(maxWidth: 360)
                        Picker("File system", selection: $filesystem) {
                            Text("FAT32 (Default — WIM files over 4 GB are split automatically)").tag(PhysicalUSBMediaCreator.Filesystem.fat32)
                            Text("ExFAT").tag(PhysicalUSBMediaCreator.Filesystem.exfat)
                        }.frame(maxWidth: 460)
                        Text("NTFS is not offered: macOS mounts NTFS read-only, so Windows setup files cannot be copied onto it.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Volume label:")
                            TextField("RUFUS", text: $volumeLabel).frame(maxWidth: 160)
                        }
                        if let snapshot = selectedSnapshot {
                            Divider()
                            Text("⚠️ Write confirmation: all data on '\(snapshot.identifier)' will be erased. Type '\(snapshot.identifier)' below to confirm:")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            HStack {
                                TextField(snapshot.identifier, text: $confirmDiskID).frame(maxWidth: 140)
                                Button("START…", action: startPressed)
                                    .disabled(busy || imageURL == nil || confirmDiskID != snapshot.identifier)
                            }
                        }
                        if busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                if writeProgress > 0, writeProgress < 1 {
                                    ProgressView(value: writeProgress).frame(maxWidth: 260)
                                    Text("\(Int(writeProgress * 100))%").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text(status).foregroundStyle(.secondary).textSelection(.enabled)
                        if !result.isEmpty { Text(result).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                Spacer()
                HStack {
                    Button("Known limitations…") { showLimitations = true }
                    Spacer()
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 620, minHeight: 580)
            .onAppear(perform: refreshDisks)
            .sheet(item: $uxReport, onDismiss: {
                // Escape / other dismissals must not leave the app stuck in `busy`.
                if !uxHandled {
                    busy = false
                    status = "Operation cancelled."
                }
            }) { report in
                WindowsUserExperienceSheet(report: report, selection: $uxSelection, onAccept: {
                    uxHandled = true
                    uxReport = nil
                    acceptUserExperience(report)
                }, onCancel: {
                    uxHandled = true
                    uxReport = nil
                    busy = false
                    status = "Operation cancelled."
                })
                .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showLimitations) { KnownLimitationsSheet() }
    }

    private func captureSnapshot(for identifier: String) {
        confirmDiskID = ""
        guard !identifier.isEmpty else {
            selectedSnapshot = nil
            return
        }
        selectedSnapshot = try? DiskIdentity.snapshot(identifier: identifier, includeExternalUSBDisks: includeFixed)
    }

    private func refreshDisks() {
        let include = includeFixed
        DispatchQueue.global(qos: .userInitiated).async {
            let value = Result { try DiskInventory.discover(includeExternalUSBDisks: include) }
            DispatchQueue.main.async {
                guard include == includeFixed else { return }
                switch value {
                case .success(let found):
                    disks = found
                    if !found.contains(where: { $0.identifier == selectedDiskID }) {
                        selectedDiskID = ""
                        selectedSnapshot = nil
                        confirmDiskID = ""
                    }
                case .failure(let error):
                    disks = []
                    selectedDiskID = ""
                    selectedSnapshot = nil
                    status = "Could not read disks: \(error.localizedDescription)"
                }
            }
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "iso")!]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { imageURL = panel.url; result = ""; status = "Ready to inspect." }
    }

    private func inspectISO() {
        guard let image = imageURL else { return }
        busy = true; result = ""; status = "Inspecting ISO…"
        DispatchQueue.global(qos: .userInitiated).async {
            let value = Result { try WindowsMediaInspector.inspectISO(image) }
            DispatchQueue.main.async {
                busy = false
                switch value {
                case .failure(let error): status = "Inspection failed: \(error.localizedDescription)"
                case .success(let report):
                    lastReport = report
                    if RawDiskWriter.recommendsDD(for: report) {
                        imageMode = .dd
                        status = "This image is not Windows installation media; DD image mode was selected."
                    } else {
                        status = "Inspection complete; boot has not been verified yet."
                    }
                    let architectures = report.architectures.map(\.rawValue).sorted().joined(separator: ", ")
                    let wimlibReady = BundledTools.locateWimlib() != nil ? "ready" : "not found"
                    let build = report.windowsBuild.map(String.init) ?? "unknown"
                    result = "UEFI: \(architectures.isEmpty ? "not found" : architectures)\nInstall image: \(report.installImage ?? "not found")\nBoot.wim: \(report.hasBootImage ? "present" : "missing")\nWindows build: \(build)\nFiles above the FAT32 limit: \(report.oversizedFiles.isEmpty ? "none" : report.oversizedFiles.joined(separator: ", "))\nwimlib-imagex: \(wimlibReady)"
                }
            }
        }
    }

    /// Rufus flow: START → inspect the image → "Windows User Experience" dialog (Windows 10/11 images without an
    /// existing Panther unattend.xml) → build `unattend.xml` from the choices → format, copy and customize.
    private func startPressed() {
        guard let image = imageURL, let snapshot = selectedSnapshot else { return }
        if imageMode == .dd {
            startDDWrite(image: image, snapshot: snapshot)
            return
        }
        busy = true
        status = "Inspecting ISO…"
        DispatchQueue.global(qos: .userInitiated).async {
            let value = Result { try WindowsMediaInspector.inspectISO(image) }
            DispatchQueue.main.async {
                switch value {
                case .failure(let error):
                    busy = false
                    status = "Inspection failed: \(error.localizedDescription)"
                case .success(let report):
                    uxHandled = false
                    if WindowsUserExperience.isApplicable(report) {
                        status = "Preparing Windows User Experience options…"
                        uxReport = report
                    } else {
                        if report.hasPantherUnattend {
                            status = "The ISO already contains a Panther unattend.xml; the Windows User Experience dialog will not be shown."
                        }
                        prepareSelectedUSB(answerFile: nil, useMS2023: false)
                    }
                }
            }
        }
    }

    /// Rufus' DD mode: no inspection-driven customisation, the image goes to the disk unchanged.
    private func startDDWrite(image: URL, snapshot: DiskIdentity.Snapshot) {
        let include = includeFixed
        busy = true
        writeProgress = 0
        status = "Preparing DD write…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try RawDiskWriter.write(
                    image: image,
                    selected: snapshot,
                    includeExternalUSBDisks: include,
                    verify: true,
                    statusUpdate: { message in DispatchQueue.main.async { status = message } },
                    progress: { fraction in DispatchQueue.main.async { writeProgress = fraction } }
                )
            }
            DispatchQueue.main.async {
                busy = false
                writeProgress = 0
                confirmDiskID = ""
                switch outcome {
                case .success(let result):
                    status = "DD write finished: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: result.bytesWritten), countStyle: .file)) written"
                        + (result.verified ? ", verified against the image." : " (verification skipped).")
                case .failure(let error):
                    status = "DD write failed: \(error)"
                }
            }
        }
    }

    private func acceptUserExperience(_ report: WindowsMediaReport) {
        uxSelection.persist()
        do {
            let answerFile = try WindowsUserExperience.makeAnswerFile(
                selection: uxSelection,
                report: report,
                regional: WindowsUserExperience.hostRegionalOptions()
            )
            prepareSelectedUSB(answerFile: answerFile, useMS2023: WindowsUserExperience.usesMS2023Bootloaders(selection: uxSelection, report: report))
        } catch WindowsAnswerFile.AnswerError.invalidLocalAccount {
            busy = false
            status = "Enter a valid username: at most 20 letters, digits, spaces or _ - ."
        } catch {
            busy = false
            status = "Could not build the setup settings: \(error.localizedDescription)"
        }
    }

    private func prepareSelectedUSB(answerFile: String?, useMS2023: Bool) {
        guard let image = imageURL, let snapshot = selectedSnapshot else { busy = false; return }
        let confirmation = confirmDiskID
        let include = includeFixed
        let chosenScheme = scheme
        let chosenFS = filesystem
        let chosenLabel = volumeLabel
        busy = true
        status = "Starting USB preparation…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try PhysicalUSBMediaCreator.prepareWindowsUSB(
                    selected: snapshot,
                    confirmationIdentifier: confirmation,
                    includeExternalUSBDisks: include,
                    iso: image,
                    scheme: chosenScheme,
                    filesystem: chosenFS,
                    volumeLabel: chosenLabel,
                    answerFile: answerFile,
                    silentInstall: uxSelection.contains(.silentInstall),
                    useMS2023Bootloaders: useMS2023,
                    wimlib: BundledTools.locateWimlib(),
                    statusUpdate: { message in
                        DispatchQueue.main.async { status = message }
                    }
                )
            }
            DispatchQueue.main.async {
                busy = false
                confirmDiskID = ""
                switch outcome {
                case .success(let mountURL):
                    status = "USB installation media is ready: \(mountURL.path)"
                case .failure(let error):
                    status = "USB preparation failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
