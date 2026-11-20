import Foundation

@main struct SandboxProbe {
    static func main() {
        guard let snapshot = SharedStorage.read(BoardSnapshot.self, name: "snapshot.json") else { print("FAIL: sandbox cannot read widget snapshot"); exit(1) }
        let outside = SharedStorage.userHome.appendingPathComponent(".cc-switch/cc-switch.db")
        let forbidden = try? Data(contentsOf: outside)
        guard forbidden == nil else { print("FAIL: sandbox can read outside the allowed directory"); exit(1) }
        print("PASS: sandbox read-only snapshot access (\(snapshot.accounts.count) accounts, \(snapshot.tasks.count) tasks)")
        print("PASS: agent database outside allowed directory is inaccessible")
        let testURL = SharedStorage.directory.appendingPathComponent("sandbox-write-test")
        do { try Data("test".utf8).write(to: testURL); print("FAIL: sandbox can write snapshot directory"); exit(1) }
        catch { print("PASS: sandbox cannot write snapshot directory") }
    }
}
