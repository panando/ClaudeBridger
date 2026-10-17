import Foundation

/// What a settings.json currently says, as far as ClaudeBridger is concerned.
public struct SettingsSnapshot: Equatable, Sendable {
    public var fileExists: Bool
    /// Value of `env.ANTHROPIC_BASE_URL`, when present.
    public var baseURL: String?
    /// Every model-tier variable currently set.
    public var models: [String: String]
    /// Display labels currently set, for the tiers that have a display-name variable.
    public var modelDisplayNames: [String: String]
    /// Keys from `ManagedEnvironment.clearableKeys` present in `env`.
    public var managedKeysPresent: Set<String>
    /// How many keys the `env` object holds in total, so the screen can say what it is not touching.
    public var totalEnvironmentKeys: Int
    /// True when the file could not be parsed. A parse failure is reported, never overwritten.
    public var isUnparseable: Bool
    /// Why parsing failed, when it did, so the message can name the offending character.
    public var parseErrorMessage: String?
    /// True when `env` exists but is not an object.
    public var environmentIsNotAnObject: Bool
    /// Whether `~/.claude.json` carries `hasCompletedOnboarding: true`.
    public var hasCompletedOnboarding: Bool

    public var isEmpty: Bool { !fileExists }
}

/// Turns an activated profile into the files Claude Code reads.
///
/// Order of operations is deliberate, and mirrors the safety rules ClaudeBridger promises:
///
/// 1. **Refuse before writing.** An unparseable settings.json, or an `env` that is not an object,
///    stops the write. Both mean the file holds something ClaudeBridger does not understand, and
///    the one thing that must never happen is that a tool "repairs" a user's config by discarding
///    the parts it could not read.
/// 2. **Back up first, always.** Every activation copies the current files aside, including when
///    switching between two profiles this app manages. Backing up only for "foreign" configs is
///    how the one destructive action ends up as the only one with no way back.
/// 3. **Touch only managed keys.** The `env` object is edited member by member. A user's
///    `HTTPS_PROXY` or `API_TIMEOUT_MS` survives, because it is never named.
/// 4. **Write atomically**, then **read back** and compare, so "saved" means "verified on disk"
///    rather than "the call returned".
public struct ClaudeSettingsWriter: @unchecked Sendable {
    public let paths: ClaudePaths
    public let fileManager: FileManager
    public let now: () -> Date

    public init(
        paths: ClaudePaths,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.now = now
    }

    public enum WriterError: Error, LocalizedError, Equatable {
        case settingsFileUnparseable(String)
        case environmentNotAnObject
        case emptyBaseURL
        case missingCredential(CredentialMode)

        public var errorDescription: String? {
            switch self {
            case let .settingsFileUnparseable(message):
                return "settings.json 无法解析，已停止写入以免覆盖你的配置：" + message
            case .environmentNotAnObject:
                return "settings.json 里的 env 不是一个对象，已停止写入以免覆盖你的配置"
            case .emptyBaseURL:
                return "还没有填写 base_url"
            case let .missingCredential(mode):
                return mode == .none ? "" : "还没有填写凭据"
            }
        }
    }

    /// What an activation did. Tests assert on these strings instead of re-reading the files.
    public struct ActivationResult: Equatable, Sendable {
        public var profileID: String
        public var settingsURL: URL
        public var globalConfigURL: URL
        public var backupSettingsURL: URL?
        public var backupGlobalConfigURL: URL?
        /// Problems the user has to know about; these keep the action bar's message on screen.
        public var warnings: [String]
        public var settingsJSON: String
        public var globalConfigJSON: String?
        /// True when the onboarding flag had to be added or corrected.
        public var wroteOnboardingFlag: Bool
    }

    // MARK: - Reading

