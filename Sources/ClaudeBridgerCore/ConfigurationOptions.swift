import Foundation

// MARK: - Provenance
//
// Every option ClaudeBridger can write declares where its key came from. This is not decoration:
// two of the sources are third-party implementations rather than vendor documentation, and an
// option that only a third-party app uses may stop working in any Claude Code release. The
// interface has to be able to say which is which, so provenance is data on the option rather than
// a note in a README that drifts.

/// Where an option's environment key was confirmed.
public enum OptionProvenance: String, Codable, CaseIterable, Sendable {
    /// Listed in Claude Code's official environment variables reference.
    case officialDocumentation
    /// Used by a widely deployed third-party client (Cherry Studio), but not listed in the
    /// official reference. It may work; it may stop working without notice.
    case thirdPartyImplementation

    public var isOfficial: Bool { self == .officialDocumentation }

    public var shortLabel: String {
        switch self {
        case .officialDocumentation: return "官方文档"
        case .thirdPartyImplementation: return "第三方实现"
        }
    }

    public var explanation: String {
        switch self {
        case .officialDocumentation:
            return "这个键在 Claude Code 官方环境变量文档里可以查到。"
        case .thirdPartyImplementation:
            return "这个键在主流第三方客户端（Cherry Studio）里在用，但官方文档没有列出。可能有效，也可能随版本失效——所以默认不开启。"
        }
    }
}

// MARK: - Boolean flags

/// A toggle that writes a fixed value under its key when enabled, and is absent when disabled.
///
/// The value is data rather than a constant because one of these is inverted: omitting the
/// attribution block is requested by setting `CLAUDE_CODE_ATTRIBUTION_HEADER` to `0`. Modelling
/// that as `onValue` keeps the inversion in one place instead of in a special case at each call
/// site, and keeps the interface labelling the *feature* rather than the value.
public enum EnvironmentFlag: String, Codable, CaseIterable, Sendable {
    case disableNonessentialTraffic
    case disableAutoupdater
    case disableBundledSkills
    case disableCompact
    case disable1MContext
    case disableTerminalTitle
    case disableExtraUsageCommand
    case agentTeams
    case emitSessionStateEvents
    case totalTokensReminderOff
    case omitAttributionHeader

    public var key: String {
        switch self {
        case .disableNonessentialTraffic: return "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
        case .disableAutoupdater: return "DISABLE_AUTOUPDATER"
        case .disableBundledSkills: return "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS"
        case .disableCompact: return "DISABLE_COMPACT"
        case .disable1MContext: return "CLAUDE_CODE_DISABLE_1M_CONTEXT"
        case .disableTerminalTitle: return "CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
        case .disableExtraUsageCommand: return "DISABLE_EXTRA_USAGE_COMMAND"
        case .agentTeams: return "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
        case .emitSessionStateEvents: return "CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"
        case .totalTokensReminderOff: return "CLAUDE_CODE_TOTAL_TOKENS_REMINDER"
        case .omitAttributionHeader: return "CLAUDE_CODE_ATTRIBUTION_HEADER"
        }
    }

    /// The value written when the flag is on. Most are `"1"`; two are not, which is exactly why
    /// this is a property.
    public var onValue: String {
        switch self {
        case .totalTokensReminderOff: return "off"
        case .omitAttributionHeader: return "0"
        default: return "1"
        }
    }

    public var displayName: String {
        switch self {
        case .disableNonessentialTraffic: return "关闭非必要流量"
        case .disableAutoupdater: return "关闭自动更新"
        case .disableBundledSkills: return "关闭内置 skills"
        case .disableCompact: return "关闭上下文压缩"
        case .disable1MContext: return "关闭 1M 上下文"
        case .disableTerminalTitle: return "不修改终端标题"
        case .disableExtraUsageCommand: return "关闭 extra usage 命令"
        case .agentTeams: return "实验性 Agent Teams"
        case .emitSessionStateEvents: return "输出会话状态事件"
        case .totalTokensReminderOff: return "关闭 token 用量提醒"
        case .omitAttributionHeader: return "省略系统提示里的署名块"
        }
    }

    public var explanation: String {
        switch self {
        case .disableNonessentialTraffic:
            return "接第三方后端时建议开启：阻止那些只对 Anthropic 官方接口有意义的额外请求。"
        case .disableAutoupdater:
            return "关掉 Claude Code 的自更新。如果你想自己控制版本，或者自更新在公司网络里会卡住，可以开启。"
        case .disableBundledSkills:
            return "不加载 Claude Code 自带的 skills，只保留你自己的。"
        case .disableCompact:
            return "同时关掉自动压缩和手动 /compact。注意这会让长会话更早撞到上下文上限。"
        case .disable1MContext:
            return "关掉 1M 上下文相关行为，退回默认窗口。"
        case .disableTerminalTitle:
            return "不让 Claude Code 改动终端窗口标题。"
        case .disableExtraUsageCommand:
            return "关掉额外用量相关的命令。"
        case .agentTeams:
            return "开启实验性的多 Agent 协作功能。属于实验特性，行为可能随版本变化。"
        case .emitSessionStateEvents:
            return "在消息流里加入会话状态事件。只在通过 Agent SDK 或 --print/--output-format stream-json 使用时才有意义。"
        case .totalTokensReminderOff:
            return "关闭 token 用量提醒。这是一个第三方客户端在用、官方文档未列出的键，可能随版本失效。"
        case .omitAttributionHeader:
            return "不把署名块（含客户端版本与提示指纹）放进系统提示开头。注意这个键的写法是反的——开启对应写入 0。"
        }
    }

