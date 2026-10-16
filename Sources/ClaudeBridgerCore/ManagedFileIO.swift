import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Atomic file writes.
///
/// Every file Claude Code reads is written to a sibling temporary file and then renamed over the
/// destination. rename(2) is atomic within a filesystem, so a crash or a kill mid-write can never
/// leave Claude Code with a half-written settings.json — which it would refuse to load, taking
/// the user's permissions and hooks down with it.
public enum AtomicFile {
    public enum WriteError: Error, LocalizedError {
        case renameFailed(path: String, errno: Int32)

        public var errorDescription: String? {
            switch self {
            case let .renameFailed(path, code):
                return "原子重命名失败：" + path + "（errno " + String(code) + "）"
            }
        }
    }

    @discardableResult
    public static func write(_ data: Data, to destination: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(
            "." + destination.lastPathComponent + ".tmp-" + UUID().uuidString
        )
        do {
            try data.write(to: temp, options: [])
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
        // Flush to disk before the rename so the rename cannot publish an empty file.
        if let handle = try? FileHandle(forWritingTo: temp) {
            try? handle.synchronize()
            try? handle.close()
        }
        if rename(temp.path, destination.path) != 0 {
            let code = errno
            try? fileManager.removeItem(at: temp)
            if code == EEXIST || code == ENOTEMPTY {
                try? fileManager.removeItem(at: destination)
                if rename(temp.path, destination.path) == 0 { return destination }
            }
            throw WriteError.renameFailed(path: destination.path, errno: code)
        }
        return destination
    }

    @discardableResult
    public static func write(_ string: String, to destination: URL, fileManager: FileManager = .default) throws -> URL {
        try write(Data(string.utf8), to: destination, fileManager: fileManager)
    }
}

/// Which managed file a backup covers. The two differ in name and in extension.
public enum BackupKind: String, Sendable {
    /// settings.json, which holds the `env` block.
    case settings
    /// ~/.claude.json, which holds the onboarding flag and the app's own state.
    case globalConfig

    var stem: String {
        switch self {
        case .settings: return "settings"
        case .globalConfig: return "claude-json"
        }
    }

    var fileExtension: String { "json" }
}

/// Creates the timestamped backups ClaudeBridger takes before touching a file Claude Code reads.
///
/// Layout: `<config dir>/claudebridger/backup/settings-<profile>-yyyy-MM-dd-HHmm-bak.json`. The
/// profile segment names the backend the file held, so a backup is identifiable without opening
/// it. The timestamp resolves to the minute, so a second backup inside the same minute is
/// disambiguated with a numeric suffix and an earlier backup is never overwritten.
public struct BackupManager {
    public let paths: ClaudePaths
    public let fileManager: FileManager

    public init(paths: ClaudePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    /// Placeholder for a file that names no backend at all, e.g. a hand-written settings.json.
    /// Keeps the filename shape identical either way.
    public static let unknownProfileSegment = "unknown"

    public static func backupFileName(
        kind: BackupKind,
        profile: String,
        date: Date,
        sequence: Int = 1
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: date)
        let suffix = sequence <= 1 ? "" : "-" + String(sequence)
        let segment = sanitizedProfileSegment(profile)
        return kind.stem + "-" + segment + "-" + stamp + "-bak" + suffix + "." + kind.fileExtension
    }

    /// Reduces a profile id to characters safe inside a filename, so a name can never inject a
    /// path separator or a newline into the backup filename.
    static func sanitizedProfileSegment(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unknownProfileSegment }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? unknownProfileSegment : cleaned
    }

    /// Copies `source` into the backup directory. Returns nil when the source does not exist yet,
    /// which is the normal case on a fresh machine.
    @discardableResult
    public func backup(
        _ source: URL,
        kind: BackupKind,
        profile: String = BackupManager.unknownProfileSegment,
        now: Date = Date()
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        try fileManager.createDirectory(at: paths.backupDirectory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: source)

        var sequence = 1
        var target = paths.backupDirectory.appendingPathComponent(
            BackupManager.backupFileName(kind: kind, profile: profile, date: now, sequence: sequence)
        )
        while fileManager.fileExists(atPath: target.path) {
            sequence += 1
            target = paths.backupDirectory.appendingPathComponent(
                BackupManager.backupFileName(kind: kind, profile: profile, date: now, sequence: sequence)
            )
        }
        try AtomicFile.write(data, to: target, fileManager: fileManager)
        return target
    }

    /// Every backup currently on disk, newest first.
    public func listBackups() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }
}
