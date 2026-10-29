import Foundation

public struct DiskTarget: Equatable {
    public let identifier: String
    public let size: UInt64
}

public enum DiskInventory {
    /// Development-only escape hatch: set `RUFUS_ALLOW_VIRTUAL_DISKS=1` to let the app target
    /// `hdiutil` disk images (`VirtualOrPhysical == "Virtual"`). Used to exercise the whole
    /// format/copy flow inside a VM that has no physical external disks. Never enabled by default:
    /// without the variable the inventory stays fail-closed on physical, external, removable disks.
    public static var allowsVirtualDisks: Bool {
        ProcessInfo.processInfo.environment["RUFUS_ALLOW_VIRTUAL_DISKS"] == "1"
    }

    public static func parseInfo(_ data: Data, expectedIdentifier: String? = nil, includeExternalUSBDisks: Bool = false, allowVirtualDisks: Bool = allowsVirtualDisks) throws -> DiskTarget? {
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["DeviceIdentifier"] as? String,
              id.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              expectedIdentifier == nil || expectedIdentifier == id,
              info["WholeDisk"] as? Bool == true,
              info["Internal"] as? Bool == false,
              (info["RemovableMedia"] as? Bool == true ||
               (includeExternalUSBDisks && info["RemovableMedia"] as? Bool == false && info["BusProtocol"] as? String == "USB" && info["Ejectable"] as? Bool == true)),
              (info["VirtualOrPhysical"] as? String == "Physical" ||
               (allowVirtualDisks && info["VirtualOrPhysical"] as? String == "Virtual")),
              let size = info["TotalSize"] as? UInt64, size > 0 else { return nil }
        return DiskTarget(identifier: id, size: size)
    }

    public static func discover(includeExternalUSBDisks: Bool = false) throws -> [DiskTarget] {
        let data = try runDiskutil(allowsVirtualDisks ? ["list", "-plist", "external"] : ["list", "-plist", "external", "physical"])
        guard let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = list["WholeDisks"] as? [String] else { return [] }
        return try disks.compactMap { id in
            guard id.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return nil }
            return try parseInfo(runDiskutil(["info", "-plist", id]), expectedIdentifier: id, includeExternalUSBDisks: includeExternalUSBDisks)
        }
    }

    public static func lookup(identifier: String, includeExternalUSBDisks: Bool = false) throws -> DiskTarget? {
        guard identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return try parseInfo(runDiskutil(["info", "-plist", identifier]), expectedIdentifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks)
    }

    private static func runDiskutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "RufusMac.diskutil", code: Int(process.terminationStatus))
        }
        return data
    }
}
