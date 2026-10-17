import Foundation
import XCTest
@testable import ClaudeBridgerCore

/// A throwaway Claude Code home for one test.
///
/// Everything is built under a temporary directory so no test can touch the real `~/.claude`.
struct TestHome {
    let root: URL
    let home: URL
    let configDirectory: URL
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claudebridger-tests-" + UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.root = base
        self.home = base.appendingPathComponent("home", isDirectory: true)
        self.configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try? fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        // The app's own folder, so a test can write to `appConfiguration` directly without every
        // one of them having to remember to create it.
        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
    }

    var appDirectory: URL {
        configDirectory.appendingPathComponent("claudebridger", isDirectory: true)
    }

    var paths: ClaudePaths {
        ClaudePaths(configDirectory: configDirectory, homeDirectory: home)
    }

    var settingsURL: URL { paths.settingsJSON }
    var claudeJSONURL: URL { paths.claudeJSON }

    func write(settings: String) {
        try? settings.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    func write(claudeJSON: String) {
        try? claudeJSON.write(to: claudeJSONURL, atomically: true, encoding: .utf8)
    }

    func read(settings: String? = nil) -> String {
        (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""
    }

    func readClaudeJSON() -> String {
        (try? String(contentsOf: claudeJSONURL, encoding: .utf8)) ?? ""
    }

    /// Parses a written file with the system parser, so a test can assert on real validity rather
    /// than on the writer agreeing with itself.
    func parseJSON(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            XCTFail("not utf8", file: file, line: line)
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            XCTFail("written file is not valid JSON: \(error)\n\(text)", file: file, line: line)
            return nil
        }
    }

    func environment(in text: String) -> [String: String] {
        guard let root = parseJSON(text), let env = root["env"] as? [String: String] else { return [:] }
        return env
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }
}

/// A profile wired the way the DeepSeek preset does it, for tests that need one.
func makeProfile(
    id: String = "deepseek",
    name: String = "DeepSeek",
    baseURL: String = "https://api.deepseek.com/anthropic"
) -> BackendProfile {
    var profile = BackendProfile(id: id, name: name, baseURL: baseURL)
    profile.setModel("deepseek-v4-pro[1m]", for: .primary)
    profile.setModel("deepseek-v4-flash", for: .haiku)
    profile.contextWindow = 1_048_576
    // Mirrors what a preset produces: the third-party traffic switch is on.
    //
    // A bare `BackendProfile` starts with no flags — the app should not switch on a behaviour the
    // user did not ask for. It is the preset, which stands for "make this backend work", that
    // turns this one on; this helper stands in for that preset.
    profile.setFlag(.disableNonessentialTraffic, on: true)
    profile.effortLevel = .max
    return profile
}
