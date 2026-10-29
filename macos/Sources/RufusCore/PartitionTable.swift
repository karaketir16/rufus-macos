// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure-Swift GPT and MBR partition table generator matching upstream `src/drive.c` (`CreatePartition`).
/// Avoids macOS diskutil's automatic 200 MB EFI System Partition (`C12A7328-...`) on >= 2 GiB disks,
/// which causes Windows Setup to fail when two ESPs exist on the system.
public enum PartitionTable {
    public static let mbrUefiMarker: UInt32 = 0x49464555 // "UEFI" in little-endian (`MBR_UEFI_MARKER` in `src/rufus.h`)
    public static let gptNoDriveLetterAttribute: UInt64 = 0x8000_0000_0000_0000 // `GPT_BASIC_DATA_ATTRIBUTE_NO_DRIVE_LETTER`
    public static let microsoftBasicDataGUID = UUID(uuidString: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")!
    public static let efiSystemPartitionGUID = UUID(uuidString: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")!
    public static let linuxDataGUID = UUID(uuidString: "0FC63DAF-8483-4772-8E79-3D69D8477DE4")!

    public enum Scheme: Equatable {
        case gpt(diskGUID: UUID = UUID())
        case mbr(signature: UInt32 = mbrUefiMarker, bootable: Bool = true)
    }

    public enum FilesystemKind: Equatable {
        case fat32
        case exfat
        case ntfs
        case linuxExt
    }

    public struct PartitionDescriptor: Equatable {
        public let index: Int
        public let name: String
        public let firstLBA: UInt64
        public let lastLBA: UInt64
        public let typeGUID: UUID
        public let partitionGUID: UUID
        public let attributes: UInt64
        public let mbrType: UInt8
        public let bootable: Bool

        public var sectorCount: UInt64 { lastLBA - firstLBA + 1 }
    }

    public struct LayoutPlan: Equatable {
        public let scheme: Scheme
        public let blockSize: UInt64
        public let totalBlocks: UInt64
        public let partitions: [PartitionDescriptor]
        public let primaryRegion: Data
        public let backupRegionOffset: UInt64?
        public let backupRegion: Data?
        public let uefiNTFSOffset: UInt64?
    }

    public enum LayoutError: Error {
        case invalidGeometry
        case diskTooSmall
        case invalidExtraPartitionSize
    }

    public static func plan(
        scheme: Scheme,
        totalBytes: UInt64,
        blockSize: UInt64 = 512,
        filesystem: FilesystemKind = .fat32,
        uefiNTFSSizeBytes: UInt64 = 0
    ) throws -> LayoutPlan {
        guard blockSize >= 512, blockSize <= 4096, blockSize.nonzeroBitCount == 1,
              totalBytes >= 16 * 1024 * 1024, totalBytes % blockSize == 0 else {
            throw LayoutError.invalidGeometry
        }
        let totalBlocks = totalBytes / blockSize
        let oneMiBBlocks = (1024 * 1024) / blockSize
        guard uefiNTFSSizeBytes % blockSize == 0 else {
            throw LayoutError.invalidExtraPartitionSize
        }
        let uefiBlocks: UInt64 = uefiNTFSSizeBytes > 0
            ? ((uefiNTFSSizeBytes + (1024 * 1024 - 1)) / (1024 * 1024)) * oneMiBBlocks
            : 0

        let firstUsableLBA = oneMiBBlocks
        let gptEntriesBytes: UInt64 = 128 * 128
        let gptEntriesBlocks = (gptEntriesBytes + blockSize - 1) / blockSize
        let reservedTailBlocks: UInt64
        switch scheme {
        case .gpt:
            reservedTailBlocks = gptEntriesBlocks + 1
        case .mbr:
            reservedTailBlocks = 0
        }
        guard totalBlocks > firstUsableLBA + reservedTailBlocks + uefiBlocks + oneMiBBlocks else {
            throw LayoutError.diskTooSmall
        }
        let lastUsableLBA = totalBlocks - reservedTailBlocks - 1
        let alignedLimitBlocks = ((lastUsableLBA + 1) / oneMiBBlocks) * oneMiBBlocks
        guard alignedLimitBlocks > firstUsableLBA + uefiBlocks else {
            throw LayoutError.diskTooSmall
        }

        let mainFirstLBA = firstUsableLBA
        let mainLastLBA = alignedLimitBlocks - uefiBlocks - 1
        let mainMBRType: UInt8
        let mainTypeGUID: UUID
        switch filesystem {
        case .fat32:
            mainMBRType = 0x0C
            mainTypeGUID = microsoftBasicDataGUID
        case .exfat, .ntfs:
            mainMBRType = 0x07
            mainTypeGUID = microsoftBasicDataGUID
        case .linuxExt:
            mainMBRType = 0x83
            mainTypeGUID = linuxDataGUID
        }

        let isBootableMBR: Bool
        if case .mbr(_, let bootable) = scheme {
            isBootableMBR = bootable
        } else {
            isBootableMBR = false
        }

        var partitions: [PartitionDescriptor] = [
            PartitionDescriptor(
                index: 1,
                name: "Main Data Partition",
                firstLBA: mainFirstLBA,
                lastLBA: mainLastLBA,
                typeGUID: mainTypeGUID,
                partitionGUID: UUID(),
                attributes: 0,
                mbrType: mainMBRType,
                bootable: isBootableMBR
            )
        ]

        var uefiOffset: UInt64?
        if uefiBlocks > 0 {
            let uefiFirstLBA = mainLastLBA + 1
            let uefiLastLBA = uefiFirstLBA + uefiBlocks - 1
            uefiOffset = uefiFirstLBA * blockSize
            partitions.append(
                PartitionDescriptor(
                    index: 2,
                    name: "UEFI:NTFS",
                    firstLBA: uefiFirstLBA,
                    lastLBA: uefiLastLBA,
                    typeGUID: microsoftBasicDataGUID,
                    partitionGUID: UUID(),
                    attributes: gptNoDriveLetterAttribute,
                    mbrType: 0xEF,
                    bootable: false
                )
            )
        }

        switch scheme {
        case .mbr(let signature, _):
            let mbr = buildMBR(blockSize: Int(blockSize), signature: signature, partitions: partitions)
            return LayoutPlan(
                scheme: scheme,
                blockSize: blockSize,
                totalBlocks: totalBlocks,
                partitions: partitions,
                primaryRegion: mbr,
                backupRegionOffset: nil,
                backupRegion: nil,
                uefiNTFSOffset: uefiOffset
            )
        case .gpt(let diskGUID):
            let protectiveMBR = buildProtectiveMBR(blockSize: Int(blockSize), totalBlocks: totalBlocks)
            let entriesData = buildGPTEntries(partitions: partitions, paddedBytes: Int(gptEntriesBlocks * blockSize))
            let entriesCRC = crc32(entriesData.prefix(Int(gptEntriesBytes)))
            let primaryHeader = buildGPTHeader(
                blockSize: Int(blockSize),
                myLBA: 1,
                alternateLBA: totalBlocks - 1,
                firstUsableLBA: firstUsableLBA,
                lastUsableLBA: lastUsableLBA,
                diskGUID: diskGUID,
                entriesStartLBA: 2,
                entriesCRC: entriesCRC
            )
            let backupEntriesLBA = totalBlocks - 1 - gptEntriesBlocks
            let backupHeader = buildGPTHeader(
                blockSize: Int(blockSize),
                myLBA: totalBlocks - 1,
                alternateLBA: 1,
                firstUsableLBA: firstUsableLBA,
                lastUsableLBA: lastUsableLBA,
                diskGUID: diskGUID,
                entriesStartLBA: backupEntriesLBA,
                entriesCRC: entriesCRC
            )
            var primary = Data()
            primary.append(protectiveMBR)
            primary.append(primaryHeader)
            primary.append(entriesData)

            var backup = Data()
            backup.append(entriesData)
            backup.append(backupHeader)

            return LayoutPlan(
                scheme: scheme,
                blockSize: blockSize,
                totalBlocks: totalBlocks,
                partitions: partitions,
                primaryRegion: primary,
                backupRegionOffset: backupEntriesLBA * blockSize,
                backupRegion: backup,
                uefiNTFSOffset: uefiOffset
            )
        }
    }

    private static func buildProtectiveMBR(blockSize: Int, totalBlocks: UInt64) -> Data {
        var mbr = Data(count: blockSize)
        mbr[446] = 0x00
        mbr[447] = 0x00
        mbr[448] = 0x02
        mbr[449] = 0x00
        mbr[450] = 0xEE
        mbr[451] = 0xFF
        mbr[452] = 0xFF
        mbr[453] = 0xFF
        putUInt32LE(&mbr, offset: 454, value: 1)
        let clampedSectors = UInt32(min(totalBlocks - 1, UInt64(UInt32.max)))
        putUInt32LE(&mbr, offset: 458, value: clampedSectors)
        mbr[510] = 0x55
        mbr[511] = 0xAA
        return mbr
    }

    private static func buildMBR(blockSize: Int, signature: UInt32, partitions: [PartitionDescriptor]) -> Data {
        var mbr = Data(count: blockSize)
        putUInt32LE(&mbr, offset: 440, value: signature)
        for (idx, part) in partitions.prefix(4).enumerated() {
            let base = 446 + idx * 16
            mbr[base] = part.bootable ? 0x80 : 0x00
            mbr[base + 1] = 0xFE
            mbr[base + 2] = 0xFF
            mbr[base + 3] = 0xFF
            mbr[base + 4] = part.mbrType
            mbr[base + 5] = 0xFE
            mbr[base + 6] = 0xFF
            mbr[base + 7] = 0xFF
            putUInt32LE(&mbr, offset: base + 8, value: UInt32(clamping: part.firstLBA))
            putUInt32LE(&mbr, offset: base + 12, value: UInt32(clamping: part.sectorCount))
        }
        mbr[510] = 0x55
        mbr[511] = 0xAA
        return mbr
    }

    private static func buildGPTEntries(partitions: [PartitionDescriptor], paddedBytes: Int) -> Data {
        var data = Data(count: paddedBytes)
        for (idx, part) in partitions.prefix(128).enumerated() {
            let base = idx * 128
            let typeBytes = uuidToMixedEndianBytes(part.typeGUID)
            let partBytes = uuidToMixedEndianBytes(part.partitionGUID)
            data.replaceSubrange(base..<(base + 16), with: typeBytes)
            data.replaceSubrange((base + 16)..<(base + 32), with: partBytes)
            putUInt64LE(&data, offset: base + 32, value: part.firstLBA)
            putUInt64LE(&data, offset: base + 40, value: part.lastLBA)
            putUInt64LE(&data, offset: base + 48, value: part.attributes)
            let utf16 = Array(part.name.utf16.prefix(36))
            for (charIndex, codeUnit) in utf16.enumerated() {
                let pos = base + 56 + charIndex * 2
                data[pos] = UInt8(truncatingIfNeeded: codeUnit)
                data[pos + 1] = UInt8(truncatingIfNeeded: codeUnit >> 8)
            }
        }
        return data
    }

    private static func buildGPTHeader(
        blockSize: Int,
        myLBA: UInt64,
        alternateLBA: UInt64,
        firstUsableLBA: UInt64,
        lastUsableLBA: UInt64,
        diskGUID: UUID,
        entriesStartLBA: UInt64,
        entriesCRC: UInt32
    ) -> Data {
        var header = Data(count: blockSize)
        header.replaceSubrange(0..<8, with: Data("EFI PART".utf8))
        putUInt32LE(&header, offset: 8, value: 0x0001_0000)
        putUInt32LE(&header, offset: 12, value: 92)
        putUInt32LE(&header, offset: 16, value: 0)
        putUInt32LE(&header, offset: 20, value: 0)
        putUInt64LE(&header, offset: 24, value: myLBA)
        putUInt64LE(&header, offset: 32, value: alternateLBA)
        putUInt64LE(&header, offset: 40, value: firstUsableLBA)
        putUInt64LE(&header, offset: 48, value: lastUsableLBA)
        header.replaceSubrange(56..<72, with: uuidToMixedEndianBytes(diskGUID))
        putUInt64LE(&header, offset: 72, value: entriesStartLBA)
        putUInt32LE(&header, offset: 80, value: 128)
        putUInt32LE(&header, offset: 84, value: 128)
        putUInt32LE(&header, offset: 88, value: entriesCRC)
        let headerCRC = crc32(header.prefix(92))
        putUInt32LE(&header, offset: 16, value: headerCRC)
        return header
    }

    public static func uuidToMixedEndianBytes(_ uuid: UUID) -> Data {
        let u = uuid.uuid
        return Data([
            u.3, u.2, u.1, u.0,
            u.5, u.4,
            u.7, u.6,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
        ])
    }

    public static func crc32<D: DataProtocol>(_ data: D) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }

    private static func putUInt32LE(_ data: inout Data, offset: Int, value: UInt32) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func putUInt64LE(_ data: inout Data, offset: Int, value: UInt64) {
        for i in 0..<8 {
            data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8))
        }
    }
}
