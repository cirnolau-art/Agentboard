import Foundation

enum BoardIdentity {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    static var author: String { Bundle.main.object(forInfoDictionaryKey: "AgentBoardAuthor") as? String ?? "Lau Kachun" }
    static var copyright: String { Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 Lau Kachun. All rights reserved." }
    static var title: String { "AgentBoard v" + version }
}
