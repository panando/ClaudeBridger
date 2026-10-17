import Foundation

// MARK: - Values Claude Code defines

/// The model tier aliases Claude Code resolves internally.
///
/// Claude Code does not call one model; it calls whichever model each situation needs — the main
/// conversation, background summarisation, subagent work — and picks it by alias. Pointing the
/// endpoint at a third-party backend without also pointing these aliases there makes the
/// background tiers silently fail: they keep requesting `claude-haiku-*` from a provider that has
/// never heard of it. Both DeepSeek's and Kimi's official guides call this out as the single most
/// common misconfiguration, which is why every tier is a first-class field here rather than
/// something the user is expected to remember.
public enum ModelTier: String, Codable, CaseIterable, Sendable {
    /// The main conversation, `ANTHROPIC_MODEL`.
    case primary
    /// The `opus` alias, `ANTHROPIC_DEFAULT_OPUS_MODEL`.
    case opus
    /// The `sonnet` alias, `ANTHROPIC_DEFAULT_SONNET_MODEL`.
    case sonnet
    /// The `haiku` alias, `ANTHROPIC_DEFAULT_HAIKU_MODEL`. Also drives background token usage.
    case haiku
    /// The `fable` alias, `ANTHROPIC_DEFAULT_FABLE_MODEL`. Also the ID Claude Code recognises for
    /// automatic model fallback on third-party providers.
    case fable
    /// Subagents, `CLAUDE_CODE_SUBAGENT_MODEL`.
    case subagent

    public var environmentKey: String {
        switch self {
        case .primary: return "ANTHROPIC_MODEL"
        case .opus: return "ANTHROPIC_DEFAULT_OPUS_MODEL"
        case .sonnet: return "ANTHROPIC_DEFAULT_SONNET_MODEL"
        case .haiku: return "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        case .fable: return "ANTHROPIC_DEFAULT_FABLE_MODEL"
        case .subagent: return "CLAUDE_CODE_SUBAGENT_MODEL"
        }
    }

    public var displayName: String {
        switch self {
        case .primary: return "主对话"
        case .opus: return "Opus 档"
        case .sonnet: return "Sonnet 档"
        case .haiku: return "Haiku 档（后台任务）"
        case .fable: return "Fable 档（自动降级）"
        case .subagent: return "子 Agent"
        }
    }

    public var explanation: String {
        switch self {
        case .primary: return "你平时对话用的模型。"
        case .opus: return "选择 opus 别名时实际请求的模型。"
        case .sonnet: return "选择 sonnet 别名时实际请求的模型。"
        case .haiku: return "后台摘要、标题生成等轻量任务用。不配置这一档，这些任务会静默失败。"
        case .fable: return "自动降级时使用。不配置会退回到 Claude 默认模型名。"
        case .subagent: return "子 Agent 执行的模型。不配置会让子任务失败或明显变差。"
        }
    }

    /// The variable that overrides this tier's label in the `/model` picker, when one exists.
    ///
    /// Only the four alias tiers have a display-name variable. There is no `ANTHROPIC_MODEL_NAME`
    /// and no subagent equivalent in the official reference, so this returns nil for those two and
    /// the app must not invent them.
    public var displayNameKey: String? {
        switch self {
        case .opus: return "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"
        case .sonnet: return "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"
        case .haiku: return "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"
        case .fable: return "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"
        case .primary, .subagent: return nil
        }
    }

    /// Whether this tier can carry a display name at all.
    public var supportsDisplayName: Bool { displayNameKey != nil }
}

