import SwiftUI
import ClaudeBridgerCore

/// App-wide preferences. Deliberately small: everything about the backend lives in the main
/// window, and this pane holds only choices about the app itself.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            general
                .tabItem { Label("通用", systemImage: "gearshape") }
            about
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 340)
    }

    private var general: some View {
        Form {
            Section {
                Picker("界面语言", selection: Binding(
                    get: { model.language },
                    set: { model.setLanguage($0) }
                )) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Toggle("写入后回读校验", isOn: Binding(
                    get: { model.configuration.verifyAfterWrite },
                    set: { newValue in
                        model.setVerifyAfterWrite(newValue)
                    }
                ))
                .help("写完 settings.json 后重新读取，比对是否与预期一致。")
            } header: {
                Text("界面")
            }

            Section {
                LabeledContent("Claude 配置目录") {
                    PathLabel(path: model.paths.configDirectory.path)
                }
                LabeledContent("settings.json") {
                    PathLabel(path: model.paths.settingsJSON.path)
                }
                LabeledContent("全局配置") {
                    PathLabel(path: model.paths.claudeJSON.path)
                }
                LabeledContent("备份目录") {
                    PathLabel(path: model.paths.backupDirectory.path)
                }
            } header: {
                Text("文件位置")
            }

            Section {
                LabeledContent("已写入环境变量") {
                    Text("\(model.snapshot.managedKeysPresent.count) 个")
                }
                LabeledContent("env 里其他变量") {
                    Text("\(max(0, model.snapshot.totalEnvironmentKeys - model.snapshot.managedKeysPresent.count)) 个（不会被动）")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("当前状态")
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: Tokens.spacingM) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("ClaudeBridger")
                .font(.title2.weight(.semibold))
            Text(L.appTagline(model.language))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Text("只接终端里的 Claude Code（CLI）。桌面版 App 的第三方推理配置走的是另一套机制，本软件不涉及。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .padding(Tokens.spacingXL)
    }
}

/// A path with a copy button, because these paths are the ones a user pastes somewhere else.
struct PathLabel: View {
    let path: String

    var body: some View {
        HStack(spacing: Tokens.spacingXS) {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("复制路径")
        }
    }
}
