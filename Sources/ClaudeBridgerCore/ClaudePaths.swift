import Foundation

/// Resolves every path ClaudeBridger reads or writes.
///
/// Claude Code relocates its whole configuration directory when `CLAUDE_CONFIG_DIR` is set, so
/// honouring it is both correct for the users who do that (the documented way to run two accounts
/// side by side) and the mechanism the test suite uses to run against a throwaway directory
/// instead of the real `~/.claude`.
public struct ClaudePaths: Equatable, Sendable {

    /// Claude Code's configuration directory, normally `~/.claude`.
    public let configDirectory: URL

    /// The user's home directory. `~/.claude.json` lives here, outside the config directory.
    public let homeDirectory: URL

    /// Overrides where `~/.claude.json` is read and written.
    ///
    /// The official docs describe the file as `~/.claude.json` and separately say that setting
    /// `CLAUDE_CONFIG_DIR` relocates "every `~/.claude` path". Whether the sibling file travels
    /// with the directory is not stated outright, so the documented home-directory location is
    /// the default here and this parameter exists so a caller who knows otherwise can say so.
    public let claudeJSONOverride: URL?

    public init(configDirectory: URL, homeDirectory: URL, claudeJSONOverride: URL? = nil) {
        self.configDirectory = configDirectory
        self.homeDirectory = homeDirectory
        self.claudeJSONOverride = claudeJSONOverride
    }

    /// Builds paths from the process environment, honouring `CLAUDE_CONFIG_DIR`.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.homeDirectory = home
        self.claudeJSONOverride = nil
        if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            self.configDirectory = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            self.configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        }
    }

    /// <config dir>/settings.json - the file the `env` block goes in.
    public var settingsJSON: URL {
        configDirectory.appendingPathComponent("settings.json")
    }

    /// ~/.claude.json - the global config file Claude Code writes for itself.
    public var claudeJSON: URL {
        if let override = claudeJSONOverride { return override }
        return homeDirectory.appendingPathComponent(".claude.json")
    }

    /// <config dir>/claudebridger/backup - ClaudeBridger's own backups.
    ///
    /// Deliberately not `<config dir>/backups`, which is where Claude Code keeps its own
    /// rotating `.claude.json.backup.<timestamp>` files. Two writers in one directory is how one
    /// of them ends up deleting the other's files.
    public var backupDirectory: URL {
        configDirectory
            .appendingPathComponent("claudebridger", isDirectory: true)
            .appendingPathComponent("backup", isDirectory: true)
    }

    /// <config dir>/claudebridger - ClaudeBridger's own persistence folder.
    public var appDirectory: URL {
        configDirectory.appendingPathComponent("claudebridger", isDirectory: true)
    }

    /// <config dir>/claudebridger/config.json
    public var appConfiguration: URL {
        appDirectory.appendingPathComponent("config.json")
    }

    /// The directory of a managed file, for reporting where a backup of it would go.
    public func isInsideConfigDirectory(_ url: URL) -> Bool {
        url.path.hasPrefix(configDirectory.path)
    }
}