/// Every environment key ClaudeBridger is allowed to write or remove.
///
/// This list is the whole safety boundary of the app. Claude Code reads settings.json's `env`
/// block as a general-purpose environment for itself and every subprocess it starts, so a naive
/// writer that rewrites the block would destroy a user's own variables — a proxy setting, a
/// telemetry token, an API timeout. ClaudeBridger therefore treats `env` as a shared object: it
/// writes only keys on this list, clears only keys on this list, and leaves every other member of
/// the object byte-for-byte alone.
///
/// The list covers the endpoint, the credential, the model tiers, the context-window knobs and
/// the two traffic switches that a third-party endpoint needs.
public enum ManagedEnvironment {
    /// `ANTHROPIC_BASE_URL` — where requests go.
    public static let baseURL = "ANTHROPIC_BASE_URL"
    /// `ANTHROPIC_AUTH_TOKEN` — sent as `Authorization: Bearer`.
    public static let authToken = "ANTHROPIC_AUTH_TOKEN"
    /// `ANTHROPIC_API_KEY` — sent as `x-api-key`.
    ///
    /// Managed only so it can be *removed*. The two credential variables conflict when both are
    /// set, and a stale `ANTHROPIC_API_KEY` left over from an earlier setup is the documented
    /// cause of `401` responses. ClaudeBridger writes the token and clears the key.
    public static let apiKey = "ANTHROPIC_API_KEY"
    /// `CLAUDE_CODE_AUTO_COMPACT_WINDOW` — when automatic compaction triggers.
    public static let autoCompactWindow = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
    /// `CLAUDE_CODE_MAX_CONTEXT_TOKENS` — the context budget.
    public static let maxContextTokens = "CLAUDE_CODE_MAX_CONTEXT_TOKENS"
    /// `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` — stops calls that only make sense against
    /// Anthropic's own API.
    public static let disableNonessentialTraffic = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    /// `CLAUDE_CODE_EFFORT_LEVEL` — the default thinking effort.
    public static let effortLevel = "CLAUDE_CODE_EFFORT_LEVEL"

    /// Every model-tier variable, derived so the two lists can never drift apart.
    public static var modelTierKeys: [String] { ModelTier.allCases.map(\.environmentKey) }

    /// The display-name variables for the tiers that have one.
    ///
    /// These are managed because they are part of pointing Claude Code at a third-party backend:
    /// a leftover label from a previous gateway is what makes the `/model` picker show a name that
    /// has nothing to do with the model actually being requested.
    public static var modelDisplayNameKeys: [String] {
        ModelTier.allCases.compactMap(\.displayNameKey)
    }

    /// Everything ClaudeBridger may write.
    public static var writableKeys: Set<String> {
        Set([
            baseURL,
            authToken,
            autoCompactWindow,
            maxContextTokens,
            disableNonessentialTraffic,
            effortLevel
        ]).union(modelTierKeys).union(modelDisplayNameKeys)
    }

    /// Everything ClaudeBridger may remove. The credential key is here but not in `writableKeys`:
    /// it is cleared, never set.
    public static var clearableKeys: Set<String> {
        writableKeys.union([apiKey])
    }

    /// Keys whose values are secret and must never be written into ClaudeBridger's own state file
    /// (which is not where the user expects a credential to be, and which nothing rotates).
    public static var secretKeys: Set<String> { [authToken, apiKey] }
}

