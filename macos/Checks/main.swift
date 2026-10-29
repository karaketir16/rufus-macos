import Foundation
func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
func plist(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
let valid: [String: Any] = ["DeviceIdentifier": "disk4", "WholeDisk": true, "Internal": false, "RemovableMedia": true, "VirtualOrPhysical": "Physical", "TotalSize": 16000000000]
check(try DiskInventory.parseInfo(plist(valid)) != nil, "valid USB rejected")
for changes: [String: Any] in [["Internal": true], ["RemovableMedia": false], ["WholeDisk": false], ["VirtualOrPhysical": "Virtual"], ["DeviceIdentifier": "disk4s1"], ["TotalSize": 0]] {
    check(try DiskInventory.parseInfo(plist(valid.merging(changes) { _, new in new })) == nil, "unsafe disk accepted")
}
var missing = valid
missing.removeValue(forKey: "RemovableMedia")
check(try DiskInventory.parseInfo(plist(missing)) == nil, "missing metadata accepted")
print("Disk inventory checks passed")
let sampleURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try Data("abc".utf8).write(to: sampleURL)
defer { try? FileManager.default.removeItem(at: sampleURL) }
let vectors: [(Checksum.Algorithm, String)] = [(.md5, "900150983cd24fb0d6963f7d28e17f72"), (.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d"), (.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), (.sha512, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")]
for (algorithm, expected) in vectors { check(try Checksum.digest(file: sampleURL, algorithm: algorithm) == expected, "bad digest \(algorithm)") }
try Data().write(to: sampleURL)
check(try Checksum.digest(file: sampleURL, algorithm: .sha256) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty digest")
do { _ = try Checksum.digest(file: sampleURL.appendingPathExtension("missing"), algorithm: .sha256); fatalError("missing file accepted") } catch {}
print("Checksum checks passed")
let large = Data(repeating: 0x61, count: 2_000_000)
try large.write(to: sampleURL)
check(try Checksum.digest(file: sampleURL, algorithm: .sha256) == "bcf7f9d1b4311c3352e60502255ce09a6744df84e8f2c89f79c4b5d74933a95a", "large file digest")
do { check(try DiskInventory.parseInfo(Data("invalid".utf8)) == nil, "invalid plist accepted") } catch {}
print("Large file and malformed input checks passed")
let xml = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: true, bypassOnlineAccount: true, disablePrivacyPrompts: true)
for text in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassNRO", "ProtectYourPC", "processorArchitecture=\"amd64\""] { check(xml.contains(text), "missing answer file value \(text)") }
check(!xml.contains("WillWipeDisk"), "unexpected automatic disk wipe")
let minimal = try WindowsAnswerFile.make(architecture: .arm64, bypassHardware: false, bypassOnlineAccount: false, disablePrivacyPrompts: false)
check(!minimal.contains("BypassTPMCheck") && !minimal.contains("BypassNRO") && !minimal.contains("ProtectYourPC"), "unselected setting applied")
let parser = XMLParser(data: Data(xml.utf8))
check(parser.parse(), "invalid answer file XML")
print("Windows answer file checks passed")
let removal = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: false, bypassOnlineAccount: true, disablePrivacyPrompts: false, removeBundledApps: true)
check(XMLParser(data: Data(removal.utf8)).parse(), "invalid removal XML")
for term in ["DisableFileSyncNGSC", "OneDriveSetup.exe", "*Outlook*", "*Teams*", "Remove-AppxProvisionedPackage", "Remove-AppxPackage"] { check(removal.contains(term), "missing removal command \(term)") }
check(removal.components(separatedBy: "pass=\"specialize\"").count == 2, "duplicate specialize pass")
check(removal.contains("<Order>7</Order>"), "commands not ordered")
check(!minimal.contains("DisableFileSyncNGSC") && !minimal.contains("*Outlook*"), "removal must be opt-in")
print("Bundled app removal checks passed")
let qol = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: false, bypassOnlineAccount: false, disablePrivacyPrompts: true, qualityOfLife: true)
check(XMLParser(data: Data(qol.utf8)).parse(), "invalid QoL XML")
for term in ["HiberbootEnabled", "TurnOffWindowsCopilot", "SystemPaneSuggestionsEnabled", "PreventDeviceMetadataFromNetwork", "AllowNewsAndInterests", "HideFirstRunExperience", "VisiblePlaces", "86ca1aa0-34aa-4e8b-a509-50c905bae2a2", "<Order>17</Order>", "DisableFileSyncNGSC"] { check(qol.contains(term), "missing QoL item \(term)") }
check(qol.components(separatedBy: "pass=\"oobeSystem\"").count == 2, "duplicate oobeSystem pass")
check(!minimal.contains("FirstLogonCommands"), "QoL must be opt-in")
print("QoL answer file checks passed")
let wrongID = try plist(valid.merging(["DeviceIdentifier": "disk5"]) { _, new in new })
check(try DiskInventory.parseInfo(wrongID, expectedIdentifier: "disk4") == nil, "diskutil returned a different disk")
check(try DiskInventory.parseInfo(plist(valid), expectedIdentifier: "disk4")?.identifier == "disk4", "matching identity rejected")
print("Disk identity checks passed")
let usbFixed = valid.merging(["RemovableMedia": false, "BusProtocol": "USB", "Ejectable": true]) { _, new in new }
check(try DiskInventory.parseInfo(plist(usbFixed)) == nil, "fixed external disk visible by default")
check(try DiskInventory.parseInfo(plist(usbFixed), includeExternalUSBDisks: true) != nil, "explicit external USB disk omitted")
let notUSB = usbFixed.merging(["BusProtocol": "Thunderbolt"]) { _, new in new }
check(try DiskInventory.parseInfo(plist(notUSB), includeExternalUSBDisks: true) == nil, "non-USB fixed disk accepted")
print("External disk opt-in checks passed")
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: fixture.appendingPathComponent("sources"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: fixture.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixture) }
try Data([1]).write(to: fixture.appendingPathComponent("efi/boot/bootx64.efi"))
let fixtureWimlibPath = ProcessInfo.processInfo.environment["RUFUS_TEST_WIMLIB"] ?? FileManager.default.currentDirectoryPath + "/.deps/wimlib-1.14.5/bin/wimlib-imagex"
check(FileManager.default.isExecutableFile(atPath: fixtureWimlibPath), "wimlib-imagex required for checks: run scripts/build-wimlib.sh or set RUFUS_TEST_WIMLIB")
func runFixtureWimlib(_ args: [String]) throws {
    let proc = Process(); proc.executableURL = URL(fileURLWithPath: fixtureWimlibPath); proc.arguments = args
    proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
    try proc.run(); proc.waitUntilExit(); check(proc.terminationStatus == 0, "fixture wimlib failed: \(args.first ?? "")")
}
func bootWimAutounattend(_ wim: URL) throws -> String? {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: out) }
    let proc = Process(); proc.executableURL = URL(fileURLWithPath: fixtureWimlibPath)
    proc.arguments = ["extract", wim.path, "2", "/Autounattend.xml", "--dest-dir=\(out.path)"]
    proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
    try proc.run(); proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return try String(contentsOf: out.appendingPathComponent("Autounattend.xml"), encoding: .utf8)
}
let bootSeed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: bootSeed, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: bootSeed) }
try Data([1]).write(to: bootSeed.appendingPathComponent("seed.txt"))
try runFixtureWimlib(["capture", bootSeed.path, fixture.appendingPathComponent("sources/boot.wim").path, "Microsoft Windows PE", "--compress=none"])
try runFixtureWimlib(["append", bootSeed.path, fixture.appendingPathComponent("sources/boot.wim").path, "Microsoft Windows Setup", "--compress=none"])
let imageFile = fixture.appendingPathComponent("sources/install.wim")
FileManager.default.createFile(atPath: imageFile.path, contents: nil)
let sparse = try FileHandle(forWritingTo: imageFile)
try sparse.truncate(atOffset: 4_294_967_296)
try sparse.close()
let report = try WindowsMediaInspector.inspect(root: fixture)
check(report.architectures == [.amd64], "UEFI bootloader not detected")
check(report.installImage == "sources/install.wim", "install image not detected")
check(report.oversizedFiles == ["sources/install.wim"], "FAT32 limit not detected")
try FileManager.default.createSymbolicLink(atPath: fixture.appendingPathComponent("link").path, withDestinationPath: "/etc/passwd")
do { _ = try WindowsMediaInspector.inspect(root: fixture); fatalError("symbolic link accepted") } catch {}
print("Windows media inspection checks passed")
try FileManager.default.removeItem(at: fixture.appendingPathComponent("link"))
let small = try FileHandle(forWritingTo: imageFile)
try small.truncate(atOffset: 1)
try small.close()
let isoFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
defer { try? FileManager.default.removeItem(at: isoFile) }
let buildISO = Process()
buildISO.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
buildISO.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-o", isoFile.path, fixture.path]
buildISO.standardOutput = FileHandle.nullDevice
buildISO.standardError = FileHandle.nullDevice
try buildISO.run()
buildISO.waitUntilExit()
check(buildISO.terminationStatus == 0, "failed to create disposable ISO")
let isoReport = try WindowsMediaInspector.inspectISO(isoFile)
check(isoReport.architectures == [.amd64] && isoReport.hasBootImage && isoReport.installImage?.lowercased() == "sources/install.wim", "ISO inspection mismatch")
do { _ = try WindowsMediaInspector.inspectISO(isoFile.appendingPathExtension("missing")); fatalError("missing ISO accepted") } catch {}
print("Mounted ISO checks passed")
let tmpDir = FileManager.default.temporaryDirectory
let beforeMounts = Set(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).filter { $0.hasPrefix("RufusMount-") })
let badISO = tmpDir.appendingPathComponent(UUID().uuidString + ".iso")
try Data("not an image".utf8).write(to: badISO)
defer { try? FileManager.default.removeItem(at: badISO) }
do { _ = try WindowsMediaInspector.inspectISO(badISO); fatalError("bad ISO accepted") } catch {}
let afterMounts = Set(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).filter { $0.hasPrefix("RufusMount-") })
check(beforeMounts == afterMounts, "failed ISO left temporary mount directory")
print("ISO failure cleanup checks passed")
let destination = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: destination) }
try WindowsMediaStager.stage(source: fixture, destination: destination, answerFile: xml)
check(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sources/install.wim").path), "install image not staged")
check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("autounattend.xml").path), "answer file must not be written to the media root (upstream puts it in boot.wim)")
check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("sources/$OEM$").path), "Panther copy must not exist when the windowsPE pass is present")
let stagedBootList = Process(); stagedBootList.executableURL = URL(fileURLWithPath: fixtureWimlibPath); stagedBootList.arguments = ["dir", destination.appendingPathComponent("sources/boot.wim").path, "2"]
let stagedBootPipe = Pipe(); stagedBootList.standardOutput = stagedBootPipe
try stagedBootList.run(); stagedBootList.waitUntilExit()
check(String(decoding: stagedBootPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("/Autounattend.xml"), "Autounattend.xml missing from boot.wim image 2")
let stagedAppraiser = destination.appendingPathComponent("sources/appraiserres.dll")
check(FileManager.default.fileExists(atPath: stagedAppraiser.path) && ((try? FileManager.default.attributesOfItem(atPath: stagedAppraiser.path)[.size] as? Int) ?? -1) == 0, "empty appraiserres.dll placeholder missing")
do { try WindowsMediaStager.stage(source: fixture, destination: destination, answerFile: nil); fatalError("nonempty destination accepted") } catch {}
do { try WindowsMediaStager.stage(source: fixture, destination: fixture, answerFile: nil); fatalError("source accepted as destination") } catch {}
print("Windows media staging checks passed")
let emptyDestination = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: emptyDestination, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: emptyDestination) }
let largeAgain = try FileHandle(forWritingTo: imageFile)
try largeAgain.truncate(atOffset: 4_294_967_296)
try largeAgain.close()
do { try WindowsMediaStager.stage(source: fixture, destination: emptyDestination, answerFile: nil); fatalError("large FAT32 file accepted") } catch {}
check(try FileManager.default.contentsOfDirectory(atPath: emptyDestination.path).isEmpty, "large-file rejection wrote data")
let smallAgain = try FileHandle(forWritingTo: imageFile)
try smallAgain.truncate(atOffset: 1)
try smallAgain.close()
let conflict = fixture.appendingPathComponent("AutoUnattend.xml")
try Data("original".utf8).write(to: conflict)
do { try WindowsMediaStager.stage(source: fixture, destination: emptyDestination, answerFile: xml); fatalError("answer conflict accepted") } catch {}
try FileManager.default.removeItem(at: conflict)
check(try FileManager.default.contentsOfDirectory(atPath: emptyDestination.path).isEmpty, "conflict rejection wrote data")
print("Staging failure checks passed")
if let toolPath = ProcessInfo.processInfo.environment["RUFUS_TEST_WIMLIB"] {
    let wimRoot = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDir = wimRoot.appendingPathComponent("source", isDirectory: true)
    let partsDir = wimRoot.appendingPathComponent("parts", isDirectory: true)
    let restoredDir = wimRoot.appendingPathComponent("restored", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: restoredDir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: wimRoot) }
    var generator = SystemRandomNumberGenerator()
    let contents = Data((0..<900_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    try contents.write(to: sourceDir.appendingPathComponent("data.bin"))
    for index in 1...2 { try Data((0..<900_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).write(to: sourceDir.appendingPathComponent("extra\(index).bin")) }
    func wimTool(_ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: toolPath); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); check(process.terminationStatus == 0, "wimlib operation failed: \(args.first ?? "")")
    }
    let wim = wimRoot.appendingPathComponent("install.wim")
    try wimTool(["capture", sourceDir.path, wim.path, "test", "--compress=none"])
    try WIMSplitter.split(input: wim, destination: partsDir, tool: URL(fileURLWithPath: toolPath), partSizeMiB: 1)
    let parts = try FileManager.default.contentsOfDirectory(atPath: partsDir.path).filter { $0.hasSuffix(".swm") }
    check(parts.count > 1 && parts.contains("install.swm"), "split files missing")
    try wimTool(["apply", partsDir.appendingPathComponent("install.swm").path, "1", restoredDir.path, "--ref=\(partsDir.path)/install*.swm"])
    check(try Data(contentsOf: restoredDir.appendingPathComponent("data.bin")) == contents, "split WIM restored wrong data")
    let media = wimRoot.appendingPathComponent("media", isDirectory: true)
    let staged = wimRoot.appendingPathComponent("staged", isDirectory: true)
    try FileManager.default.createDirectory(at: media.appendingPathComponent("sources"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
    try FileManager.default.copyItem(at: wim, to: media.appendingPathComponent("sources/install.wim"))
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("sources/boot.wim"), to: media.appendingPathComponent("sources/boot.wim"))
    try WindowsMediaStager.stage(source: media, destination: staged, answerFile: xml, wimlib: URL(fileURLWithPath: toolPath), maximumFileBytes: 1_048_576, partSizeMiB: 1)
    check(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("sources/install.wim").path), "unsplit WIM copied")
    check(FileManager.default.fileExists(atPath: staged.appendingPathComponent("sources/install.swm").path), "split WIM missing in staged media")
    check(try bootWimAutounattend(staged.appendingPathComponent("sources/boot.wim")) == xml, "staged XML missing from boot.wim")
    let restoreStage = wimRoot.appendingPathComponent("restoreStage", isDirectory: true)
    try FileManager.default.createDirectory(at: restoreStage, withIntermediateDirectories: false)
    try wimTool(["apply", staged.appendingPathComponent("sources/install.swm").path, "1", restoreStage.path, "--ref=\(staged.path)/sources/install*.swm"])
    check(try Data(contentsOf: restoreStage.appendingPathComponent("data.bin")) == contents, "staged WIM restore failed")
    print("Real WIM split and staging checks passed")
}
let isoDestination = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: isoDestination, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: isoDestination) }
try WindowsMediaStager.stageISO(image: isoFile, destination: isoDestination, answerFile: xml)
check(FileManager.default.fileExists(atPath: isoDestination.appendingPathComponent("sources/install.wim").path), "ISO file staging failed")
check(try bootWimAutounattend(isoDestination.appendingPathComponent("sources/boot.wim")) == xml, "ISO answer file missing from boot.wim")
let mountsBeforeFailure = Set(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).filter { $0.hasPrefix("RufusMount-") })
do { try WindowsMediaStager.stageISO(image: isoFile, destination: isoDestination, answerFile: nil); fatalError("nonempty ISO destination accepted") } catch {}
let mountsAfterFailure = Set(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).filter { $0.hasPrefix("RufusMount-") })
check(mountsBeforeFailure == mountsAfterFailure, "failed staging leaked mount")
print("ISO staging and detach checks passed")
if let fatPath = ProcessInfo.processInfo.environment["RUFUS_TEST_FAT_DIR"] {
    let fatDestination = URL(fileURLWithPath: fatPath, isDirectory: true).appendingPathComponent("RufusTest-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: fatDestination, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: fatDestination) }
    try WindowsMediaStager.stageISO(image: isoFile, destination: fatDestination, answerFile: xml)
    check(FileManager.default.fileExists(atPath: fatDestination.appendingPathComponent("efi/boot/bootx64.efi").path), "EFI file missing from FAT volume")
    check(FileManager.default.fileExists(atPath: fatDestination.appendingPathComponent("sources/install.wim").path), "WIM missing from FAT volume")
    print("ISO staging on disposable FAT volume passed")
}
let selectedIdentity = DiskIdentity.Snapshot(identifier: "disk4", size: 16_000_000_000, registryEntryID: 100)
let sameIdentity = DiskIdentity.Snapshot(identifier: "disk4", size: 16_000_000_000, registryEntryID: 100)
let changedDevice = DiskIdentity.Snapshot(identifier: "disk4", size: 16_000_000_000, registryEntryID: 101)
let changedSize = DiskIdentity.Snapshot(identifier: "disk4", size: 15_000_000_000, registryEntryID: 100)
check(DiskIdentity.matches(selected: selectedIdentity, current: sameIdentity), "same disk rejected")
check(!DiskIdentity.matches(selected: selectedIdentity, current: changedDevice), "replacement disk accepted")
check(!DiskIdentity.matches(selected: selectedIdentity, current: changedSize), "changed size accepted")
print("Disk registry identity checks passed")
let liveTargets = try DiskInventory.discover(includeExternalUSBDisks: true)
for target in liveTargets {
    let first = try DiskIdentity.snapshot(identifier: target.identifier, includeExternalUSBDisks: true)
    let second = try DiskIdentity.snapshot(identifier: target.identifier, includeExternalUSBDisks: true)
    check(DiskIdentity.matches(selected: first, current: second), "unchanged live disk identity mismatch")
}
print("Read-only live disk identity check passed for \(liveTargets.count) device(s)")
let rawRoot = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: rawRoot) }
let rawSource = rawRoot.appendingPathComponent("source.img")
let rawDestination = rawRoot.appendingPathComponent("copy.img")
let rawContents = Data((0..<2_200_000).map { UInt8(truncatingIfNeeded: $0) })
try rawContents.write(to: rawSource)
var updates: [UInt64] = []
try RawImage.copy(source: rawSource, destination: rawDestination, progress: { updates.append($0) })
check(try Data(contentsOf: rawDestination) == rawContents, "image contents changed")
check(updates.last == UInt64(rawContents.count), "image progress incorrect")
do { try RawImage.copy(source: rawSource, destination: rawDestination); fatalError("existing image overwritten") } catch {}
check(try Data(contentsOf: rawDestination) == rawContents, "existing image changed")
let cancelledImage = rawRoot.appendingPathComponent("cancelled.img")
do { try RawImage.copy(source: rawSource, destination: cancelledImage, cancelled: { true }); fatalError("cancellation ignored") } catch {}
check(!FileManager.default.fileExists(atPath: cancelledImage.path), "cancelled partial image retained")
print("Raw image copy checks passed")
var stopCopy = false
let interrupted = rawRoot.appendingPathComponent("interrupted.img")
do { try RawImage.copy(source: rawSource, destination: interrupted, progress: { _ in stopCopy = true }, cancelled: { stopCopy }); fatalError("mid-copy cancellation ignored") } catch {}
check(!FileManager.default.fileExists(atPath: interrupted.path), "interrupted image retained")
let linkTarget = rawRoot.appendingPathComponent("link.img")
try FileManager.default.createSymbolicLink(at: linkTarget, withDestinationURL: rawDestination)
do { try RawImage.copy(source: rawSource, destination: linkTarget); fatalError("symlink destination accepted") } catch {}
check(try Data(contentsOf: rawDestination) == rawContents, "symlink target changed")
print("Raw copy cancellation and symlink checks passed")
if let fatRoot = ProcessInfo.processInfo.environment["RUFUS_TEST_EMPTY_FAT_ROOT"] {
    let root = URL(fileURLWithPath: fatRoot, isDirectory: true)
    check(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "test FAT root not empty")
    try WindowsMediaStager.stageISO(image: isoFile, destination: root, answerFile: xml)
    check(try Data(contentsOf: root.appendingPathComponent("efi/boot/bootx64.efi")) == Data([1]), "FAT root boot file incorrect")
    check(try bootWimAutounattend(root.appendingPathComponent("sources/boot.wim")) == xml, "FAT root answer file incorrect")
    print("ISO staging at disposable FAT root passed")
}
let localXML = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: false, bypassOnlineAccount: false, disablePrivacyPrompts: true, qualityOfLife: true, localAccount: "Alice", disableDeviceEncryption: true)
check(XMLParser(data: Data(localXML.utf8)).parse(), "invalid local account XML")
for text in ["<Name>Alice</Name>", "<Group>Administrators;Power Users</Group>", "UABhAHMAcwB3AG8AcgBkAA==", "logonpasswordchg:yes", "<PreventDeviceEncryption>true</PreventDeviceEncryption>", "<TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled>"] { check(localXML.contains(text), "missing local option \(text)") }
check(localXML.components(separatedBy: "<FirstLogonCommands>").count == 2, "duplicate first-logon commands")
for username in ["Administrator", "a&whoami", "", "NUL", "a."] {
    do { _ = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: false, bypassOnlineAccount: false, disablePrivacyPrompts: false, localAccount: username); fatalError("invalid account accepted") } catch {}
}
check(!minimal.contains("PreventDeviceEncryption") && !minimal.contains("LocalAccounts"), "unselected local options present")
print("Local account and encryption settings checks passed")

