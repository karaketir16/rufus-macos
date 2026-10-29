// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit

/// Read-only snapshot used to detect disk replacement before a future write operation.
/// It does not eliminate the race between checking and opening a device.
public enum DiskIdentity {
    public struct Snapshot: Equatable {
        public let identifier: String
        public let size: UInt64
        public let registryEntryID: UInt64

        public init(identifier: String, size: UInt64, registryEntryID: UInt64) {
            self.identifier = identifier
            self.size = size
            self.registryEntryID = registryEntryID
        }
    }
    public enum IdentityError: Error { case unavailable, changed }

    public static func matches(selected: Snapshot, current: Snapshot) -> Bool {
        selected == current && selected.size > 0 && selected.registryEntryID != 0
    }

    public static func snapshot(identifier: String, includeExternalUSBDisks: Bool = false) throws -> Snapshot {
        let before = try registryID(identifier)
        guard let disk = try DiskInventory.lookup(identifier: identifier, includeExternalUSBDisks: includeExternalUSBDisks) else { throw IdentityError.unavailable }
        let after = try registryID(identifier)
        guard before == after else { throw IdentityError.changed }
        return Snapshot(identifier: disk.identifier, size: disk.size, registryEntryID: before)
    }

    static func registryID(_ identifier: String) throws -> UInt64 {
        guard identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              let query = IOBSDNameMatching(kIOMainPortDefault, 0, identifier) else { throw IdentityError.unavailable }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, query)
        guard entry != 0 else { throw IdentityError.unavailable }
        defer { IOObjectRelease(entry) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS, id != 0 else { throw IdentityError.unavailable }
        return id
    }
}
