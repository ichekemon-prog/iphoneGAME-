import Foundation

/// USB setup uses Documents only as an inbox. The active credential stays private.
enum PairingSetup {
    static let inboxName = "phone-runner-pairing.plist"
    static let maximumBytes = 1_048_576

    static func valid(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count < maximumBytes,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = value as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String, !identifier.isEmpty else { return false }
        return true
    }

    /// Returns false if there is nothing to import. Never replaces an existing file.
    static func receive(inbox: URL, destination: URL) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: inbox.path) else { return false }
        guard !manager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let attributes = try manager.attributesOfItem(atPath: inbox.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue < maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: inbox)
        guard valid(data) else { throw CocoaError(.fileReadCorruptFile) }
        var directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #if os(iOS)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: destination, options: .atomic)
        #endif
        // If cleanup fails, report it to the caller instead of claiming completion.
        try manager.removeItem(at: inbox)
        return true
    }
}
