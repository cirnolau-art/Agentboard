import AppKit
import UniformTypeIdentifiers

struct ConfigurationDocument: Codable {
    var schema = "agentboard.preferences.v1"
    var preferences: BoardPreferences
    init(_ preferences: BoardPreferences) {
        var safe = preferences
        safe.manualAccounts = []; safe.agentPaths = [:]; safe.ccPath = BoardPreferences().ccPath
        self.preferences = safe
    }
    func applying(to local: BoardPreferences, knownAccounts: Set<String>) throws -> BoardPreferences {
        guard schema == "agentboard.preferences.v1" else { throw ReaderError.message("不支持的配置版本") }
        var p = preferences
        guard p.themeOptions.valid, p.opacity.isFinite, (0.65...1).contains(p.opacity), p.fontScale.isFinite, (0.85...1.3).contains(p.fontScale),
              [3.0, 5, 10].contains(p.taskInterval), [15.0, 30, 60].contains(p.usageInterval), [300.0, 600, 1800].contains(p.balanceInterval),
              (0...23).contains(p.alertOptions.quietStart), (0...23).contains(p.alertOptions.quietEnd),
              p.alertOptions.thresholds.values.allSatisfy({ $0.amount.isFinite && $0.amount >= 0 && $0.unit.count <= 20 }),
              Set(p.moduleOrder) == Set(["usage", "balances", "tasks"]), p.moduleOrder.count == 3,
              p.hiddenModules.allSatisfy({ ["usage", "balances", "tasks"].contains($0) }),
              p.enabledAgents.allSatisfy({ AgentKind(rawValue: $0) != nil }), p.accountAliases.values.allSatisfy({ $0.count <= 120 }) else { throw ReaderError.message("配置包含无效的颜色、频率或阈值，未修改现有设置") }
        p.manualAccounts = local.manualAccounts; p.agentPaths = local.agentPaths; p.ccPath = local.ccPath
        p.selectedAccounts = p.selectedAccounts.filter { knownAccounts.contains($0) }
        p.enabledAgents = Array(Set(p.enabledAgents)).sorted()
        p.accountsInitialized = local.accountsInitialized; p.onboardingCompleted = true
        // Notification permission belongs to this Mac and is never imported.
        p.alertOptions.enabled = local.alertOptions.enabled
        p.floatVisible = local.floatVisible
        p.miniOptions.rotation = Array(Set(p.miniOptions.rotation ?? [])).sorted { $0.rawValue < $1.rawValue }
        p.miniOptions.rotationInterval = min(30, max(3, p.miniOptions.rotationInterval ?? 6))
        return p
    }
}
struct SanitizedDiagnostics: Codable {
    struct Health: Codable { var agent: String; var category: String; var available: Bool; var secondsSinceSuccess: Int?; var taskCount: Int }
    var version: String
    var build: String
    var generatedAt: Date
    var system: String
    var health: [Health]
    var usageAgeSeconds: Int?
    var accountCount: Int
    var statisticsAvailable: Bool
    init(snapshot: BoardSnapshot, now: Date = Date()) {
        version = BoardIdentity.version; build = BoardIdentity.build; generatedAt = now; system = ProcessInfo.processInfo.operatingSystemVersionString
        health = snapshot.health.map { h in Health(agent: h.agent.rawValue, category: (h.category ?? (h.available ? .connected : .unreadable)).rawValue, available: h.available, secondsSinceSuccess: h.lastSuccessAt.map { max(0, Int(now.timeIntervalSince($0))) }, taskCount: snapshot.tasks.filter { $0.agent == h.agent }.count) }
        usageAgeSeconds = snapshot.usageUpdatedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        accountCount = snapshot.accounts.count; statisticsAvailable = snapshot.statistics != nil
    }
}
enum AgentDetection {
    static func installed(_ preferences: BoardPreferences) -> [AgentKind] {
        AgentKind.allCases.filter { agent in
            let root = preferences.path(for: agent)
            switch agent {
            case .codex: return (try? CodexReader.databasePath(root: root, prefix: "state")) != nil
            case .workbuddy: return FileManager.default.fileExists(atPath: root + "/workbuddy.db")
            case .dsh: return FileManager.default.fileExists(atPath: root + "/sessions")
            case .qwen, .claude, .custom: return FileManager.default.fileExists(atPath: root)
            }
        }
    }
}
enum AgentNavigation {
    static func sessionURL(_ task: AgentTask) -> URL? {
        guard task.agent == .codex, task.id.hasPrefix("codex:"), UUID(uuidString: String(task.id.dropFirst(6))) != nil else { return nil }
        return URL(string: "codex://threads/" + String(task.id.dropFirst(6)))
    }
    @MainActor static func open(_ task: AgentTask) {
        if let url = sessionURL(task), NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url); return }
        if let path = task.sourcePath, FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        else if task.project.hasPrefix("/"), FileManager.default.fileExists(atPath: task.project) { NSWorkspace.shared.open(URL(fileURLWithPath: task.project)) }
    }
}