check(xml.contains("<AcceptEula>true</AcceptEula>") && xml.contains("<ProductKey><Key /></ProductKey>"), "windowsPE UserData ProductKey missing")
do {
    _ = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: false, bypassOnlineAccount: true, disablePrivacyPrompts: false, forceSMode: true)
    fatalError("conflicting online account bypass and S Mode accepted")
} catch WindowsAnswerFile.AnswerError.conflictingOptions {}
do {
    _ = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: false, bypassOnlineAccount: false, disablePrivacyPrompts: false, silentInstall: .init(editionIndex: 0, uiLanguage: "en-US"))
    fatalError("invalid silent install edition index accepted")
} catch WindowsAnswerFile.AnswerError.invalidSilentInstallConfiguration {}
let fullUpstreamXML = try WindowsAnswerFile.make(
    architecture: .amd64,
    bypassHardware: true,
    bypassOnlineAccount: false,
    disablePrivacyPrompts: true,
    qualityOfLife: true,
    localAccount: "Alice",
    disableDeviceEncryption: true,
    offlineInternalDrives: true,
    forceSMode: true,
    applySkuSiPolicy: true,
    silentInstall: .init(editionIndex: 2, uiLanguage: "tr-TR"),
    regionalOptions: .init(
        timeZone: "Turkey Standard Time",
        inputLocale: "041f:0000041f",
        systemLocale: "tr-TR",
        userLocale: "tr-TR",
        uiLanguage: "tr-TR",
        uiLanguageFallback: "en-US"
    )
)
check(XMLParser(data: Data(fullUpstreamXML.utf8)).parse(), "invalid full upstream XML")
for term in [
    "<DisableEncryptedDiskProvisioning>true</DisableEncryptedDiskProvisioning>",
    "<Label>RUFUS_BOOT</Label>",
    "<WillWipeDisk>true</WillWipeDisk>",
    "<Key>/IMAGE/INDEX</Key><Value>2</Value>",
    "Microsoft-Windows-International-Core-WinPE",
    "<UILanguage>tr-TR</UILanguage>",
    "<HideOnlineAccountScreens>true</HideOnlineAccountScreens>",
    "<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>",
    "<TimeZone>Turkey Standard Time</TimeZone>",
    "SkuSiPolicy.p7b",
    "Microsoft-Windows-International-Core",
    "<InputLocale>041f:0000041f</InputLocale>",
    "<UILanguageFallback>en-US</UILanguageFallback>",
    "pass=\"offlineServicing\"",
    "<SanPolicy>4</SanPolicy>",
    "<SkuPolicyRequired>1</SkuPolicyRequired>"
] {
    check(fullUpstreamXML.contains(term), "missing upstream XML element \(term)")
}
print("Full upstream Windows answer file checks passed")
let virtualOutput = tmpDir.appendingPathComponent(UUID().uuidString + ".sparseimage")
defer { try? FileManager.default.removeItem(at: virtualOutput) }
try VirtualMediaBuilder.create(iso: isoFile, destination: virtualOutput, sizeGiB: 4, answerFile: xml)
check(FileManager.default.fileExists(atPath: virtualOutput.path), "virtual image missing")
let virtualReport = try WindowsMediaInspector.inspectISO(virtualOutput)
check(virtualReport.hasBootImage && virtualReport.installImage?.lowercased() == "sources/install.wim", "virtual image content mismatch")
do { try VirtualMediaBuilder.create(iso: isoFile, destination: virtualOutput, sizeGiB: 4, answerFile: nil); fatalError("existing virtual image overwritten") } catch {}
print("Virtual media builder checks passed")
let invalidVirtual = tmpDir.appendingPathComponent(UUID().uuidString + ".sparseimage")
do { try VirtualMediaBuilder.create(iso: badISO, destination: invalidVirtual, sizeGiB: 4, answerFile: nil); fatalError("invalid ISO produced image") } catch {}
check(!FileManager.default.fileExists(atPath: invalidVirtual.path), "failed builder left output")
print("Virtual image failure cleanup checks passed")
let rawVirtual = tmpDir.appendingPathComponent(UUID().uuidString + ".img")
defer { try? FileManager.default.removeItem(at: rawVirtual) }
try VirtualMediaBuilder.exportRaw(sparseImage: virtualOutput, destination: rawVirtual)
let rawHead = try FileHandle(forReadingFrom: rawVirtual)
let sectors = try rawHead.read(upToCount: 17408) ?? Data()
try rawHead.close()
check(sectors.count == 17408 && sectors[510] == 0x55 && sectors[511] == 0xaa, "raw image missing MBR")
check(String(data: sectors[512..<520], encoding: .ascii) == "EFI PART", "raw image missing GPT")
let espGUID = Data([0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B])
for entryIndex in 0..<128 {
    let start = 1024 + entryIndex * 128
    check(Data(sectors[start..<(start + 16)]) != espGUID, "VirtualMediaBuilder image still contains conflicting EFI System Partition")
}
do { try VirtualMediaBuilder.exportRaw(sparseImage: virtualOutput, destination: rawVirtual); fatalError("existing raw image overwritten") } catch {}
print("Raw virtual media export checks passed")
var verifiedBytes: UInt64 = 0
check(try RawImage.verify(source: rawSource, destination: rawDestination, progress: { verifiedBytes = $0 }), "identical images did not verify")
check(verifiedBytes == UInt64(rawContents.count), "verify progress incorrect")
let corrupt = rawRoot.appendingPathComponent("corrupt.img")
try rawContents.write(to: corrupt)
let corrupter = try FileHandle(forWritingTo: corrupt)
try corrupter.seek(toOffset: 1_100_000)
try corrupter.write(contentsOf: Data([0xff]))
try corrupter.close()
check(try !RawImage.verify(source: rawSource, destination: corrupt), "corrupt image verified")
let shortImage = rawRoot.appendingPathComponent("short.img")
try Data([1]).write(to: shortImage)
check(try !RawImage.verify(source: rawSource, destination: shortImage), "different length verified")
do { _ = try RawImage.verify(source: rawSource, destination: rawDestination, cancelled: { true }); fatalError("verification cancellation ignored") } catch {}
print("Raw image verification checks passed")

