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
                        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                            FormRow(label: tier.displayName, help: tier.explanation) {
                                HStack(spacing: Tokens.spacingS) {
                                    TextField(tierPlaceholder(tier), text: binding(for: tier))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 320)
                                    // The checkbox edits the model string rather than a separate
                                    // field, so a model that already carries the suffix shows as
                                    // checked and there is no second value to disagree with.
                                    Toggle("1M", isOn: isOneMBinding(for: tier))
                                        .toggleStyle(.checkbox)
                                        .disabled(draft.model(for: tier) == nil)
                                        .help("在模型名后加上 " + ModelTier.oneMillionSuffix + " 后缀。这是给 Claude Code 的上下文窗口提示——实测 CLI 会在发请求前把它剥掉，服务商收到的是干净的模型名。")
                                }
                            }
                            // Only the four alias tiers have a display-name variable; the main
                            // conversation and subagent tiers have none, so no field is shown for
                            // them rather than one that would write a key Claude Code ignores.
                            if tier.supportsDisplayName {
                                FormRow(
                                    label: "  └ 显示名",
                                    help: "写进 " + (tier.displayNameKey ?? "") + "。只改 /model 选择器里显示的名字，不改变实际请求的模型。留空则使用模型名本身。"
                                ) {
                                    TextField("留空 = 用模型名", text: displayNameBinding(for: tier))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.body)
                                        .frame(width: 320)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing: Tokens.spacingS) {
                        Button("一键填满其余档位") {
                            fillEmptyTiers()
                        }
                        .disabled(draft.model(for: .primary) == nil)
                        .help("把主对话的模型名复制到还没有填写的档位上。")

                        Button("全部勾选 1M") {
                            for tier in ModelTier.allCases { draft.set1M(true, for: tier) }
                        }
                        .disabled(draft.models.isEmpty)
                        .help("给所有已填写的档位加上 " + ModelTier.oneMillionSuffix + " 后缀。")

                        Button("全部取消 1M") {
                            for tier in ModelTier.allCases { draft.set1M(false, for: tier) }
                        }
                        .disabled(!ModelTier.allCases.contains { draft.is1M(for: $0) })
                        .help("去掉所有档位的 " + ModelTier.oneMillionSuffix + " 后缀。")
                    }
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
                        help: "写成 CLAUDE_CODE_EFFORT_LEVEL。复杂任务建议高一些。注意 Claude Code 官方文档说明：这个环境变量的优先级高于 settings.json 顶层的 effortLevel 与 /effort 命令。"
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
                }
            }

            DisclosureSection(
                title: "行为开关",
                subtitle: "这些开关写成 Claude Code 的环境变量。关闭状态不会写入任何值——所以切换后端时上一个后端开启的开关会被清掉。",
                badge: flagsBadge
            ) {
                VStack(alignment: .leading, spacing: Tokens.spacingM) {
                    // The documented flags first, then the third-party-only ones, so an option
                    // whose provenance is weaker is never presented as if it were settled.
                    ForEach(documentedFlags, id: \.self) { flag in
                        FlagToggleRow(flag: flag, isOn: flagBinding(flag))
                    }
                    if !thirdPartyFlags.isEmpty {
                        Divider()
                        Text("以下键在主流第三方客户端里在用，但官方文档没有列出，可能随版本失效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(thirdPartyFlags, id: \.self) { flag in
                            FlagToggleRow(flag: flag, isOn: flagBinding(flag))
                        }
                    }
                    Divider()
                    Text("这些开关里只有「关闭非必要流量」对第三方后端是普遍建议的。其余大多数场景下应该保持关闭：它们要么只影响本地终端行为，字面含义并不改变模型选择。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureSection(
                title: "加载方式与提示词",
                subtitle: "这两项取值不是简单的开关，所以用下拉框。",
                badge: choicesBadge
            ) {
                VStack(alignment: .leading, spacing: Tokens.spacingM) {
                    ForEach(EnvironmentChoice.allCases, id: \.self) { choice in
                        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                            FormRow(label: choice.displayName, help: choice.explanation) {
                                Picker("", selection: choiceBinding(choice)) {
                                    ForEach(choice.options) { option in
                                        Text(option.label).tag(option.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 340)
                            }
                            if let detail = selectedOptionDetail(choice) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, Tokens.labelWidth + Tokens.spacingM)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(choice.key)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, Tokens.labelWidth + Tokens.spacingM)
                        }
                    }
                }
            }

            DisclosureSection(
                title: "超时与限额",
                subtitle: "留空就用 Claude Code 的默认值。填错可能导致请求被提前超时或报错，不确定就别填。",
                badge: numericsBadge
            ) {
                VStack(alignment: .leading, spacing: Tokens.spacingM) {
                    ForEach(NumericSetting.allCases, id: \.self) { setting in
                        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                            FormRow(label: setting.displayName, help: setting.explanation) {
                                HStack(spacing: Tokens.spacingS) {
                                    TextField(setting.placeholder, text: numericBinding(setting))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 140)
                                    Text(setting.unit)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let error = numericError(setting) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.leading, Tokens.labelWidth + Tokens.spacingM)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: Tokens.spacingXS) {
                        FormRow(
                            label: "自定义请求头",
                            help: "写成 ANTHROPIC_CUSTOM_HEADERS，每行一个 Name: Value。中转服务常需要它。"
                        ) {
                            TextEditor(text: $draft.customHeaders)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 340, height: 66)
                                .padding(2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Tokens.radiusS)
                                        .strokeBorder(Color(nsColor: .separatorColor))
                                )
                        }
                        if !draft.customHeaderProblems.isEmpty {
                            ForEach(Array(draft.customHeaderProblems.enumerated()), id: \.offset) { _, problem in
                                Label(problem, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Flag / choice / numeric helpers

    private var documentedFlags: [EnvironmentFlag] {
        EnvironmentFlag.allCases.filter { $0.provenance.isOfficial }
    }

    private var thirdPartyFlags: [EnvironmentFlag] {
        EnvironmentFlag.allCases.filter { !$0.provenance.isOfficial }
    }

    private var flagsBadge: String {
        draft.flags.isEmpty ? "" : "已开 " + String(draft.flags.count)
    }

    private var choicesBadge: String {
        draft.choices.isEmpty ? "" : "已设 " + String(draft.choices.count)
    }

    private var numericsBadge: String {
        var count = draft.numerics.count
        if draft.normalizedCustomHeaders != nil { count += 1 }
        return count == 0 ? "" : "已设 " + String(count)
    }

    private func flagBinding(_ flag: EnvironmentFlag) -> Binding<Bool> {
        Binding(
            get: { draft.isOn(flag) },
            set: { draft.setFlag(flag, on: $0) }
        )
    }

    private func choiceBinding(_ choice: EnvironmentChoice) -> Binding<String> {
        Binding(
            get: { choice.optionID(forValue: draft.choiceValue(choice)) },
            set: { newID in
                let value = choice.options.first { $0.id == newID }?.value
                draft.setChoice(choice, value: value)
            }
        )
    }

    private func selectedOptionDetail(_ choice: EnvironmentChoice) -> String? {
        let current = choice.optionID(forValue: draft.choiceValue(choice))
        return choice.options.first { $0.id == current }?.detail
    }

    private func numericBinding(_ setting: NumericSetting) -> Binding<String> {
        Binding(
            get: { draft.numericValue(setting) ?? "" },
            set: { draft.setNumeric(setting, value: $0) }
        )
    }

    private func numericError(_ setting: NumericSetting) -> String? {
        let raw = draft.numericValue(setting) ?? ""
        return setting.validate(raw).errorMessage
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

    private func isOneMBinding(for tier: ModelTier) -> Binding<Bool> {
        Binding(
            get: { draft.is1M(for: tier) },
            set: { draft.set1M($0, for: tier) }
        )
    }

    private func displayNameBinding(for tier: ModelTier) -> Binding<String> {
        Binding(
            get: { draft.displayName(for: tier) ?? "" },
            set: { draft.setDisplayName($0, for: tier) }
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