    /// Reads the current state without modifying anything.
    public func snapshot() -> SettingsSnapshot {
        var snapshot = SettingsSnapshot(
            fileExists: false,
            baseURL: nil,
            models: [:],
            modelDisplayNames: [:],
            managedKeysPresent: [],
            totalEnvironmentKeys: 0,
            isUnparseable: false,
            parseErrorMessage: nil,
            environmentIsNotAnObject: false,
            hasCompletedOnboarding: false
        )
        snapshot.hasCompletedOnboarding = readOnboardingFlag()
        guard fileManager.fileExists(atPath: paths.settingsJSON.path) else { return snapshot }
        snapshot.fileExists = true
        guard let data = try? Data(contentsOf: paths.settingsJSON),
              let text = String(data: data, encoding: .utf8) else {
            snapshot.isUnparseable = true
            snapshot.parseErrorMessage = "文件不是 UTF-8 文本"
            return snapshot
        }
        let document: JSONDocument
        do {
            document = try JSONDocument(source: text)
        } catch {
            snapshot.isUnparseable = true
            snapshot.parseErrorMessage = error.localizedDescription
            return snapshot
        }
        guard let root = document.rootObject else {
            snapshot.isUnparseable = true
            snapshot.parseErrorMessage = "顶层不是一个对象"
            return snapshot
        }
        // An `env` key that exists but is not an object is a different failure from a missing one:
        // the file holds a value where a table belongs, and the user has to decide what to do.
        if root.member("env") != nil, document.object(atPath: ["env"]) == nil {
            snapshot.environmentIsNotAnObject = true
            return snapshot
        }
        let keys = document.keys(atPath: ["env"])
        snapshot.totalEnvironmentKeys = keys.count
        snapshot.managedKeysPresent = Set(keys).intersection(ManagedEnvironment.clearableKeys)
        snapshot.baseURL = document.string(atPath: ["env", ManagedEnvironment.baseURL])
        for tier in ModelTier.allCases {
            if let value = document.string(atPath: ["env", tier.environmentKey]) {
                snapshot.models[tier.rawValue] = value
            }
            if let nameKey = tier.displayNameKey,
               let value = document.string(atPath: ["env", nameKey]) {
                snapshot.modelDisplayNames[tier.rawValue] = value
            }
        }
        return snapshot
    }

    /// Whether `~/.claude.json` already carries `hasCompletedOnboarding: true`.
    public func readOnboardingFlag() -> Bool {
        guard let data = try? Data(contentsOf: paths.claudeJSON),
              let text = String(data: data, encoding: .utf8),
              let document = try? JSONDocument(source: text) else { return false }
        guard let node = document.value(atPath: ["hasCompletedOnboarding"]) else { return false }
        if case let .scalar(scalar) = node { return scalar.text == "true" }
        return false
    }

    // MARK: - Activation

    public func activate(
        profile: BackendProfile,
        credential: String,
        writeOnboardingFlag: Bool
    ) throws -> ActivationResult {
        try validate(profile: profile, credential: credential)

        var warnings: [String] = []
        var effective = profile
        effective.credential = credential

        // 1. Read and refuse rather than repair.
        let snapshot = snapshot()
        if snapshot.isUnparseable {
            throw WriterError.settingsFileUnparseable(snapshot.parseErrorMessage ?? "解析失败")
        }
        if snapshot.environmentIsNotAnObject {
            throw WriterError.environmentNotAnObject
        }

        // 2. Back up before touching anything.
        let replacedProfile = snapshot.baseURL.flatMap { host(of: $0) } ?? BackupManager.unknownProfileSegment
        let backups = BackupManager(paths: paths, fileManager: fileManager)
        let stamp = now()
        let backupSettings = try backups.backup(
            paths.settingsJSON, kind: .settings, profile: replacedProfile, now: stamp
        )
        let backupGlobal = try backups.backup(
            paths.claudeJSON, kind: .globalConfig, profile: replacedProfile, now: stamp
        )

        // 3. Edit settings.json surgically.
        let settingsText: String
        if let data = try? Data(contentsOf: paths.settingsJSON),
           let existing = String(data: data, encoding: .utf8) {
            settingsText = existing
        } else {
            settingsText = "{}\n"
        }
        var document = try JSONDocument(source: settingsText)
        try document.ensureObject(atPath: ["env"])

        let pairs = effective.environmentValues()
        let wantedKeys = Set(pairs.map(\.key))
        // Clear managed keys this profile does not set, so a switch never leaves the previous
        // backend's model name or credential behind.
        for key in ManagedEnvironment.clearableKeys.subtracting(wantedKeys).sorted() {
            try document.removeKey(key, inObjectAt: ["env"])
        }
        for pair in pairs {
            try document.setString(pair.value, forKey: pair.key, inObjectAt: ["env"])
        }
        // A credential written under one variable must not survive under the other.
        if effective.credentialMode == .authToken {
            try document.removeKey(ManagedEnvironment.apiKey, inObjectAt: ["env"])
        }
        let renderedSettings = ensureTrailingNewline(document.render())

        // 4. The onboarding flag lives in ~/.claude.json, a different file with its own content.
        var renderedGlobal: String?
        var wroteOnboarding = false
        if writeOnboardingFlag, !snapshot.hasCompletedOnboarding {
            if let data = try? Data(contentsOf: paths.claudeJSON),
               let existing = String(data: data, encoding: .utf8),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if var globalDocument = try? JSONDocument(source: existing) {
                    try globalDocument.setRawValue("true", forKey: "hasCompletedOnboarding", inObjectAt: [])
                    renderedGlobal = globalDocument.render()
                    wroteOnboarding = true
                } else {
                    // Never rewrite a global config that cannot be parsed: it holds the sign-in
                    // session and every personal MCP server. Report it and carry on with the part
                    // that did work.
                    warnings.append(
                        "~/.claude.json 无法解析，已跳过 hasCompletedOnboarding 写入。首次启动若被要求登录，请手动添加这个键。"
                    )
                }
            } else {
                renderedGlobal = "{\n  \"hasCompletedOnboarding\": true\n}\n"
                wroteOnboarding = true
            }
            if let rendered = renderedGlobal {
                renderedGlobal = ensureTrailingNewline(rendered)
            }
        }