check(PartitionTable.crc32(Data("123456789".utf8)) == 0xCBF4_3926, "IEEE 802.3 CRC32 vector mismatch")
let gptPlan = try PartitionTable.plan(scheme: .gpt(), totalBytes: 16 * 1024 * 1024 * 1024, blockSize: 512, filesystem: .fat32)
check(gptPlan.partitions.count == 1 && gptPlan.partitions[0].firstLBA == 2048 && gptPlan.partitions[0].typeGUID == PartitionTable.microsoftBasicDataGUID, "single-partition GPT plan mismatch")
check(gptPlan.primaryRegion[510] == 0x55 && gptPlan.primaryRegion[511] == 0xAA, "protective MBR signature missing")
check(String(data: gptPlan.primaryRegion[512..<520], encoding: .ascii) == "EFI PART", "GPT header signature missing")
let dualPlan = try PartitionTable.plan(scheme: .gpt(), totalBytes: 16 * 1024 * 1024 * 1024, blockSize: 512, filesystem: .exfat, uefiNTFSSizeBytes: 1024 * 1024)
check(dualPlan.partitions.count == 2 && dualPlan.partitions[1].name == "UEFI:NTFS" && dualPlan.partitions[1].attributes == PartitionTable.gptNoDriveLetterAttribute, "dual GPT UEFI:NTFS plan mismatch")
let mbrPlan = try PartitionTable.plan(scheme: .mbr(signature: PartitionTable.mbrUefiMarker, bootable: true), totalBytes: 4 * 1024 * 1024 * 1024, blockSize: 512, filesystem: .fat32)
check(mbrPlan.primaryRegion[440..<444] == Data("UEFI".utf8) && mbrPlan.primaryRegion[446] == 0x80 && mbrPlan.primaryRegion[450] == 0x0C, "MBR UEFI layout mismatch")
print("PartitionTable GPT and MBR layout checks passed")

