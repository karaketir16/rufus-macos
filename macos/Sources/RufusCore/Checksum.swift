// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

public enum Checksum {
    public enum Algorithm { case md5, sha1, sha256, sha512 }

    public static func digest(file: URL, algorithm: Algorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        switch algorithm {
        case .md5: return try hash(handle, Insecure.MD5())
        case .sha1: return try hash(handle, Insecure.SHA1())
        case .sha256: return try hash(handle, SHA256())
        case .sha512: return try hash(handle, SHA512())
        }
    }

    private static func hash<H: HashFunction>(_ handle: FileHandle, _ initial: H) throws -> String {
        var hasher = initial
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
