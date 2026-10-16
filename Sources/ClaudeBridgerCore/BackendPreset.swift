import Foundation

// MARK: - Preset catalogue
//
// A preset ships only when its Anthropic-compatible endpoint could be confirmed against the
// vendor's own documentation. Vendors whose base URL is account- or region-scoped are included
// with the scope made explicit in the note rather than shipped as a URL that silently fails,
// because those are exactly the endpoints a user is most likely to paste in wrong.
//
// Model names move faster than anything else in this file. Every preset's note says so.

/// One model suggestion for a preset.
public struct PresetModel: Equatable, Sendable {
    public let slug: String
    /// The context window the vendor documents for this model, used to prefill the window field.
    public let contextWindow: Int
    /// The tier this model is the natural choice for, when a preset suggests one.
    public let tier: ModelTier?

    public init(slug: String, contextWindow: Int, tier: ModelTier? = nil) {
        self.slug = slug
        self.contextWindow = contextWindow
        self.tier = tier
    }
}

/// A known backend, used to prefill a new profile.
public struct BackendPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Sidebar group.
    public let category: String
    /// The vendor's Anthropic-compatible endpoint. Never ends in `/v1`.
    public let baseURL: String
    public let credentialMode: CredentialMode
    /// Suggested models, in the order they should be offered.
    public let models: [PresetModel]
    /// The context window to prefill, when the vendor documents one for its default model.
    public let contextWindow: Int?
    public let note: String
    /// Where the endpoint and model names were confirmed, kept so the table stays auditable.
    public let source: String

    public init(
        id: String,
        name: String,
        category: String,
        baseURL: String,
        credentialMode: CredentialMode = .authToken,
        models: [PresetModel] = [],
        contextWindow: Int? = nil,
        note: String,
        source: String
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.baseURL = baseURL
        self.credentialMode = credentialMode
        self.models = models
        self.contextWindow = contextWindow
        self.note = note
        self.source = source
    }

    /// Category used by profiles not created from a preset.
    public static let customCategory = "自定义"

    /// Builds a profile from this preset. Credentials are never prefilled.
    public func makeProfile(id: String) -> BackendProfile {
        var profile = BackendProfile(
            id: id,
            name: name,
            category: category,
            baseURL: baseURL,
            credentialMode: credentialMode,
            contextWindow: contextWindow
        )
        // Every tier defaults to the preset's preferred model: leaving a tier unset is what makes
        // the background tiers silently fail, so a preset fills all of them rather than making the
        // user discover the requirement from an error message.
        let primary = models.first(where: { $0.tier == .primary }) ?? models.first
        guard let primary else { return profile }
        for tier in ModelTier.allCases {
            let chosen = models.first(where: { $0.tier == tier }) ?? primary
            profile.setModel(chosen.slug, for: tier)
        }
        return profile
    }

    // MARK: - Catalogue

    public static let builtIn: [BackendPreset] = [
        BackendPreset(
            id: "deepseek",
            name: "DeepSeek",
            category: "国产大模型",
            baseURL: "https://api.deepseek.com/anthropic",
            models: [
                PresetModel(slug: "deepseek-v4-pro[1m]", contextWindow: 1_048_576, tier: .primary),
                PresetModel(slug: "deepseek-v4-flash", contextWindow: 1_048_576, tier: .haiku)
            ],
            contextWindow: 1_048_576,
            note: "官方支持 Anthropic 协议。它会把 claude-opus* 映射到自家 pro 模型、claude-sonnet*/claude-haiku* 映射到 flash 模型，所以即使模型名没配对也能跑。",
            source: "api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code（端点为 /anthropic，模型 deepseek-v4-pro / deepseek-v4-flash）"
        ),
        BackendPreset(
            id: "zhipu",
            name: "智谱 GLM",
            category: "国产大模型",
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            models: [
                PresetModel(slug: "glm-5-turbo", contextWindow: 204_800, tier: .primary)
            ],
            contextWindow: 204_800,
            note: "原生兼容 Anthropic 协议，不需要任何转换层。模型名变动频繁，填入前请到智谱文档确认当前可用的 GLM 版本。",
            source: "docs.bigmodel.cn/cn/guide/develop/claude（Anthropic 兼容端点 /api/anthropic）"
        ),
        BackendPreset(
            id: "moonshot",
            name: "Kimi / Moonshot 开放平台",
            category: "国产大模型",
            baseURL: "https://api.moonshot.cn/anthropic",
            models: [
                PresetModel(slug: "kimi-k3[1m]", contextWindow: 1_048_576, tier: .primary),
                PresetModel(slug: "kimi-k2.7-code", contextWindow: 262_144, tier: .haiku)
            ],
            contextWindow: 1_048_576,
            note: "开放平台按量计费，端点是 /anthropic。注意它和 Kimi Code 会员是两个平台，Key 不通用。",
            source: "platform.kimi.com/docs/guide/claude-code-kimi（端点 api.moonshot.cn/anthropic）"
        ),
        BackendPreset(
            id: "kimi-code",
            name: "Kimi Code（会员订阅）",
            category: "国产大模型",
            baseURL: "https://api.kimi.com/coding/",
            models: [
                PresetModel(slug: "k3-256k", contextWindow: 262_144, tier: .primary)
            ],
            contextWindow: 262_144,
            note: "会员制，端点结尾是 /coding/，不是开放平台的地址。这里的 Key 必须来自会员页面。",
            source: "www.kimi.com/code/docs/third-party-tools/claude-code（Anthropic 兼容 Base URL 国内 https://api.kimi.com/coding/）"
        ),
        BackendPreset(
            id: "dashscope",
            name: "阿里云百炼 · 通义 Qwen",
            category: "国产大模型",
            baseURL: "https://dashscope.aliyuncs.com/apps/anthropic",
            models: [
                PresetModel(slug: "qwen3-coder-plus", contextWindow: 204_800, tier: .primary)
            ],
            contextWindow: 204_800,
            note: "这是按量计费的端点。百炼还提供 Coding Plan 和 Token Plan 团队版，各自的 base_url 和专属 Key 必须配套使用，混用会报鉴权失败。",
            source: "help.aliyun.com/zh/model-studio/claude-code（按量计费 /apps/anthropic；Coding Plan 为 coding.dashscope.aliyuncs.com/apps/anthropic）"
        ),
        BackendPreset(
            id: "custom",
            name: "自定义 / 中转服务",
            category: "自定义",
            baseURL: "",
            models: [],
            contextWindow: nil,
            note: "任何实现了 Anthropic Messages API 的服务都可以。地址不要带 /v1 结尾，Claude Code 会自己拼 /v1/messages。",
            source: "code.claude.com/docs/en/llm-gateway-connect"
        )
    ]

    /// Groups presets by category, in catalogue order, dropping empty groups.
    public static func groups(_ presets: [BackendPreset]) -> [BackendPresetGroup] {
        var order: [String] = []
        var buckets: [String: [BackendPreset]] = [:]
        for preset in presets {
            if buckets[preset.category] == nil {
                order.append(preset.category)
                buckets[preset.category] = []
            }
            buckets[preset.category]?.append(preset)
        }
        return order.compactMap { category in
            guard let presets = buckets[category], !presets.isEmpty else { return nil }
            return BackendPresetGroup(category: category, presets: presets)
        }
    }
}

public struct BackendPresetGroup: Identifiable, Equatable, Sendable {
    public var id: String { category }
    public let category: String
    public let presets: [BackendPreset]

    public init(category: String, presets: [BackendPreset]) {
        self.category = category
        self.presets = presets
    }
}