check(BundledTools.locateUefiNtfsImage() != nil, "BundledTools failed to locate uefi-ntfs.img")
let volumeMetaDest = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: volumeMetaDest.appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: volumeMetaDest) }
do {
    try WindowsMediaStager.stage(source: fixture, destination: volumeMetaDest, answerFile: nil, allowVolumeMetadata: false)
    fatalError(".fseventsd directory accepted without allowVolumeMetadata")
} catch WindowsMediaStager.StagingError.destinationNotEmpty {}
try WindowsMediaStager.stage(source: fixture, destination: volumeMetaDest, answerFile: xml, allowVolumeMetadata: true)
check(try bootWimAutounattend(volumeMetaDest.appendingPathComponent("sources/boot.wim")) == xml, "allowVolumeMetadata staging failed")
let pantherDest = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: pantherDest, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: pantherDest) }
let nonPEXML = try WindowsAnswerFile.make(architecture: .amd64, bypassHardware: false, bypassOnlineAccount: false, disablePrivacyPrompts: true)
check(!WindowsCustomization.needsWindowsPEPass(nonPEXML) && WindowsCustomization.needsWindowsPEPass(xml), "windowsPE pass detection wrong")
try WindowsMediaStager.stage(source: fixture, destination: pantherDest, answerFile: nonPEXML)
check(try String(contentsOf: pantherDest.appendingPathComponent("sources/$OEM$/$$/Panther/unattend.xml"), encoding: .utf8) == nonPEXML, "Panther unattend.xml missing for non-windowsPE answer file")
check(!FileManager.default.fileExists(atPath: pantherDest.appendingPathComponent("autounattend.xml").path) && !FileManager.default.fileExists(atPath: pantherDest.appendingPathComponent("sources/appraiserres.dll").path), "non-windowsPE answer file wrongly applied WinPE customization")
check(try bootWimAutounattend(pantherDest.appendingPathComponent("sources/boot.wim")) == nil, "non-windowsPE answer file wrongly added to boot.wim")
let fakeSnapshot = DiskIdentity.Snapshot(identifier: "disk99", size: 16_000_000_000, registryEntryID: 12345)
do {
    _ = try PhysicalUSBMediaCreator.prepareWindowsUSB(selected: fakeSnapshot, confirmationIdentifier: "disk98", includeExternalUSBDisks: false, iso: isoFile)
    fatalError("mismatched confirmation identifier accepted")
} catch PhysicalUSBMediaCreator.CreatorError.confirmationMismatch {}
do {
    _ = try PhysicalUSBMediaCreator.prepareWindowsUSB(selected: fakeSnapshot, confirmationIdentifier: "disk99", includeExternalUSBDisks: false, iso: isoFile, volumeLabel: "***")
    fatalError("invalid volume label accepted")
} catch PhysicalUSBMediaCreator.CreatorError.invalidLabel {}
print("BundledTools and PhysicalUSBMediaCreator safety gate checks passed")