    public var provenance: OptionProvenance {
        switch self {
        case .totalTokensReminderOff: return .thirdPartyImplementation
        default: return .officialDocumentation
        }
    }

    /// Flags that only take effect in a narrower context, worth surfacing in the interface.
    public var caveat: String? {
        switch self {
        case .emitSessionStateEvents:
            return "只在 Agent SDK 或 --print 流程里有意义，交互式终端里没有效果。"
        case .agentTeams:
            return "实验特性。"
        case .omitAttributionHeader:
            return "官方文档说明：直接连 Anthropic 时对缓存没有影响，但在部分直连场景下 Claude Code 会自行保留该块。"
        default:
            return nil
        }
    }
}

// MARK: - Choice settings

/// A setting whose value is one of a small set of strings, and whose absence is itself meaningful.
///
/// `ENABLE_TOOL_SEARCH` is the reason this exists: it accepts `true`, `auto`, `auto:N` and `false`,
/// where "unset" behaves differently again. A toggle would misrepresent it.
public enum EnvironmentChoice: String, Codable, CaseIterable, Sendable {
    case toolSearch
    case systemPrompt

    public var key: String {
        switch self {
        case .toolSearch: return "ENABLE_TOOL_SEARCH"
        case .systemPrompt: return "CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT"
        }
    }

    public var displayName: String {
        switch self {
        case .toolSearch: return "MCP 工具加载方式"
        case .systemPrompt: return "系统提示词长度"
        }
    }

    public var explanation: String {
        switch self {
        case .toolSearch:
            return "ANTHROPIC_BASE_URL 指向第三方主机时，Claude Code 默认会把 MCP 工具全部提前加载（tool search 被关掉）。选 true 可以让它继续按需延迟加载，通常能省下可观的上下文。"
        case .systemPrompt:
            return "在新模型上 Claude Code 默认用简版系统提示词。这里可以强制指定。"
        }
    }

    public var provenance: OptionProvenance {
        switch self {
        case .toolSearch, .systemPrompt: return .officialDocumentation
        }
    }

    /// The value written for a given option id. `nil` means "write nothing".
    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String
        public let value: String?
        public let label: String
        public let detail: String?

        public init(id: String, value: String?, label: String, detail: String? = nil) {
            self.id = id
            self.value = value
            self.label = label
            self.detail = detail
        }
    }

    /// The picker options, in the order they should be offered. The first is "leave unset".
    public var options: [Option] {
        switch self {
        case .toolSearch:
            return [
                Option(id: "unset", value: nil, label: "不设置（默认）",
                       detail: "接第三方后端时 MCP 工具会全部提前加载。"),
                Option(id: "true", value: "true", label: "true — 保持延迟加载",
                       detail: "即使指向第三方主机，也按需加载 MCP 工具。"),
                Option(id: "auto", value: "auto", label: "auto — 工具定义在上下文 10% 以内时提前加载",
                       detail: nil),
                Option(id: "auto5", value: "auto:5", label: "auto:5 — 阈值改为 5%",
                       detail: nil),
                Option(id: "false", value: "false", label: "false — 全部提前加载",
                       detail: nil)
            ]
        case .systemPrompt:
            return [
                Option(id: "unset", value: nil, label: "不设置（默认）",
                       detail: "由模型自行决定用完整还是简版提示词。"),
                Option(id: "simple", value: "1", label: "1 — 使用简版提示词（任何模型）",
                       detail: nil),
                Option(id: "full", value: "0", label: "0 — 使用完整提示词（任何模型）",
                       detail: nil)
            ]
        }
    }

    /// Which option id matches a value read back from the environment, if any.
    public func optionID(forValue value: String?) -> String {
        guard let value else { return "unset" }
        return options.first { $0.value == value }?.id ?? "custom"
    }
}

// MARK: - Numeric settings

/// A numeric setting, with the bounds the official documentation states so the interface can
/// refuse a value that would be silently ignored or rejected.
public enum NumericSetting: String, Codable, CaseIterable, Sendable {
    case maxOutputTokens
    case apiTimeoutMs
    case bashMaxTimeoutMs
    case autoCompactPercent

    public var key: String {
        switch self {
        case .maxOutputTokens: return "CLAUDE_CODE_MAX_OUTPUT_TOKENS"
        case .apiTimeoutMs: return "API_TIMEOUT_MS"
        case .bashMaxTimeoutMs: return "BASH_MAX_TIMEOUT_MS"
        case .autoCompactPercent: return "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
        }
    }

