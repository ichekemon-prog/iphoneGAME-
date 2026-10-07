import Foundation

@main
struct PairingSetupTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent(PairingSetup.inboxName)
        let destination = root.appendingPathComponent("private/remote-pairing.plist")
        let fixture: [String: Any] = ["public_key": Data(repeating: 1, count: 32),
                                     "private_key": Data(repeating: 2, count: 32), "identifier": "test-only"]
        let valid = try PropertyListSerialization.data(fromPropertyList: fixture, format: .xml, options: 0)
        assert(PairingSetup.valid(valid))
        assert(!PairingSetup.valid(Data("not a plist".utf8)))
        let lockdownOnly = try PropertyListSerialization.data(fromPropertyList: ["HostID": "test"], format: .xml, options: 0)
        assert(!PairingSetup.valid(lockdownOnly))
        var shortKey = fixture
        shortKey["private_key"] = Data(repeating: 2, count: 31)
        let invalidKey = try PropertyListSerialization.data(fromPropertyList: shortKey, format: .xml, options: 0)
        assert(!PairingSetup.valid(invalidKey))
        assert(!PairingSetup.valid(Data(repeating: 0, count: PairingSetup.maximumBytes)))
        let absent = try PairingSetup.receive(inbox: inbox, destination: destination)
        assert(!absent)
        try Data("invalid".utf8).write(to: inbox)
        do { _ = try PairingSetup.receive(inbox: inbox, destination: destination); fatalError("Invalid input accepted") }
        catch { assert(!FileManager.default.fileExists(atPath: destination.path)) }
        try valid.write(to: inbox)
        let imported = try PairingSetup.receive(inbox: inbox, destination: destination)
        assert(imported)
        let saved = try Data(contentsOf: destination)
        assert(saved == valid)
        assert(!FileManager.default.fileExists(atPath: inbox.path))
        try Data("replacement".utf8).write(to: inbox)
        do { _ = try PairingSetup.receive(inbox: inbox, destination: destination); fatalError("Existing credential overwritten") }
        catch { let kept = try Data(contentsOf: destination); assert(kept == valid) }
        print("Pairing setup tests passed")
    }
}