        // 5. Publish: settings.json first, then the global config.
        try AtomicFile.write(renderedSettings, to: paths.settingsJSON, fileManager: fileManager)
        if let renderedGlobal {
            try AtomicFile.write(renderedGlobal, to: paths.claudeJSON, fileManager: fileManager)
        }

        return ActivationResult(
            profileID: effective.id,
            settingsURL: paths.settingsJSON,
            globalConfigURL: paths.claudeJSON,
            backupSettingsURL: backupSettings,
            backupGlobalConfigURL: backupGlobal,
            warnings: warnings,
            settingsJSON: renderedSettings,
            globalConfigJSON: renderedGlobal,
            wroteOnboardingFlag: wroteOnboarding
        )
    }

    // MARK: - Verification

    /// Re-reads the written files and reports anything that does not match what was requested.
    ///
    /// This checks the file layer only: it proves the bytes landed, not that the third-party
    /// service is reachable. It exists because "the write returned" and "the file says it" are
    /// different claims, and only the second one is worth telling the user.
    public func verify(expected profile: BackendProfile, credential: String) -> [String] {
        var problems: [String] = []
        let snapshot = snapshot()
        if !snapshot.fileExists {
            problems.append("settings.json 写入后没有找到")
            return problems
        }
        if snapshot.isUnparseable {
            problems.append("settings.json 写入后无法解析")
            return problems
        }
        let expectedBase = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.baseURL != expectedBase {
            problems.append(
                "settings.json 里的 base_url 是 " + (snapshot.baseURL ?? "空") + "，期望是 " + expectedBase
            )
        }
        for tier in ModelTier.allCases {
            let expected = profile.model(for: tier)
            let actual = snapshot.models[tier.rawValue]
            if expected != actual {
                problems.append(
                    tier.displayName + "是 " + (actual ?? "未设置") + "，期望 " + (expected ?? "未设置")
                )
            }
        }
        for tier in ModelTier.allCases where tier.supportsDisplayName {
            let expected = profile.displayName(for: tier)
            let actual = snapshot.modelDisplayNames[tier.rawValue]
            if expected != actual {
                problems.append(
                    tier.displayName + "的显示名是 " + (actual ?? "未设置") + "，期望 " + (expected ?? "未设置")
                )
            }
        }
        if profile.credentialMode != .none, !credential.isEmpty {
            let key = profile.credentialMode == .authToken
                ? ManagedEnvironment.authToken
                : ManagedEnvironment.apiKey
            let conflicting = profile.credentialMode == .authToken
                ? ManagedEnvironment.apiKey
                : ManagedEnvironment.authToken
            if !snapshot.managedKeysPresent.contains(key) {
                problems.append("settings.json 里没有找到凭据变量 " + key)
            }
            if snapshot.managedKeysPresent.contains(conflicting) {
                problems.append("settings.json 里同时存在 " + conflicting + "，它与 " + key + " 冲突")
            }
        }
        return problems
    }

    /// The bare host of a URL, used to name a backup after the backend it holds.
    private func host(of raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host else { return nil }
        return host.replacingOccurrences(of: ".", with: "-")
    }

    private func validate(profile: BackendProfile, credential: String) throws {
        guard !profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WriterError.emptyBaseURL
        }
        if profile.credentialMode != .none,
           credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WriterError.missingCredential(profile.credentialMode)
        }
    }

    private func ensureTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}
