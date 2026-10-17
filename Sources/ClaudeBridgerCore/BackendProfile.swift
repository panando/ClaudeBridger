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

    // MARK: - The 1M context suffix

    /// The context-window hint written after a model id, e.g. `deepseek-v4-pro[1m]`.
    ///
    /// Verified by experiment against Claude Code v2.1.299: the CLI strips this suffix before
    /// sending the request, so the vendor receives the bare model id. It is a client-side hint
    /// telling Claude Code the model can take a large context, not part of the model's name.
    public static let oneMillionSuffix = "[1m]"

    /// Every spelling of the suffix that has been observed in the wild.
    ///
    /// ClaudeBridger writes the lowercase form, but Cherry Studio writes `[1M]` (with a space, as
    /// ` [1M]`) and several vendor guides use `[1M]`. Reading all of them means a profile written
    /// by another tool is recognised as 1M rather than silently treated as an ordinary model name.
    static let recognisedSuffixes = ["[1m]", "[1M]", " [1m]", " [1M]"]

    /// The model id with any recognised 1M suffix removed.
    public static func stripping1M(from model: String) -> String {
        var result = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Loop so a doubled suffix (`m[1m][1M]`) cannot survive a single pass.
        var changed = true
        while changed {
            changed = false
            for suffix in recognisedSuffixes where result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return result
    }

    /// Whether `model` carries a 1M suffix in any recognised spelling.
    public static func has1M(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return recognisedSuffixes.contains { trimmed.hasSuffix($0) }
    }

    /// Appends the suffix in the canonical form.
    public static func appending1M(to model: String) -> String {
        let bare = stripping1M(from: model)
        guard !bare.isEmpty else { return bare }
        return bare + oneMillionSuffix
    }
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
/// The list covers the endpoint, the credential, the model tiers and their labels, the
/// context-window knobs, the behaviour flags, the numeric limits and the custom-header setting.
///
/// Every key here is a Claude Code configuration variable. None of them is a variable a user would
/// plausibly have set for their own purposes, which is the test a new key has to pass to join this
/// set: widening this boundary is how the app could start damaging the file it promises to protect.
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

    /// The keys of every behaviour flag, derived from the flag list.
    public static var flagKeys: [String] { EnvironmentFlag.allCases.map(\.key) }

    /// The keys of the choice settings, derived from the choice list.
    public static var choiceKeys: [String] { EnvironmentChoice.allCases.map(\.key) }

    /// The keys of the numeric limits, derived from the numeric list.
    public static var numericKeys: [String] { NumericSetting.allCases.map(\.key) }

    /// Keys ClaudeBridger writes but does **not** claim ownership of.
    ///
    /// This is the important distinction for these options, and it exists because of a real
    /// incident caught in review: `API_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS`,
    /// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` and `CLAUDE_CODE_MAX_OUTPUT_TOKENS` are general tuning
    /// knobs. A user may well have set them by hand long before this app existed — one machine had
    /// `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = 87` sitting in its settings.json.
    ///
    /// If those keys joined `clearableKeys`, switching backends would delete a value the user
    /// wrote, which is precisely the damage this app exists to prevent. So they are writable (an
    /// explicit value in the profile wins, and can be corrected) but never *cleared*: an empty
    /// field means "leave whatever is there alone", not "remove it".
    public static var userOwnedKeys: Set<String> {
        Set(numericKeys)
    }

    /// Everything ClaudeBridger may write.
    public static var writableKeys: Set<String> {
        Set([
            baseURL,
            authToken,
            autoCompactWindow,
            maxContextTokens,
            effortLevel,
            CustomHeaders.key
        ])
        .union(modelTierKeys)
        .union(modelDisplayNameKeys)
        .union(flagKeys)
        .union(choiceKeys)
        .union(numericKeys)
    }

    /// Everything ClaudeBridger may remove.
    ///
    /// The credential key is here but not in `writableKeys`: it is cleared, never set. The
    /// user-owned keys are deliberately excluded — see `userOwnedKeys`.
    public static var clearableKeys: Set<String> {
        writableKeys.subtracting(userOwnedKeys).union([apiKey])
    }

    /// Keys whose values are secret and must never be written into ClaudeBridger's own state file
    /// (which is not where the user expects a credential to be, and which nothing rotates).
    public static var secretKeys: Set<String> { [authToken, apiKey] }

    /// Whether a key is managed at all, in either direction.
    public static func isManaged(_ key: String) -> Bool {
        writableKeys.contains(key) || clearableKeys.contains(key)
    }
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
    /// The behaviour flags that are on. A flag that is off is absent from the file rather than
    /// written with an "off" value, so switching backends really does clear the previous one's.
    public var flags: Set<EnvironmentFlag>
    /// Choice settings, keyed by `EnvironmentChoice.rawValue`. Absent means "leave unset", which
    /// for `ENABLE_TOOL_SEARCH` is materially different from any explicit value.
    public var choices: [String: String]
    /// Numeric limits, keyed by `NumericSetting.rawValue`. Absent means unset.
    public var numerics: [String: String]
    /// Raw `ANTHROPIC_CUSTOM_HEADERS` text, newline-separated `Name: Value`. Empty means unset.
    public var customHeaders: String
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
        flags: Set<EnvironmentFlag> = [],
        choices: [String: String] = [:],
        numerics: [String: String] = [:],
        customHeaders: String = "",
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
        self.flags = flags
        self.choices = choices
        self.numerics = numerics
        self.customHeaders = customHeaders
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

    // MARK: - The 1M checkbox
    //
    // The checkbox is a view of the model string, not a stored field. Keeping `models` as the only
    // source of truth is what makes this migration-free: a profile that already says
    // `deepseek-v4-pro[1m]` simply shows as checked, and there is no second value that could
    // disagree with the one being written.

    /// Whether this tier's model carries a 1M suffix.
    public func is1M(for tier: ModelTier) -> Bool {
        guard let value = model(for: tier) else { return false }
        return ModelTier.has1M(value)
    }

    /// Turns the suffix on or off for this tier. No-op when the tier has no model.
    public mutating func set1M(_ enabled: Bool, for tier: ModelTier) {
        guard let current = model(for: tier) else { return }
        let updated = enabled
            ? ModelTier.appending1M(to: current)
            : ModelTier.stripping1M(from: current)
        setModel(updated, for: tier)
        // A label describes the model, never the hint: keep it free of the suffix.
        if let label = displayName(for: tier) {
            setDisplayName(ModelTier.stripping1M(from: label), for: tier)
        }
    }

    // MARK: - Flags, choices, numerics

    public func isOn(_ flag: EnvironmentFlag) -> Bool { flags.contains(flag) }

    public mutating func setFlag(_ flag: EnvironmentFlag, on: Bool) {
        if on { flags.insert(flag) } else { flags.remove(flag) }
    }

    public func choiceValue(_ choice: EnvironmentChoice) -> String? {
        guard let raw = choices[choice.rawValue] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public mutating func setChoice(_ choice: EnvironmentChoice, value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            choices[choice.rawValue] = trimmed
        } else {
            choices.removeValue(forKey: choice.rawValue)
        }
    }

    public func numericValue(_ setting: NumericSetting) -> String? {
        guard let raw = numerics[setting.rawValue] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public mutating func setNumeric(_ setting: NumericSetting, value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            numerics[setting.rawValue] = trimmed
        } else {
            numerics.removeValue(forKey: setting.rawValue)
        }
    }

    /// The custom headers as the newline-separated text the variable expects.
    public var normalizedCustomHeaders: String? {
        let parsed = CustomHeaders.parse(customHeaders)
        guard !parsed.pairs.isEmpty else { return nil }
        return CustomHeaders.render(parsed.pairs)
    }

    /// Problems in the custom-header text, for the form to surface. A malformed header line would
    /// otherwise reach the service and fail there, where it is far harder to diagnose.
    public var customHeaderProblems: [String] {
        CustomHeaders.parse(customHeaders).problems
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
        if let effort = effortLevel {
            pairs.append((ManagedEnvironment.effortLevel, effort.rawValue))
        }
        // Flags, choices and numerics are emitted in enum declaration order so the written block
        // has a stable shape regardless of the order the user toggled things.
        for flag in EnvironmentFlag.allCases where flags.contains(flag) {
            pairs.append((flag.key, flag.onValue))
        }
        for choice in EnvironmentChoice.allCases {
            if let value = choiceValue(choice) {
                pairs.append((choice.key, value))
            }
        }
        for setting in NumericSetting.allCases {
            if let value = numericValue(setting) {
                pairs.append((setting.key, value))
            }
        }
        if let headers = normalizedCustomHeaders {
            pairs.append((CustomHeaders.key, headers))
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
    public var flags: Set<EnvironmentFlag>
    public var choices: [String: String]
    public var numerics: [String: String]
    public var customHeaders: String
    public var effortLevel: EffortLevel?

    /// Declared explicitly because `disableNonessentialTraffic` is read during decoding but is no
    /// longer a stored property: the synthesised key list only covers stored properties, so the
    /// legacy key would otherwise be unreachable and every 1.0.x profile would lose that setting.
    enum CodingKeys: String, CodingKey {
        case id, name, category, baseURL, credentialMode
        case models, modelDisplayNames, contextWindow
        case flags, choices, numerics, customHeaders, effortLevel
        /// Legacy (1.0.x). Read-only: never written back.
        case disableNonessentialTraffic
    }

    public init(_ profile: BackendProfile) {
        id = profile.id
        name = profile.name
        category = profile.category
        baseURL = profile.baseURL
        credentialMode = profile.credentialMode
        models = profile.models
        modelDisplayNames = profile.modelDisplayNames
        contextWindow = profile.contextWindow
        flags = profile.flags
        choices = profile.choices
        numerics = profile.numerics
        customHeaders = profile.customHeaders
        effortLevel = profile.effortLevel
    }

    /// Hand-written so a config saved by an older build still decodes.
    ///
    /// The synthesised decoder throws on a missing key, which would turn "new field" into "your
    /// saved backends are gone" for anyone upgrading. That matters more here than usual: 1.1.0
    /// replaced a stored boolean with a set of flags, so this is the one place where an existing
    /// user's data is read by a shape it was not written in.
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
        choices = try container.decodeIfPresent([String: String].self, forKey: .choices) ?? [:]
        numerics = try container.decodeIfPresent([String: String].self, forKey: .numerics) ?? [:]
        customHeaders = try container.decodeIfPresent(String.self, forKey: .customHeaders) ?? ""
        effortLevel = try container.decodeIfPresent(EffortLevel.self, forKey: .effortLevel)

        if let decoded = try container.decodeIfPresent(Set<EnvironmentFlag>.self, forKey: .flags) {
            flags = decoded
        } else {
            // Migration from the 1.0.x shape, which stored a single boolean instead of the set.
            //
            // The old field defaulted to `true`, so a profile saved by 1.0.1 that omitted it still
            // had the flag on. Decoding `?? true` for the legacy key therefore reproduces the old
            // behaviour exactly rather than silently dropping a setting the user had.
            let legacy = try container.decodeIfPresent(Bool.self, forKey: .disableNonessentialTraffic) ?? true
            flags = legacy ? [.disableNonessentialTraffic] : []
        }
    }

    /// Written by hand because `CodingKeys` carries a read-only case (the legacy boolean), which
    /// stops the synthesised encoder from being generated. The legacy key is deliberately not
    /// written: 1.1.0 stores the same information in `flags`, and emitting both would leave two
    /// sources of truth that could disagree.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(credentialMode, forKey: .credentialMode)
        try container.encode(models, forKey: .models)
        try container.encode(modelDisplayNames, forKey: .modelDisplayNames)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encode(flags, forKey: .flags)
        try container.encode(choices, forKey: .choices)
        try container.encode(numerics, forKey: .numerics)
        try container.encode(customHeaders, forKey: .customHeaders)
        try container.encodeIfPresent(effortLevel, forKey: .effortLevel)
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
            flags: flags,
            choices: choices,
            numerics: numerics,
            customHeaders: customHeaders,
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
