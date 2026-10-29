import Foundation

public enum WIMSplitter {
    public enum SplitError: Error {
        case invalidArguments, destinationNotEmpty, toolFailed(Int32, String), invalidOutput
    }

    /// Uses a caller-supplied wimlib-imagex. The caller owns dependency provenance.
    public static func split(input: URL, destination: URL, tool: URL, partSizeMiB: Int = 3800) throws {
        guard (1...4095).contains(partSizeMiB), input.isFileURL, destination.isFileURL, tool.isFileURL else { throw SplitError.invalidArguments }
        let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let dest = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              dest.isDirectory == true, dest.isSymbolicLink != true else { throw SplitError.invalidArguments }
        guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else { throw SplitError.destinationNotEmpty }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["split", input.path, destination.appendingPathComponent("install.swm").path, String(partSizeMiB), "--check"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SplitError.toolFailed(process.terminationStatus, String(decoding: data, as: UTF8.self)) }
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        guard files.contains(where: { $0.lastPathComponent == "install.swm" }),
              try files.allSatisfy({ file in
                  let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                  return file.pathExtension.lowercased() == "swm" && info.isRegularFile == true && (info.fileSize ?? 0) > 0 && UInt64(info.fileSize ?? 0) <= 4_294_967_295
              }) else { throw SplitError.invalidOutput }
    }
}