/// The effort levels `CLAUDE_CODE_EFFORT_LEVEL` accepts.
public enum EffortLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case low
    case medium
    case high
    case xhigh
    case max

    public static func < (lhs: EffortLevel, rhs: EffortLevel) -> Bool {
        let order = EffortLevel.allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// How a provider authenticates.
public enum CredentialMode: String, Codable, CaseIterable, Sendable {
    /// `ANTHROPIC_AUTH_TOKEN`, sent as `Authorization: Bearer`. What every vendor guide shows.
    case authToken
    /// `ANTHROPIC_API_KEY`, sent as `x-api-key`.
    case apiKey
    /// No credential written; the user supplies it another way.
    case none

    public var displayName: String {
        switch self {
        case .authToken: return "Bearer Token（ANTHROPIC_AUTH_TOKEN）"
        case .apiKey: return "API Key（ANTHROPIC_API_KEY）"
        case .none: return "不写入凭据"
        }
    }

    public var explanation: String {
        switch self {
        case .authToken: return "作为 Authorization: Bearer 头发送。绝大多数国产厂商的服务端都认这个。"
        case .apiKey: return "作为 x-api-key 头发送。少量只认这个头的服务端需要它。"
        case .none: return "只写地址和模型，凭据留给你自己用环境变量或 apiKeyHelper 提供。"
        }
    }
}

// MARK: - Persisted configuration

/// One backend the user can switch Claude Code to.
public struct BackendProfile: Codable, Identifiable, Equatable, Sendable {
    /// Stable id, used for the sidebar and for backup filenames.
    public var id: String
    public var name: String
    /// Sidebar group. ClaudeBridger's own metadata: never written to any file.
    public var category: String

    /// `ANTHROPIC_BASE_URL`. Must have no trailing `/v1`; Claude Code appends `/v1/messages`.
    public var baseURL: String
    public var credentialMode: CredentialMode
    /// Held in memory and written to settings.json, but never persisted to ClaudeBridger's own
    /// config.json — see `StoredProfile`.
    public var credential: String

    /// Model id per tier. A tier set to nil is left unwritten, which keeps whatever Claude Code
    /// would otherwise resolve.
    public var models: [String: String]

    /// Optional display label per tier, for the tiers that support one.
    ///
    /// This is what the `/model` picker shows. It changes nothing about which model is requested,
    /// but leaving a stale label behind is confusing in a specific way: the picker then advertises
    /// one model while the requests go to another.
    public var modelDisplayNames: [String: String]

    /// Pins the context window. nil means do not write either variable, which lets the model's
    /// own documented default apply.
    public var contextWindow: Int?
    /// Whether to set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`.
    public var disableNonessentialTraffic: Bool
    public var effortLevel: EffortLevel?

    public init(
        id: String,
        name: String,
        category: String = BackendPreset.customCategory,
        baseURL: String = "",
        credentialMode: CredentialMode = .authToken,
        credential: String = "",
        models: [String: String] = [:],
        modelDisplayNames: [String: String] = [:],
        contextWindow: Int? = nil,
        disableNonessentialTraffic: Bool = true,
        effortLevel: EffortLevel? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.baseURL = baseURL
        self.credentialMode = credentialMode
        self.credential = credential
        self.models = models
        self.modelDisplayNames = modelDisplayNames
        self.contextWindow = contextWindow
        self.disableNonessentialTraffic = disableNonessentialTraffic
        self.effortLevel = effortLevel
    }

    public func model(for tier: ModelTier) -> String? {
        let raw = models[tier.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    public mutating func setModel(_ value: String?, for tier: ModelTier) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            models[tier.rawValue] = trimmed
        } else {
            models.removeValue(forKey: tier.rawValue)
        }
    }

    /// The display label for `tier`, or nil when none is set or the tier has no such variable.
    public func displayName(for tier: ModelTier) -> String? {
        guard tier.supportsDisplayName else { return nil }
        let raw = modelDisplayNames[tier.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    public mutating func setDisplayName(_ value: String?, for tier: ModelTier) {
        guard tier.supportsDisplayName else { return }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            modelDisplayNames[tier.rawValue] = trimmed
        } else {
            modelDisplayNames.removeValue(forKey: tier.rawValue)
        }
    }

    /// Every environment variable this profile would write, in a stable order.
    ///
    /// The order matters only for readability of the written file, but it is fixed so a switch
    /// produces the smallest possible diff and tests can assert on exact text.
    public func environmentValues() -> [(key: String, value: String)] {
        var pairs: [(String, String)] = []
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            pairs.append((ManagedEnvironment.baseURL, base))
        }
        let secret = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            switch credentialMode {
            case .authToken: pairs.append((ManagedEnvironment.authToken, secret))
            case .apiKey: pairs.append((ManagedEnvironment.apiKey, secret))
            case .none: break
            }
        }
        for tier in ModelTier.allCases {
            if let value = model(for: tier) {
                pairs.append((tier.environmentKey, value))
                // Emitted next to its model so the written block reads as a pair, and so a label
                // can never outlive the model it describes.
                if let label = displayName(for: tier), let nameKey = tier.displayNameKey {
                    pairs.append((nameKey, label))
                }
            }
        }
        if let window = contextWindow {
            pairs.append((ManagedEnvironment.autoCompactWindow, String(window)))
            pairs.append((ManagedEnvironment.maxContextTokens, String(window)))
        }
        if disableNonessentialTraffic {
            pairs.append((ManagedEnvironment.disableNonessentialTraffic, "1"))
        }
        if let effort = effortLevel {
            pairs.append((ManagedEnvironment.effortLevel, effort.rawValue))
        }
        return pairs
    }

    /// Whether this profile would write exactly what `other` would.
    ///
    /// The credential is deliberately excluded: comparing secrets would make a password field
    /// look dirty just because it was retyped, and the question this answers is about the shape
    /// of the configuration, not the value of the key. Display names are included, because they
    /// are written to the file and changing one is a reason to write.
    public func hasSamePublishedSettings(as other: BackendProfile) -> Bool {
        var lhs = self
        var rhs = other
        lhs.id = ""
        rhs.id = ""
        lhs.name = ""
        rhs.name = ""
        lhs.category = ""
        rhs.category = ""
        lhs.credential = ""
        rhs.credential = ""
        return lhs == rhs
    }
}

