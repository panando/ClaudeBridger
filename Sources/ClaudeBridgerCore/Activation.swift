import Foundation

/// Decides whether activating a profile is a destructive change the user has to confirm first.
///
/// Claude Code has exactly one active backend, so activating replaces whatever the user was
/// using. Replacing a working setup by accident leaves Claude Code pointed at an endpoint the
/// user did not choose, and the symptom they see is "Claude Code 坏了" with no clue why. This
/// makes that swap an explicit decision instead of a silent side effect.
public enum ActivationGuard {

    public struct Assessment: Equatable, Sendable {
        /// True when the activation would replace a different, foreign backend.
        public let requiresConfirmation: Bool
        /// The base URL Claude Code currently points at, when it differs from the target.
        public let replacedBaseURL: String?
        public let title: String
        /// Empty when no confirmation is needed.
        public let message: String
        public let confirmTitle: String
        /// Non-blocking problems worth showing before the write.
        public let warnings: [String]

        public init(
            requiresConfirmation: Bool,
            replacedBaseURL: String?,
            title: String,
            message: String,
            confirmTitle: String,
            warnings: [String]
        ) {
            self.requiresConfirmation = requiresConfirmation
            self.replacedBaseURL = replacedBaseURL
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
            self.warnings = warnings
        }
    }

    public static func assess(
        currentBaseURL: String?,
        targetBaseURL: String,
        targetName: String,
        knownBaseURLs: Set<String> = []
    ) -> Assessment {
        let warnings = baseURLWarnings(targetBaseURL)
        let current = (currentBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // A backend this app already manages is not a takeover, so it must not ask. Moving between
        // two of our own profiles is the normal case, and asking every time would train the user
        // to click through the one dialog that matters.
        if knownBaseURLs.contains(current) || current.isEmpty || current == target {
            return Assessment(
                requiresConfirmation: false,
                replacedBaseURL: nil,
                title: "",
                message: "",
                confirmTitle: "",
                warnings: warnings
            )
        }
        let displayName = targetName.isEmpty ? target : targetName
        return Assessment(
            requiresConfirmation: true,
            replacedBaseURL: current,
            title: "切换 Claude Code 正在使用的后端？",
            message: "Claude Code 当前指向 " + current + "，激活后将切换为 "
                + displayName + "（" + target + "）。写入前会自动备份 settings.json 和 ~/.claude.json。",
            confirmTitle: "切换并写入",
            warnings: warnings
        )
    }

    /// Flags configuration that would produce a Claude Code that cannot reach anything.
    public static func baseURLWarnings(_ rawBaseURL: String) -> [String] {
        let baseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty {
            return ["没有填写 base_url，写进配置之前请先补上。"]
        }
        guard let url = URL(string: baseURL), let host = url.host?.lowercased() else {
            return ["base_url 不是一个合法的网址：" + baseURL]
        }
        var warnings: [String] = []
        let loopbackHosts = ["127.0.0.1", "localhost", "::1", "0.0.0.0"]
        if loopbackHosts.contains(host) {
            warnings.append("base_url 指向本机（" + host + "），只有本地网关在运行时 Claude Code 才能用。")
        }
        // Claude Code appends /v1/messages itself, so a URL that already carries /v1 produces
        // /v1/v1/messages. The official gateway docs call this out as the mistake that is hardest
        // to debug, because it fails looking like a server problem.
        let path = url.path
        if path.hasSuffix("/v1") || path.hasSuffix("/v1/") {
            warnings.append("base_url 结尾带 /v1 了。Claude Code 会自己拼 /v1/messages，这会导致请求打到 /v1/v1/messages。请把 /v1 去掉。")
        }
        if url.scheme?.lowercased() == "http", !loopbackHosts.contains(host) {
            warnings.append("base_url 用的是 http，凭据会以明文经过网络。")
        }
        return warnings
    }
}

/// Whether the action bar's primary button can be used, and what it should say.
///
/// The contract, carried over from how CodexBridger behaves:
///
/// * 保存 writes ClaudeBridger's own settings file. It touches nothing Claude Code reads and takes
///   no backup, because it is not replacing anybody's file.
/// * 启用 applies the profile: settings.json (and the onboarding flag), with the previous files
///   backed up first, every time.
/// * Once a profile is in use *and* the files already hold exactly these settings, there is
///   nothing left to apply, so the button goes flat. Saving a change brings it back.
public enum ActivationAction {

