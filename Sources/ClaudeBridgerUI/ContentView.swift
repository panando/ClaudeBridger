import SwiftUI
import ClaudeBridgerCore

/// The window's root view. Public so the offscreen screenshot renderer can host it.
public struct ContentView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: Tokens.sidebarWidth, ideal: Tokens.sidebarWidth, max: 300)
        } detail: {
            DetailView(model: model)
        }
        .frame(minWidth: Tokens.windowMinWidth, minHeight: Tokens.windowMinHeight)
        .confirmationDialog(
            model.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.cancelPendingActivation() } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = model.pendingConfirmation {
                Button(pending.confirmTitle) { model.confirmPendingActivation() }
                Button(L.cancel(model.language), role: .cancel) { model.cancelPendingActivation() }
            }
        } message: {
            Text(model.pendingConfirmation?.message ?? "")
        }
        // Deletion asks with an alert rather than a second confirmationDialog: SwiftUI renders
        // only one confirmationDialog per view reliably, and silently dropping this one would be
        // worse than the extra chrome.
        .alert(
            model.pendingDeletion?.title ?? "",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.cancelDeletion() } }
            )
        ) {
            if let pending = model.pendingDeletion {
                Button(pending.confirmTitle, role: .destructive) { model.confirmDeletion() }
                Button(L.cancel(model.language), role: .cancel) { model.cancelDeletion() }
            }
        } message: {
            Text(model.pendingDeletion?.message ?? "")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(
                get: { model.selectedProfileID },
                set: { model.selectProfile($0) }
            )) {
                if model.profiles.isEmpty {
                    Text("还没有后端。点下面的「新建后端」开始。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Tokens.spacingS)
                }
                ForEach(groupedProfiles, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.profiles) { profile in
                            ProfileRow(model: model, profile: profile)
                                .tag(profile.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: Tokens.spacingS) {
                Menu {
                    ForEach(BackendPreset.groups(BackendPreset.builtIn)) { group in
                        Section(group.category) {
                            ForEach(group.presets) { preset in
                                Button(preset.name) { model.createProfile(from: preset) }
                            }
                        }
                    }
                } label: {
                    Label(L.newProfile(model.language), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help(L.settings(model.language))
            }
            .padding(Tokens.spacingM)
        }
    }

    private struct ProfileGroup {
        let category: String
        let profiles: [BackendProfile]
    }

    private var groupedProfiles: [ProfileGroup] {
        var order: [String] = []
        var buckets: [String: [BackendProfile]] = [:]
        for profile in model.profiles {
            if buckets[profile.category] == nil {
                order.append(profile.category)
                buckets[profile.category] = []
            }
            buckets[profile.category]?.append(profile)
        }
        return order.compactMap { category in
            guard let profiles = buckets[category], !profiles.isEmpty else { return nil }
            return ProfileGroup(category: category, profiles: profiles)
        }
    }
}

struct ProfileRow: View {
    @ObservedObject var model: AppModel
    let profile: BackendProfile

    public var body: some View {
        HStack(spacing: Tokens.spacingS) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .lineLimit(1)
                if let host = URL(string: profile.baseURL)?.host {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("未填写地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if model.isActive(profile.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(L.active(model.language))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var model: AppModel

    public var body: some View {
        if let draftBinding = Binding($model.draft) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.spacingL) {
                        header
                        if let notice = model.notice {
                            NoticeBar(notice: notice) { model.dismissNotice() }
                        }
                        ProfileFormView(
                            model: model,
                            draft: draftBinding,
                            credential: $model.draftCredential
                        )
                    }
                    .padding(Tokens.spacingXL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                ActionBar(model: model)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            EmptyStateView(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.draft?.name ?? "")
                    .font(.largeTitle.weight(.semibold))
                if let id = model.selectedProfileID, model.isActive(id) {
                    Text(L.active(model.language))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, Tokens.spacingS)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(.green)
                }
                Spacer()
                if let id = model.selectedProfileID {
                    Button(role: .destructive) {
                        model.requestDeletion(id: id)
                    } label: {
                        Label(L.delete(model.language), systemImage: "trash")
                    }
                    .help("从 ClaudeBridger 里删除这个后端。会先确认，不会直接删除。")
                }
            }
            StatusLine(model: model)
        }
    }
}

/// Always-visible statement of where Claude Code currently points, read from the file itself.
struct StatusLine: View {
    @ObservedObject var model: AppModel

    public var body: some View {
        HStack(spacing: Tokens.spacingS) {
            Image(systemName: model.activeBaseURL == nil ? "circle.dashed" : "arrow.right.circle.fill")
                .foregroundStyle(model.activeBaseURL == nil ? Color.secondary : Color.green)
            if let baseURL = model.activeBaseURL {
                Text("Claude Code 当前指向")
                    .foregroundStyle(.secondary)
                Text(baseURL)
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("Claude Code 还没有指向任何第三方后端（settings.json 里没有 ANTHROPIC_BASE_URL）")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refreshSnapshot()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("重新读取磁盘上的配置文件")
        }
        .font(.callout)
    }
}

/// The primary action, plus what it will do.
struct ActionBar: View {
    @ObservedObject var model: AppModel

    private var availability: ActivationAction.Availability { model.activationAvailability }

    public var body: some View {
        HStack(spacing: Tokens.spacingM) {
            Menu {
                Button(L.restoreOfficial(model.language)) {
                    model.restoreOfficialConfiguration()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("把 settings.json 里 ClaudeBridger 写入的那些键清除，回到官方默认。")

            Text(availability.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Tokens.spacingM)

            Button(L.save(model.language)) {
                model.saveDraft()
            }
            .disabled(!model.isDraftDirty)

            Button(availability.title) {
                model.requestActivation()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(!availability.isEnabled)
        }
        .padding(Tokens.spacingM)
        .background(.bar)
    }
}

struct EmptyStateView: View {
    @ObservedObject var model: AppModel

    public var body: some View {
        VStack(spacing: Tokens.spacingL) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("把 Claude Code 接到别的模型服务")
                .font(.title2.weight(.semibold))
            Text(L.appTagline(model.language))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Menu {
                ForEach(BackendPreset.groups(BackendPreset.builtIn)) { group in
                    Section(group.category) {
                        ForEach(group.presets) { preset in
                            Button(preset.name) { model.createProfile(from: preset) }
                        }
                    }
                }
            } label: {
                Label(L.newProfile(model.language), systemImage: "plus")
            }
            .fixedSize()
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