/// The on-disk shape of a profile.
///
/// ClaudeBridger holds the credential in its own Keychain-backed or in-memory store and writes it
/// straight into settings.json on activation; it does not copy it into this file. A credential in
/// a plaintext JSON file the user never looks at is a credential that leaks on the first backup,
/// sync or screenshot.
public struct StoredProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var baseURL: String
    public var credentialMode: CredentialMode
    public var models: [String: String]
    public var modelDisplayNames: [String: String]
    public var contextWindow: Int?
    public var disableNonessentialTraffic: Bool
    public var effortLevel: EffortLevel?

    public init(_ profile: BackendProfile) {
        id = profile.id
        name = profile.name
        category = profile.category
        baseURL = profile.baseURL
        credentialMode = profile.credentialMode
        models = profile.models
        modelDisplayNames = profile.modelDisplayNames
        contextWindow = profile.contextWindow
        disableNonessentialTraffic = profile.disableNonessentialTraffic
        effortLevel = profile.effortLevel
    }

    /// Hand-written so a config saved before display names existed still decodes.
    ///
    /// The synthesised decoder throws on a missing key, which would turn "new field" into "your
    /// saved backends are gone" for anyone upgrading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? BackendPreset.customCategory
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        credentialMode = try container.decodeIfPresent(CredentialMode.self, forKey: .credentialMode) ?? .authToken
        models = try container.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        modelDisplayNames = try container.decodeIfPresent([String: String].self, forKey: .modelDisplayNames) ?? [:]
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        disableNonessentialTraffic = try container.decodeIfPresent(Bool.self, forKey: .disableNonessentialTraffic) ?? true
        effortLevel = try container.decodeIfPresent(EffortLevel.self, forKey: .effortLevel)
    }

    public func profile(credential: String) -> BackendProfile {
        BackendProfile(
            id: id,
            name: name,
            category: category,
            baseURL: baseURL,
            credentialMode: credentialMode,
            credential: credential,
            models: models,
            modelDisplayNames: modelDisplayNames,
            contextWindow: contextWindow,
            disableNonessentialTraffic: disableNonessentialTraffic,
            effortLevel: effortLevel
        )
    }
}

/// The whole persisted state of the app, stored in `<config dir>/claudebridger/config.json`.
public struct ClaudeBridgerConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// Profiles, in sidebar order. Credentials are held separately.
    public var profiles: [StoredProfile]
    /// The profile currently written into settings.json, if any.
    public var activeProfileID: String?
    /// The profile as it was last written, so the screen can tell whether the button still has
    /// anything to apply.
    public var publishedProfile: StoredProfile?
    /// Whether ClaudeBridger also wrote the `hasCompletedOnboarding` flag into ~/.claude.json.
    public var wroteOnboardingFlag: Bool
    /// Re-read the written files after activating and report any mismatch.
    public var verifyAfterWrite: Bool
    public var interfaceLanguage: InterfaceLanguage

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = ClaudeBridgerConfiguration.currentSchemaVersion,
        profiles: [StoredProfile] = [],
        activeProfileID: String? = nil,
        publishedProfile: StoredProfile? = nil,
        wroteOnboardingFlag: Bool = false,
        verifyAfterWrite: Bool = true,
        interfaceLanguage: InterfaceLanguage = .system
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.publishedProfile = publishedProfile
        self.wroteOnboardingFlag = wroteOnboardingFlag
        self.verifyAfterWrite = verifyAfterWrite
        self.interfaceLanguage = interfaceLanguage
    }

    /// Hand-written so a config saved by an older build still decodes: Swift's synthesised
    /// decoder throws on a missing key, which would turn "new field" into "your profiles are
    /// gone".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ClaudeBridgerConfiguration.currentSchemaVersion
        profiles = try container.decodeIfPresent([StoredProfile].self, forKey: .profiles) ?? []
        activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID)
        publishedProfile = try container.decodeIfPresent(StoredProfile.self, forKey: .publishedProfile)
        wroteOnboardingFlag = try container.decodeIfPresent(Bool.self, forKey: .wroteOnboardingFlag) ?? false
        verifyAfterWrite = try container.decodeIfPresent(Bool.self, forKey: .verifyAfterWrite) ?? true
        interfaceLanguage = try container.decodeIfPresent(InterfaceLanguage.self, forKey: .interfaceLanguage) ?? .system
    }

    public func profile(id: String) -> BackendProfile? {
        profiles.first { $0.id == id }?.profile(credential: "")
    }
}

/// Interface language.
public enum InterfaceLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese
    case english

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}