    public var displayName: String {
        switch self {
        case .maxOutputTokens: return "单次最大输出 tokens"
        case .apiTimeoutMs: return "API 超时"
        case .bashMaxTimeoutMs: return "Bash 命令最大超时"
        case .autoCompactPercent: return "触发自动压缩的百分比"
        }
    }

    public var unit: String {
        switch self {
        case .maxOutputTokens: return "tokens"
        case .apiTimeoutMs, .bashMaxTimeoutMs: return "ms"
        case .autoCompactPercent: return "%"
        }
    }

    public var explanation: String {
        switch self {
        case .maxOutputTokens:
            return "大多数请求的输出上限。默认值和上限随模型而变。"
        case .apiTimeoutMs:
            return "API 请求超时，默认 600000（10 分钟）。网络慢或经过中转时调大。"
        case .bashMaxTimeoutMs:
            return "模型能给前台 Bash / PowerShell 命令设置的最大超时，默认 600000（10 分钟）。"
        case .autoCompactPercent:
            return "自动压缩在上下文窗口用到百分之多少时触发（1–100）。填小一点会压缩得更早。官方文档说明它只能降低阈值、不能提高，高于默认值的设置会被忽略。"
        }
    }

    public var provenance: OptionProvenance {
        switch self {
        case .maxOutputTokens, .apiTimeoutMs, .bashMaxTimeoutMs, .autoCompactPercent:
            return .officialDocumentation
        }
    }

    /// Inclusive bounds, when the documentation states them.
    public var range: ClosedRange<Int>? {
        switch self {
        case .autoCompactPercent: return 1...100
        case .apiTimeoutMs: return 1...2_147_483_647
        case .maxOutputTokens, .bashMaxTimeoutMs: return 1...100_000_000
        }
    }

    public var placeholder: String {
        switch self {
        case .maxOutputTokens: return "例如 32000"
        case .apiTimeoutMs: return "例如 1200000"
        case .bashMaxTimeoutMs: return "例如 600000"
        case .autoCompactPercent: return "例如 87"
        }
    }

    /// Validates a raw string. Empty means "not set", which is always acceptable.
    public func validate(_ raw: String) -> NumericValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .ok(nil) }
        guard let value = Int(trimmed), value > 0 else {
            return .invalid("需要是一个正整数")
        }
        if let range, !range.contains(value) {
            return .invalid("取值需要在 " + String(range.lowerBound) + "–" + String(range.upperBound) + " 之间")
        }
        return .ok(trimmed)
    }
}

public enum NumericValidation: Equatable, Sendable {
    case ok(String?)
    case invalid(String)

    public var errorMessage: String? {
        if case let .invalid(message) = self { return message }
        return nil
    }

    public var normalizedValue: String? {
        if case let .ok(value) = self { return value }
        return nil
    }
}

// MARK: - Custom headers

/// The `ANTHROPIC_CUSTOM_HEADERS` setting, which is a newline-separated list of `Name: Value`.
///
/// Held as text because that is what the variable is, and because a relay service often needs a
/// header shape this app has no business modelling. What the app does owe the user is validation:
/// a malformed line produces a request that fails at the service, which is much harder to diagnose
/// than a complaint in the form.
public enum CustomHeaders {
    public static let key = "ANTHROPIC_CUSTOM_HEADERS"

    public struct Parsed: Equatable, Sendable {
        public var pairs: [(name: String, value: String)]
        public var problems: [String]

        public init(pairs: [(name: String, value: String)], problems: [String]) {
            self.pairs = pairs
            self.problems = problems
        }

        public static func == (lhs: Parsed, rhs: Parsed) -> Bool {
            lhs.problems == rhs.problems
                && lhs.pairs.count == rhs.pairs.count
                && zip(lhs.pairs, rhs.pairs).allSatisfy { $0.name == $1.name && $0.value == $1.value }
        }
    }

    /// Splits on the first colon of each line, the way an HTTP header is defined. A line without a
    /// colon, or with an empty name, is reported rather than silently dropped.
    public static func parse(_ text: String) -> Parsed {
        var pairs: [(String, String)] = []
        var problems: [String] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else {
                problems.append("第 " + String(index + 1) + " 行没有冒号：" + line)
                continue
            }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                problems.append("第 " + String(index + 1) + " 行的头部名称为空")
                continue
            }
            guard !value.isEmpty else {
                problems.append("第 " + String(index + 1) + " 行的值为空：" + name)
                continue
            }
            pairs.append((name, value))
        }
        return Parsed(pairs: pairs, problems: problems)
    }

    /// Renders the pairs back to the newline-separated form the variable expects.
    public static func render(_ pairs: [(name: String, value: String)]) -> String {
        pairs.map { $0.name + ": " + $0.value }.joined(separator: "\n")
    }
}