// Windows User Experience dialog logic (port of src/rufus.c:1696-1766)
func uxReport(build: Int?, panther: Bool = false) -> WindowsMediaReport {
    WindowsMediaReport(architectures: [.amd64], installImage: "sources/install.wim", oversizedFiles: [], hasBootImage: true, windowsBuild: build, defaultLanguage: "tr-TR", hasPantherUnattend: panther)
}
check(WindowsUserExperience.availableOptions(for: uxReport(build: 19045)) == [.setUser, .duplicateLocale, .noDataCollection], "Windows 10 option list mismatch")
check(WindowsUserExperience.availableOptions(for: uxReport(build: 22000)) == [.secureBootTPMMinRAM, .setUser, .duplicateLocale, .noDataCollection, .silentInstall, .disableBitlocker, .qolEnhancements], "Windows 11 21H2 option list mismatch")
check(WindowsUserExperience.availableOptions(for: uxReport(build: 26200), expertMode: true) == [.secureBootTPMMinRAM, .noOnlineAccount, .setUser, .duplicateLocale, .noDataCollection, .silentInstall, .disableBitlocker, .qolEnhancements, .useMS2023Bootloaders, .applySkuSiPolicy, .forceSMode], "Windows 11 26H1 option list mismatch")
check(WindowsUserExperience.isApplicable(uxReport(build: 26100)) && !WindowsUserExperience.isApplicable(uxReport(build: 26100, panther: true)) && !WindowsUserExperience.isApplicable(uxReport(build: 7601)) && !WindowsUserExperience.isApplicable(uxReport(build: nil)), "dialog applicability mismatch")
var uxSelection = WindowsUserExperience.Selection(mask: WindowsUserExperience.defaultSelectionMask, username: "Alice")
uxSelection.set(.qolEnhancements, true); uxSelection.set(.setUser, true); uxSelection.set(.noDataCollection, true)
let uxXML = try WindowsUserExperience.makeAnswerFile(selection: uxSelection, report: uxReport(build: 26100))
for term in ["BypassTPMCheck", "BypassNRO", "<Name>Alice</Name>", "ProtectYourPC", "HiberbootEnabled"] { check(uxXML.contains(term), "dialog answer file missing \(term)") }
let win10XML = try WindowsUserExperience.makeAnswerFile(selection: uxSelection, report: uxReport(build: 19045))
check(!win10XML.contains("BypassTPMCheck") && !win10XML.contains("BypassNRO") && !win10XML.contains("HiberbootEnabled") && win10XML.contains("<Name>Alice</Name>"), "options not offered for Windows 10 were applied")
uxSelection.set(.forceSMode, true)
check(!uxSelection.contains(.noOnlineAccount), "S Mode must clear online-account bypass")
let defaultsSuite = UserDefaults(suiteName: "rufus-ux-check-\(UUID().uuidString)")!
uxSelection.set(.silentInstall, true)
uxSelection.persist(to: defaultsSuite)
let restoredUX = WindowsUserExperience.Selection.restored(from: defaultsSuite)
check(restoredUX.contains(.qolEnhancements) && !restoredUX.contains(.forceSMode) && !restoredUX.contains(.silentInstall), "persisted selection must exclude S Mode and silent install (UNATTEND_DEFAULT_MASK)")
let hostRegional = WindowsUserExperience.hostRegionalOptions(locale: Locale(identifier: "tr_TR"), timeZone: TimeZone(identifier: "Europe/Istanbul")!)
check(hostRegional?.timeZone == "Turkey Standard Time" && hostRegional?.userLocale == "tr-TR", "host regional options mismatch")
let regionalXML = try WindowsUserExperience.makeAnswerFile(selection: .init(mask: WindowsUserExperience.Option.duplicateLocale.rawValue, username: ""), report: uxReport(build: 26100), regional: hostRegional)
check(regionalXML.contains("<TimeZone>Turkey Standard Time</TimeZone>"), "duplicate locale did not produce a time zone")
print("Windows User Experience dialog logic checks passed")

