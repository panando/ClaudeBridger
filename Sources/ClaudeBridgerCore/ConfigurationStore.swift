import Foundation

/// Persists ClaudeBridger's own state under `<config dir>/claudebridger/config.json`.
///
/// The location is deliberate: it lives beside the Claude Code files it manages, so a
/// `CLAUDE_CONFIG_DIR` override keeps the app state and the managed config in step, and a user can
/// back up or move one folder.
///
/// Credentials are **not** stored here. See `CredentialStore`.
public final class ConfigurationStore: @unchecked Sendable {
    public let paths: ClaudePaths
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(paths: ClaudePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public var configurationExists: Bool {
        fileManager.fileExists(atPath: paths.appConfiguration.path)
    }

    public enum StoreError: Error, LocalizedError {
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .decodingFailed(message):
                return "无法解析已保存的 ClaudeBridger 配置：" + message
            }
        }
    }

    /// Loads the saved configuration, or an empty one on a fresh install.
    public func load() throws -> ClaudeBridgerConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: paths.appConfiguration.path) else {
            return ClaudeBridgerConfiguration()
        }
        let data = try Data(contentsOf: paths.appConfiguration)
        if data.isEmpty { return ClaudeBridgerConfiguration() }
        do {
            return try JSONDecoder().decode(ClaudeBridgerConfiguration.self, from: data)
        } catch {
            // Never silently discard user data; surface it so the UI can warn.
            throw StoreError.decodingFailed(error.localizedDescription)
        }
    }

    public func save(_ configuration: ClaudeBridgerConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(Data("\n".utf8))
        try AtomicFile.write(data, to: paths.appConfiguration, fileManager: fileManager)
    }
}
