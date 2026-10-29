import Foundation
import Observation

/// App-wide preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var autoFetchEnabled: Bool { didSet { defaults.set(autoFetchEnabled, forKey: "autoFetchEnabled") } }
    var autoFetchMinutes: Int { didSet { defaults.set(autoFetchMinutes, forKey: "autoFetchMinutes") } }
    var showWhitespaceChanges: Bool { didSet { defaults.set(showWhitespaceChanges, forKey: "showWhitespaceChanges") } }
    var syntaxHighlighting: Bool { didSet { defaults.set(syntaxHighlighting, forKey: "syntaxHighlighting") } }
    var signCommits: Bool { didSet { defaults.set(signCommits, forKey: "signCommits") } }
    var diffFontSize: Double { didSet { defaults.set(diffFontSize, forKey: "diffFontSize") } }
    var externalDiffTool: String { didSet { defaults.set(externalDiffTool, forKey: "externalDiffTool") } }
    var profiles: [UserProfile] { didSet { save(profiles, key: "profiles") } }
    var commitTemplates: [CommitTemplate] { didSet { save(commitTemplates, key: "commitTemplates") } }
    var environmentVariables: [EnvironmentVariable] { didSet { save(environmentVariables, key: "environmentVariables"); GitRunner.extraEnvironment = Dictionary(uniqueKeysWithValues: environmentVariables.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }) } }
    var gitmojiEnabled: Bool { didSet { defaults.set(gitmojiEnabled, forKey: "gitmojiEnabled") } }
    var contextLines: Int { didSet { defaults.set(contextLines, forKey: "contextLines") } }

    private let defaults = UserDefaults.standard

    private init() {
        autoFetchEnabled = defaults.object(forKey: "autoFetchEnabled") as? Bool ?? true
        autoFetchMinutes = max(1, defaults.object(forKey: "autoFetchMinutes") as? Int ?? 10)
        showWhitespaceChanges = defaults.object(forKey: "showWhitespaceChanges") as? Bool ?? true
        syntaxHighlighting = defaults.object(forKey: "syntaxHighlighting") as? Bool ?? true
        signCommits = defaults.bool(forKey: "signCommits")
        diffFontSize = defaults.object(forKey: "diffFontSize") as? Double ?? 12
        externalDiffTool = defaults.string(forKey: "externalDiffTool") ?? ""
        gitmojiEnabled = defaults.object(forKey: "gitmojiEnabled") as? Bool ?? false
        contextLines = defaults.object(forKey: "contextLines") as? Int ?? 3
        profiles = Self.load([UserProfile].self, key: "profiles") ?? []
        commitTemplates = Self.load([CommitTemplate].self, key: "commitTemplates") ?? []
        environmentVariables = Self.load([EnvironmentVariable].self, key: "environmentVariables") ?? []
        GitRunner.extraEnvironment = Dictionary(uniqueKeysWithValues: environmentVariables.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) })
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct EnvironmentVariable: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var key: String
    var value: String
}

enum Gitmoji {
    static let all: [(emoji: String, code: String, description: String)] = [
        ("✨", ":sparkles:", "Introduce new features"),
        ("🐛", ":bug:", "Fix a bug"),
        ("📝", ":memo:", "Add or update documentation"),
        ("🎨", ":art:", "Improve structure / format of the code"),
        ("⚡️", ":zap:", "Improve performance"),
        ("🔥", ":fire:", "Remove code or files"),
        ("🚑️", ":ambulance:", "Critical hotfix"),
        ("🚀", ":rocket:", "Deploy stuff"),
        ("💄", ":lipstick:", "Add or update the UI and style files"),
        ("🎉", ":tada:", "Begin a project"),
        ("✅", ":white_check_mark:", "Add, update, or pass tests"),
        ("🔒️", ":lock:", "Fix security issues"),
        ("🔖", ":bookmark:", "Release / version tags"),
        ("🚨", ":rotating_light:", "Fix compiler / linter warnings"),
        ("🚧", ":construction:", "Work in progress"),
        ("💚", ":green_heart:", "Fix CI build"),
        ("⬇️", ":arrow_down:", "Downgrade dependencies"),
        ("⬆️", ":arrow_up:", "Upgrade dependencies"),
        ("📌", ":pushpin:", "Pin dependencies to specific versions"),
        ("👷", ":construction_worker:", "Add or update CI build system"),
        ("♻️", ":recycle:", "Refactor code"),
        ("➕", ":heavy_plus_sign:", "Add a dependency"),
        ("➖", ":heavy_minus_sign:", "Remove a dependency"),
        ("🔧", ":wrench:", "Add or update configuration files"),
        ("🔨", ":hammer:", "Add or update development scripts"),
        ("🌐", ":globe_with_meridians:", "Internationalization and localization"),
        ("✏️", ":pencil2:", "Fix typos"),
        ("⏪️", ":rewind:", "Revert changes"),
        ("🔀", ":twisted_rightwards_arrows:", "Merge branches"),
        ("📦️", ":package:", "Add or update compiled files or packages"),
        ("🚚", ":truck:", "Move or rename resources"),
        ("💡", ":bulb:", "Add or update comments in source code"),
        ("🗑️", ":wastebasket:", "Deprecate code that needs to be cleaned up"),
        ("🧪", ":test_tube:", "Add a failing test"),
        ("🩹", ":adhesive_bandage:", "Simple fix for a non-critical issue"),
    ]
}