// Volume labels (src/format.c:263, src/format.c:1793-1796)
check(VolumeLabel.sanitize("RUFUS") == "RUFUS", "plain label changed")
check(VolumeLabel.sanitize("rufus", appendSilent: true) == "RUFUS (SILE", "silent suffix/truncation mismatch")
check(VolumeLabel.sanitize("RUFUS (SILENT)") == "RUFUS (SILE", "explicit silent label mismatch")
check(VolumeLabel.sanitize("my;usb") == "MYUSB", "FAT label sanitization mismatch")
check(VolumeLabel.sanitize("a.b") == "A_B", "dots must become underscores")
check(VolumeLabel.sanitize("   ") == nil && VolumeLabel.sanitize("***") == nil, "empty label accepted")
check(VolumeLabel.sanitize(String(repeating: "X", count: 20)) == String(repeating: "X", count: 11), "long label not truncated")
print("Volume label checks passed")

// md5sum.txt refresh (src/hash.c:2472)
do {
    let md5Root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: md5Root.appendingPathComponent("sources"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: md5Root) }
    try Data("abc".utf8).write(to: md5Root.appendingPathComponent("sources/appraiserres.dll"))
    try Data("hello".utf8).write(to: md5Root.appendingPathComponent("setup.exe"))
    let list = """
    # generated list
    \(String(repeating: "0", count: 32))  ./sources/appraiserres.dll
    \(String(repeating: "0", count: 32)) *setup.exe
    \(String(repeating: "0", count: 32))  ./untouched.txt
    """
    let listURL = md5Root.appendingPathComponent("md5sum.txt")
    try Data(list.utf8).write(to: listURL)
    let changed = try MD5SumUpdater.update(mediaRoot: md5Root, modifiedPaths: ["sources/appraiserres.dll", "setup.exe", "sources/boot.wim"])
    check(changed == ["md5sum.txt"], "md5sum.txt not reported as updated")
    let updated = try String(contentsOf: listURL, encoding: .utf8)
    check(updated.contains("900150983cd24fb0d6963f7d28e17f72  ./sources/appraiserres.dll"), "md5 entry for appraiserres.dll not refreshed")
    check(updated.contains("5d41402abc4b2a76b9719d911017c592 *setup.exe"), "md5 entry for setup.exe not refreshed")
    check(updated.contains(String(repeating: "0", count: 32) + "  ./untouched.txt"), "unmodified md5 entry changed")
    check(updated.contains("# generated list"), "comments must be preserved")
    check(try MD5SumUpdater.update(mediaRoot: md5Root, modifiedPaths: []) == [], "empty change list must be a no-op")
}
print("md5sum update checks passed")

