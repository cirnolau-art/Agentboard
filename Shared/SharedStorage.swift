import Foundation
import Darwin

enum SharedStorage {
    static let group = "group.local.agentboard"
    static let widgetKind = "AgentBoardWidget"
    static var userHome: URL {
        if let path = getpwuid(getuid())?.pointee.pw_dir { return URL(fileURLWithPath: String(cString: path), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var directory: URL {
        #if APP_GROUP_DISTRIBUTION
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) { return container }
        #endif
        return localDirectory.appendingPathComponent("WidgetData", isDirectory: true)
    }
    static var localDirectory: URL { userHome.appendingPathComponent("Library/Application Support/AgentBoard", isDirectory: true) }
    static func read<T: Decodable>(_ type: T.Type, name: String, directory: URL = directory) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, name: String, directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
