import SwiftUI
import ClaudeBridgerCore

/// The profile form: everything a backend needs, in the order a user thinks about it.
struct ProfileFormView: View {
    @ObservedObject var model: AppModel
    @Binding var draft: BackendProfile
    @Binding var credential: String
    /// True when this profile has never been written to a file.
    var isNew: Bool = false

    private var language: InterfaceLanguage { model.language }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingL) {
            SectionCard(
                title: L.baseURL(language),
                subtitle: L.onlyManagedKeys(language)
            ) {
                VStack(alignment: .leading, spacing: Tokens.spacingM) {
                    FormRow(
                        label: L.name(language),
                        help: "只用于这个软件里区分不同后端，不会写进 Claude Code 的配置。"
                    ) {
                        TextField("DeepSeek", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Tokens.fieldWidth)
                    }
                    FormRow(
                        label: L.baseURL(language),
                        help: "服务商提供的 Anthropic 兼容地址。不要以 /v1 结尾——Claude Code 会自己拼上 /v1/messages。"
                    ) {
                        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                            TextField("https://api.deepseek.com/anthropic", text: $draft.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 380)
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    FormRow(label: L.credentialMode(language), help: draft.credentialMode.explanation) {
                        Picker("", selection: $draft.credentialMode) {
                            ForEach(CredentialMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: Tokens.fieldWidth)
                    }
                    if draft.credentialMode != .none {
                        FormRow(
                            label: L.credential(language),
                            help: "会以明文写进 ~/.claude.json 同级的 settings.json，这是 Claude Code 读取凭据的方式。请勿把那个文件提交进仓库。"
                        ) {
                            SecureField("sk-…", text: $credential)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: Tokens.fieldWidth)
                        }
                    }
                }
            }

            SectionCard(
                title: L.models(language),
                subtitle: "Claude Code 会按场景分别调用不同档位的模型，只填主对话会让后台任务静默失败。"
            ) {
                VStack(alignment: .leading, spacing: Tokens.spacingM) {
                    ForEach(ModelTier.allCases, id: \.self) { tier in
                        FormRow(label: tier.displayName, help: tier.explanation) {
                            TextField(tierPlaceholder(tier), text: binding(for: tier))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 320)
                        }
                    }
                    Button("一键填满其余档位") {
                        fillEmptyTiers()
                    }
                    .disabled(draft.model(for: .primary) == nil)
                    .help("把主对话的模型名复制到还没有填写的档位上。")
                }
            }

            SectionCard(title: L.advanced(language), subtitle: "不填就交给服务商和 Claude Code 的默认值。") {
                VStack(alignment: .leading, spacing: Tokens.spacingM) {
                    FormRow(
                        label: L.contextWindow(language),
                        help: "写成 CLAUDE_CODE_AUTO_COMPACT_WINDOW 和 CLAUDE_CODE_MAX_CONTEXT_TOKENS。填错会导致过早压缩上下文或超出上限报错，不确定就留空。"
                    ) {
                        HStack(spacing: Tokens.spacingS) {
                            TextField("留空", text: contextWindowBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            Text("tokens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    FormRow(
                        label: "思考档位",
                        help: "写成 CLAUDE_CODE_EFFORT_LEVEL。复杂任务建议高一些。"
                    ) {
                        Picker("", selection: $draft.effortLevel) {
                            Text("不设置").tag(EffortLevel?.none)
                            ForEach(EffortLevel.allCases, id: \.self) { level in
                                Text(level.rawValue).tag(EffortLevel?.some(level))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    FormRow(
                        label: "关闭非必要流量",
                        help: "写成 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC。接第三方后端时建议保持开启。"
                    ) {
                        Toggle("", isOn: $draft.disableNonessentialTraffic)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var warnings: [String] {
        ActivationGuard.baseURLWarnings(draft.baseURL)
    }

    private func binding(for tier: ModelTier) -> Binding<String> {
        Binding(
            get: { draft.model(for: tier) ?? "" },
            set: { draft.setModel($0, for: tier) }
        )
    }

    private var contextWindowBinding: Binding<String> {
        Binding(
            get: { draft.contextWindow.map(String.init) ?? "" },
            set: { draft.contextWindow = Int($0.trimmingCharacters(in: .whitespaces)) }
        )
    }

    private func tierPlaceholder(_ tier: ModelTier) -> String {
        switch tier {
        case .primary: return "deepseek-v4-pro[1m]"
        case .opus, .sonnet: return "与服务商文档一致"
        case .haiku: return "deepseek-v4-flash"
        case .fable: return "可选"
        case .subagent: return "可选"
        }
    }

    private func fillEmptyTiers() {
        guard let primary = draft.model(for: .primary) else { return }
        for tier in ModelTier.allCases where draft.model(for: tier) == nil {
            draft.setModel(primary, for: tier)
        }
    }
}