// Install-image edition parsing (wimlib-imagex info output)
let sampleWimInfo = """
WIM Information:
----------------
Path:            /Volumes/CCCOMA_X64FRE_EN-US_DV9/sources/install.wim
Image Count:     2

Index:           1
----------------
Name:            Windows 11 Home
Description:     Windows 11 Home
Architecture:    x86_64
Default Language: en-US
Build:           26300

Index:           2
----------------
Name:            Windows 11 Pro
Description:     Windows 11 Pro
Architecture:    x86_64
Default Language: en-US
Build:           26300
"""
let parsedInfo = WindowsMediaInspector.parseImageInfo(sampleWimInfo)
check(parsedInfo.0 == 26300 && parsedInfo.1 == "en-US", "image build/language parsing failed")
check(parsedInfo.2.map(\.name) == ["Windows 11 Home", "Windows 11 Pro"] && parsedInfo.2.map(\.index) == [1, 2], "edition list parsing failed")
let editionReport = WindowsMediaReport(architectures: [.amd64], installImage: "sources/install.wim", oversizedFiles: [], hasBootImage: true, windowsBuild: 26300, defaultLanguage: "en-US", installEditions: parsedInfo.2)
var editionSelection = WindowsUserExperience.Selection(mask: WindowsUserExperience.Option.silentInstall.rawValue, username: "", editionIndex: 2)
check(editionSelection.resolvedEditionIndex(for: editionReport) == 2, "chosen edition not resolved")
editionSelection.editionIndex = 7
check(editionSelection.resolvedEditionIndex(for: editionReport) == 1, "unknown edition must fall back to the first image")
let silentXML = try WindowsUserExperience.makeAnswerFile(selection: .init(mask: WindowsUserExperience.Option.silentInstall.rawValue, username: "", editionIndex: 2), report: editionReport)
check(silentXML.contains("<Key>/IMAGE/INDEX</Key><Value>2</Value>"), "chosen edition missing from answer file")
check(silentXML.contains("<WillWipeDisk>true</WillWipeDisk>") && silentXML.contains("<WillShowUI>OnError</WillShowUI>"), "silent install not unattended")
let noEditions = WindowsMediaReport(architectures: [.amd64], installImage: "sources/install.wim", oversizedFiles: [], hasBootImage: true, windowsBuild: 26300)
check(WindowsUserExperience.Selection(mask: WindowsUserExperience.Option.silentInstall.rawValue, username: "", editionIndex: 3).resolvedEditionIndex(for: noEditions) == 1, "edition fallback without edition list failed")
print("Install edition checks passed")

