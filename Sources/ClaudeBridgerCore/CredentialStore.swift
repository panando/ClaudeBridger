import Foundation

/// Stores the credentials that belong to each profile.
///
/// ## Why not the Keychain
///
/// The Keychain is the obvious home for a secret, but this app is distributed with an ad-hoc
/// signature and no notarisation. On macOS an unsigned binary reading a Keychain item triggers an
/// access prompt whose "Always Allow" grant is keyed to a code signature that changes on every
/// rebuild, so the user would be re-approving on every update. That is a worse experience than the
/// problem it solves.
///
/// ## What this does instead
///
/// `<config dir>/claudebridger/credentials.json`, created with mode 0600 so only the owning user
/// can read it. This is not a strong secret store and the code does not pretend it is: an attacker
/// who can read the user's files can read this. The point is that it is *not* the main settings
/// file, so it does not end up in a repository the user commits, in a project-scoped settings file
/// shared with a team, or in one of the many screenshots a settings app gets pasted into.
///
/// Worth stating plainly: `ANTHROPIC_AUTH_TOKEN` ends up in Claude Code's `settings.json` as
/// plaintext regardless, because that is the file Claude Code reads. The official documentation
/// warns about exactly this. ClaudeBridger cannot make that file secret; it can refrain from
/// making a second copy somewhere less expected.
public final class CredentialStore: @unchecked Sendable {

    private struct Payload: Codable {
        var credentials: [String: String]
    }

    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: [String: String]?
    /// When true the store keeps everything in `cache` and never touches the filesystem.
    private let isInMemory: Bool

    public enum StoreError: Error, LocalizedError {
        case decodingFailed(String)
        case insecurePermissions(path: String, mode: Int)

        public var errorDescription: String? {
            switch self {
            case let .decodingFailed(message):
                return "无法解析已保存的凭据文件：" + message
            case let .insecurePermissions(path, mode):
                return "凭据文件权限过于宽松（" + String(mode, radix: 8) + "）：" + path
            }
        }
    }

    public init(
        paths: ClaudePaths,
        fileManager: FileManager = .default,
        isInMemory: Bool = false
    ) {
        self.url = paths.appDirectory.appendingPathComponent("credentials.json")
        self.fileManager = fileManager
        self.isInMemory = isInMemory
        if isInMemory { self.cache = [:] }
    }

    /// An in-memory store, for tests and for a session that must not touch disk.
    public static func inMemory() -> CredentialStore {
        CredentialStore(
            paths: ClaudePaths(
                configDirectory: URL(fileURLWithPath: "/dev/null/unused"),
                homeDirectory: URL(fileURLWithPath: "/dev/null/unused")
            ),
            fileManager: .default,
            isInMemory: true
        )
    }

    /// The permission bits every credential file must have. Group and other get nothing.
    public static let requiredMode: mode_t = 0o600

    public func credential(forProfile id: String) -> String? {
        load()[id]
    }

    public func setCredential(_ value: String?, forProfile id: String) throws {
        var values = load()
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            values[id] = trimmed
        } else {
            values.removeValue(forKey: id)
        }
        try persist(values)
    }

    /// Drops credentials for profiles that no longer exist, so deleting a profile does not leave
    /// its key on disk forever.
    public func prune(keeping ids: Set<String>) throws {
        var values = load()
        let before = values.count
        values = values.filter { ids.contains($0.key) }
        if values.count != before {
            try persist(values)
        }
    }

    // MARK: - Disk

    private func load() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        guard fileManager.fileExists(atPath: url.path) else {
            cache = [:]
            return [:]
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            cache = [:]
            return [:]
        }
        let decoded = (try? JSONDecoder().decode(Payload.self, from: data))?.credentials ?? [:]
        cache = decoded
        return decoded
    }

    private func persist(_ values: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
        if isInMemory {
            cache = values
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Payload(credentials: values))
        data.append(Data("\n".utf8))
        try AtomicFile.write(data, to: url, fileManager: fileManager)
        // The write above creates the file with the process umask, which is usually 0644. Narrow
        // it to owner-only after the fact; a create with the right mode would still be widened by
        // the umask, so the chmod is the part that actually matters.
        try? fileManager.setAttributes([.posixPermissions: NSNumber(value: Self.requiredMode)], ofItemAtPath: url.path)
        cache = values
    }

    /// Whether the credential file is currently readable by anyone but its owner.
    public func hasInsecurePermissions() -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let mode = attributes[.posixPermissions] as? NSNumber else { return false }
        return (mode.intValue & 0o077) != 0
    }
}