    public struct Availability: Equatable, Sendable {
        public var isEnabled: Bool
        public var title: String
        /// Why the button is in this state, shown as a tooltip.
        public var help: String

        public init(isEnabled: Bool, title: String, help: String) {
            self.isEnabled = isEnabled
            self.title = title
            self.help = help
        }
    }

    public static func availability(
        hasBaseURL: Bool,
        isDirty: Bool,
        hasErrors: Bool,
        isAlreadyActive: Bool,
        isAlreadyPublished: Bool
    ) -> Availability {
        let title = "启用"
        if hasErrors {
            return Availability(isEnabled: false, title: title, help: "先解决表单里的错误")
        }
        if isDirty {
            return Availability(isEnabled: false, title: title, help: "需要先保存")
        }
        if !hasBaseURL {
            return Availability(isEnabled: false, title: title, help: "需要先填写 base_url")
        }
        if isAlreadyActive, isAlreadyPublished {
            return Availability(
                isEnabled: false,
                title: title,
                help: "Claude Code 正在用它，文件里就是这套设置；改完保存后这里会重新可用"
            )
        }
        if isAlreadyActive {
            return Availability(
                isEnabled: true,
                title: title,
                help: "设置改过了，还没写进 Claude Code；点这里重新写入（写入前先备份）"
            )
        }
        return Availability(
            isEnabled: true,
            title: title,
            help: "把这套设置写进 Claude Code（写入前先备份）"
        )
    }
}

/// Checks that a completed write actually landed in the file Claude Code reads.
///
/// Kept separate from the writer so that the check has no access to the intent: it only sees the
/// profile and re-reads the disk. That is what makes "verified" mean something.
public enum ActivationVerification {

    /// Returns one message per problem found. Empty means the write is consistent.
    public static func warnings(
        expected: BackendProfile,
        credential: String,
        snapshot: SettingsSnapshot,
        problems: [String] = []
    ) -> [String] {
        var result = problems
        if !snapshot.fileExists {
            result.append("settings.json 写入后没有找到")
            return result
        }
        if snapshot.isUnparseable {
            result.append("settings.json 写入后无法解析")
            return result
        }
        let expectedBase = expected.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.baseURL != expectedBase {
            result.append(
                "settings.json 里的 base_url 是 " + (snapshot.baseURL ?? "空") + "，期望是 " + expectedBase
            )
        }
        for tier in ModelTier.allCases {
            let wanted = expected.model(for: tier)
            let actual = snapshot.models[tier.rawValue]
            if wanted != actual {
                result.append(
                    tier.displayName + "是 " + (actual ?? "未设置") + "，期望 " + (wanted ?? "未设置")
                )
            }
        }
        for tier in ModelTier.allCases where tier.supportsDisplayName {
            let wanted = expected.displayName(for: tier)
            let actual = snapshot.modelDisplayNames[tier.rawValue]
            if wanted != actual {
                result.append(
                    tier.displayName + "的显示名是 " + (actual ?? "未设置") + "，期望 " + (wanted ?? "未设置")
                )
            }
        }
        for flag in EnvironmentFlag.allCases {
            let wanted = expected.isOn(flag) ? flag.onValue : nil
            let actual = snapshot.flagValues[flag.key]
            if wanted != actual {
                result.append(
                    flag.displayName + "是 " + (actual ?? "未设置") + "，期望 " + (wanted ?? "未设置")
                )
            }
        }
        for choice in EnvironmentChoice.allCases {
            let wanted = expected.choiceValue(choice)
            let actual = snapshot.choiceValues[choice.key]
            if wanted != actual {
                result.append(
                    choice.displayName + "是 " + (actual ?? "未设置") + "，期望 " + (wanted ?? "未设置")
                )
            }
        }
        if expected.credentialMode != .none, !credential.isEmpty {
            let key = expected.credentialMode == .authToken
                ? ManagedEnvironment.authToken
                : ManagedEnvironment.apiKey
            if !snapshot.managedKeysPresent.contains(key) {
                result.append("settings.json 里没有找到凭据变量 " + key)
            }
        }
        return result
    }
}
