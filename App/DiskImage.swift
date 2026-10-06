import Foundation

/// Developer Disk Image (personalized, iOS 17+) used to restore the developer
/// services after a reboot. The files are Apple's; they are downloaded on the
/// device at runtime and never bundled or uploaded anywhere.
enum DiskImage {
    static let names = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"]
    static let base = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DDI", isDirectory: true)
    }

    static var ready: Bool {
        names.allSatisfy { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0
            return size > 0
        }
    }

    static func download() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            guard let url = URL(string: base + name) else { continue }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "\(name) を取得できません"])
            }
            let destination = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        }
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}