// MS2023 bootloader replacement (src/wue.c:1355-1444)
do {
    let ex = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let seedEX = ex.appendingPathComponent("seed")
    try FileManager.default.createDirectory(at: seedEX.appendingPathComponent("Windows/Boot/EFI_EX"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: seedEX.appendingPathComponent("Windows/Boot/Fonts_EX"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: ex) }
    try Data([7]).write(to: seedEX.appendingPathComponent("Windows/Boot/EFI_EX/bootmgfw_EX.efi"))
    try Data([8]).write(to: seedEX.appendingPathComponent("Windows/Boot/EFI_EX/bootmgr_EX.efi"))
    try Data([9]).write(to: seedEX.appendingPathComponent("Windows/Boot/Fonts_EX/segoe_EX.ttf"))
    let exMedia = ex.appendingPathComponent("media")
    try FileManager.default.createDirectory(at: exMedia.appendingPathComponent("sources"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exMedia.appendingPathComponent("efi/boot"), withIntermediateDirectories: true)
    try Data([1]).write(to: exMedia.appendingPathComponent("efi/boot/bootx64.efi"))
    try Data([1]).write(to: exMedia.appendingPathComponent("bootmgr.efi"))
    let exWim = exMedia.appendingPathComponent("sources/boot.wim")
    try runFixtureWimlib(["capture", bootSeed.path, exWim.path, "Microsoft Windows PE", "--compress=none"])
    try runFixtureWimlib(["append", seedEX.path, exWim.path, "Microsoft Windows Setup", "--compress=none"])
    let exLog = try WindowsCustomization.apply(mediaRoot: exMedia, answerFile: nonPEXML, windowsBuild: 26200, wimlib: URL(fileURLWithPath: fixtureWimlibPath), useMS2023Bootloaders: true).log
    check(try Data(contentsOf: exMedia.appendingPathComponent("efi/boot/bootx64.efi")) == Data([7]), "bootx64.efi not replaced by bootmgfw_EX.efi")
    check(try Data(contentsOf: exMedia.appendingPathComponent("bootmgr.efi")) == Data([8]), "bootmgr.efi not replaced by bootmgr_EX.efi")
    check(try Data(contentsOf: exMedia.appendingPathComponent("efi/microsoft/boot/Fonts/segoe.ttf")) == Data([9]), "font not replaced/renamed without _EX")
    check(exLog.contains(where: { $0.contains("CA 2023") }), "MS2023 log line missing")
}
print("MS2023 bootloader replacement checks passed")
if let realISO = ProcessInfo.processInfo.environment["RUFUS_TEST_WINDOWS_ISO"] {
    let realReport = try WindowsMediaInspector.inspectISO(URL(fileURLWithPath: realISO), wimlib: URL(fileURLWithPath: fixtureWimlibPath))
    check((realReport.windowsBuild ?? 0) >= 22000 && realReport.isWindows11 && realReport.defaultLanguage != nil, "real ISO build/language not read")
    print("Real Windows ISO build detection passed (build \(realReport.windowsBuild ?? 0))")
}

if let id = ProcessInfo.processInfo.environment["RUFUS_TEST_VIRTUAL_DISK"], let backing = ProcessInfo.processInfo.environment["RUFUS_TEST_VIRTUAL_BACKING"] {
    let deviceSource = rawRoot.appendingPathComponent("device-source.img")
    let pattern = Data((0..<2_097_152).map { UInt8(truncatingIfNeeded: $0) })
    try pattern.write(to: deviceSource)
    let snapshot = try VirtualDeviceWriter.inspect(identifier: id, backingImage: URL(fileURLWithPath: backing))
    do { _ = try VirtualDeviceWriter.inspect(identifier: id, backingImage: deviceSource); fatalError("wrong backing image accepted") } catch {}
    let unaligned = rawRoot.appendingPathComponent("unaligned.img")
    try Data([1]).write(to: unaligned)
    do { try VirtualDeviceWriter.write(source: unaligned, target: snapshot, backingImage: URL(fileURLWithPath: backing)); fatalError("unaligned image accepted") } catch {}
    var deviceProgress: UInt64 = 0
    try VirtualDeviceWriter.write(source: deviceSource, target: snapshot, backingImage: URL(fileURLWithPath: backing), progress: { deviceProgress = $0 })
    check(deviceProgress == UInt64(pattern.count), "virtual write progress incorrect")
    var comparedDevice: UInt64 = 0
    check(try VirtualDeviceWriter.verify(source: deviceSource, target: snapshot, backingImage: URL(fileURLWithPath: backing), progress: { comparedDevice = $0 }), "matching virtual disk did not verify")
    check(comparedDevice == UInt64(pattern.count), "virtual verification progress incorrect")
    let modified = rawRoot.appendingPathComponent("modified-device-source.img")
    var altered = pattern; altered[1_100_000] ^= 0xff; try altered.write(to: modified)
    check(try !VirtualDeviceWriter.verify(source: modified, target: snapshot, backingImage: URL(fileURLWithPath: backing)), "altered data verified")
    do { _ = try VirtualDeviceWriter.verify(source: deviceSource, target: snapshot, backingImage: URL(fileURLWithPath: backing), cancelled: { true }); fatalError("verification cancellation ignored") } catch {}
    let device = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/r\(id)"))
    let readBack = try device.read(upToCount: pattern.count)
    try device.close()
    check(readBack == pattern, "virtual disk write mismatch")

    do { try DiskMountGuard.withUnmountedGuard(identifier: "disk0s1") {}; fatalError("slice identifier accepted by DiskMountGuard") } catch {}
    var guardBodyRan = false
    try DiskMountGuard.withUnmountedGuard(identifier: id) {
        guardBodyRan = true
        do { try DiskMountGuard.withUnmountedGuard(identifier: id) {}; fatalError("re-entrant DiskMountGuard succeeded") } catch {}
    }
    check(guardBodyRan, "DiskMountGuard body did not run")

    let fatSparse = rawRoot.appendingPathComponent("partitioned.sparseimage")
    let fatRaw = rawRoot.appendingPathComponent("partitioned.img")
    let createSparse = Process()
    createSparse.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    createSparse.arguments = ["create", "-quiet", "-size", "64m", "-fs", "MS-DOS", "-volname", "GUARDTEST", "-type", "SPARSE", "-layout", "GPTSPUD", fatSparse.path]
    try createSparse.run()
    createSparse.waitUntilExit()
    check(createSparse.terminationStatus == 0, "failed to create partitioned test sparseimage")
    try VirtualMediaBuilder.exportRaw(sparseImage: fatSparse, destination: fatRaw)
    try VirtualDeviceWriter.write(source: fatRaw, target: snapshot, backingImage: URL(fileURLWithPath: backing))
    check(try VirtualDeviceWriter.verify(source: fatRaw, target: snapshot, backingImage: URL(fileURLWithPath: backing)), "partitioned GPT/FAT32 image did not verify on virtual device")

    func runDiskutilMount(_ arguments: [String]) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    try DiskMountGuard.withUnmountedGuard(identifier: id) {
        let blockedStatus = try runDiskutilMount(["mount", "\(id)s1"])
        check(blockedStatus != 0, "diskutil mount succeeded while DiskMountGuard was active")
    }
    let allowedStatus = try runDiskutilMount(["mount", "-mountOptions", "nobrowse", "\(id)s1"])
    check(allowedStatus == 0, "diskutil mount failed after DiskMountGuard was released")
    try DiskMountGuard.withUnmountedGuard(identifier: id) {
        _ = try VirtualDeviceWriter.inspect(identifier: id, backingImage: URL(fileURLWithPath: backing))
    }
    print("Virtual device write, read-back and DiskMountGuard checks passed")

    let backingURL = URL(fileURLWithPath: backing)
    let preparedPlan = try VirtualDiskFormatter.prepareWindowsMedia(
        iso: isoFile,
        target: snapshot,
        backingImage: backingURL,
        scheme: .gpt(),
        filesystem: .fat32,
        volumeLabel: "RUFUSUSB",
        answerFile: fullUpstreamXML
    )
    check(preparedPlan.partitions.count == 1 && preparedPlan.partitions[0].typeGUID == PartitionTable.microsoftBasicDataGUID, "unexpected GPT layout from VirtualDiskFormatter")
    let verifyMount = rawRoot.appendingPathComponent("verify-mount", isDirectory: true)
    try FileManager.default.createDirectory(at: verifyMount, withIntermediateDirectories: false)
    check(try runDiskutilMount(["mount", "-mountOptions", "nobrowse", "-mountPoint", verifyMount.path, "\(id)s1"]) == 0, "failed to mount formatted GPT/FAT32 slice")
    let stagedReport = try WindowsMediaInspector.inspect(root: verifyMount)
    check(stagedReport.hasBootImage && stagedReport.installImage?.lowercased() == "sources/install.wim" && stagedReport.architectures == [.amd64], "formatted virtual USB missing staged Windows media")
    check(try bootWimAutounattend(verifyMount.appendingPathComponent("sources/boot.wim")) == fullUpstreamXML, "formatted virtual USB missing Autounattend.xml in boot.wim")
    try DiskMountGuard.withUnmountedGuard(identifier: id) {
        _ = try VirtualDeviceWriter.inspect(identifier: id, backingImage: backingURL)
    }

    let uefiImgCandidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../res/uefi/uefi-ntfs.img"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("res/uefi/uefi-ntfs.img")
    ]
    if let uefiImg = uefiImgCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        let exfatPlan = try VirtualDiskFormatter.prepareWindowsMedia(
            iso: isoFile,
            target: snapshot,
            backingImage: backingURL,
            scheme: .gpt(),
            filesystem: .exfat,
            volumeLabel: "RUFUSEXFAT",
            answerFile: fullUpstreamXML,
            uefiNTFSImage: uefiImg
        )
        check(exfatPlan.partitions.count == 2 && exfatPlan.partitions[1].name == "UEFI:NTFS", "exFAT + UEFI:NTFS layout missing second partition")
        let uefiVerifyMount = rawRoot.appendingPathComponent("uefi-ntfs-mount", isDirectory: true)
        try FileManager.default.createDirectory(at: uefiVerifyMount, withIntermediateDirectories: false)
        check(try runDiskutilMount(["mount", "-mountOptions", "nobrowse", "-mountPoint", uefiVerifyMount.path, "\(id)s2"]) == 0, "failed to mount UEFI:NTFS slice")
        check(FileManager.default.fileExists(atPath: uefiVerifyMount.appendingPathComponent("EFI/Boot/bootx64.efi").path), "UEFI:NTFS bootloader missing on slice 2")
        check(FileManager.default.fileExists(atPath: uefiVerifyMount.appendingPathComponent("EFI/Rufus/exfat_x64.efi").path), "UEFI:NTFS exfat driver missing on slice 2")
        try DiskMountGuard.withUnmountedGuard(identifier: id) {
            _ = try VirtualDeviceWriter.inspect(identifier: id, backingImage: backingURL)
        }
    }
    print("VirtualDiskFormatter GPT/FAT32 and exFAT+UEFI:NTFS media preparation checks passed")
}
