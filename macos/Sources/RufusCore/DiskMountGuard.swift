import Foundation
import DiskArbitration

/// Prevents Disk Arbitration from mounting partitions on a target whole disk during a device operation,
/// and unmounts any currently mounted partitions on that whole disk after the mount blocker is active.
public enum DiskMountGuard {
    public enum GuardError: Error {
        case invalidDisk
        case alreadyGuarded
        case unavailable
        case changed
        case unmountRejected(Int32)
        case timedOut
    }

    private static let lock = NSLock()
    private static var activeDisks: Set<String> = []

    private final class ApprovalContext {
        let wholeIdentifier: String
        init(wholeIdentifier: String) {
            self.wholeIdentifier = wholeIdentifier
        }
    }

    private final class UnmountCompletion {
        let semaphore = DispatchSemaphore(value: 0)
        var dissenterStatus: Int32?
    }

    private static let approvalCallback: DADiskMountApprovalCallback = { disk, context in
        guard let context else { return nil }
        let approval = Unmanaged<ApprovalContext>.fromOpaque(context).takeUnretainedValue()
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        if let bsdName = DADiskGetBSDName(whole), String(cString: bsdName) == approval.wholeIdentifier {
            let refusal = DADissenterCreate(
                kCFAllocatorDefault,
                DAReturn(kDAReturnBusy),
                "RufusMac device operation in progress" as CFString
            )
            return Unmanaged.passRetained(refusal)
        }
        return nil
    }

    public static func withUnmountedGuard<T>(
        identifier: String,
        timeout: TimeInterval = 10,
        body: () throws -> T
    ) throws -> T {
        guard identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              timeout > 0 else {
            throw GuardError.invalidDisk
        }

        lock.lock()
        let inserted = activeDisks.insert(identifier).inserted
        lock.unlock()
        guard inserted else { throw GuardError.alreadyGuarded }
        defer {
            lock.lock()
            activeDisks.remove(identifier)
            lock.unlock()
        }

        let initialRegistryID: UInt64
        do {
            initialRegistryID = try DiskIdentity.registryID(identifier)
        } catch {
            throw GuardError.unavailable
        }

        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = identifier.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
              DADiskCopyDescription(disk) != nil else {
            throw GuardError.unavailable
        }

        let queue = DispatchQueue(label: "dev.rufus.mountguard." + UUID().uuidString)
        DASessionSetDispatchQueue(session, queue)

        let approvalContext = ApprovalContext(wholeIdentifier: identifier)
        let approvalOpaque = Unmanaged.passRetained(approvalContext).toOpaque()
        DARegisterDiskMountApprovalCallback(session, nil, approvalCallback, approvalOpaque)

        defer {
            DAUnregisterCallback(
                session,
                unsafeBitCast(approvalCallback, to: UnsafeMutableRawPointer.self),
                approvalOpaque
            )
            DASessionSetDispatchQueue(session, nil)
            queue.sync {}
            Unmanaged<ApprovalContext>.fromOpaque(approvalOpaque).release()
        }

        let unmountState = UnmountCompletion()
        let unmountOpaque = Unmanaged.passRetained(unmountState).toOpaque()
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, context in
            guard let context else { return }
            let completion = Unmanaged<UnmountCompletion>.fromOpaque(context).takeRetainedValue()
            if let dissenter {
                completion.dissenterStatus = DADissenterGetStatus(dissenter)
            }
            completion.semaphore.signal()
        }, unmountOpaque)

        guard unmountState.semaphore.wait(timeout: .now() + timeout) == .success else {
            throw GuardError.timedOut
        }
        if let status = unmountState.dissenterStatus {
            throw GuardError.unmountRejected(status)
        }
        guard (try? DiskIdentity.registryID(identifier)) == initialRegistryID else {
            throw GuardError.changed
        }

        return try body()
    }
}
