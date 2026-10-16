import Foundation
import Combine
import ClaudeBridgerCore

/// The screen's state and every action it can take.
///
/// All the decisions live in `ClaudeBridgerCore`: this type holds state, calls the core, and
/// reports what happened. That split is what lets the interesting behaviour — what a write
/// touches, when a switch needs confirming, whether the button is live — be tested without
/// launching an app.
@MainActor
public final class AppModel: ObservableObject {

    // MARK: - Injected environment

    public let paths: ClaudePaths
    private let store: ConfigurationStore
    private let credentials: CredentialStore
    private let writer: ClaudeSettingsWriter
    private let autoBackupOnActivate = true

    // MARK: - Published state

    @Published public private(set) var configuration: ClaudeBridgerConfiguration
    /// The profile currently selected in the sidebar.
    @Published public var selectedProfileID: String?
    /// The profile being edited, including unsaved edits. nil when nothing is selected.
    @Published public var draft: BackendProfile?
    /// The draft's credential, held separately because it never lives in the profile value.
    @Published public var draftCredential: String = ""
    /// What the files currently say.
    @Published public private(set) var snapshot: SettingsSnapshot
    /// The last thing that happened, shown in the action bar.
    @Published public private(set) var notice: Notice?
    /// A confirmation the user has to answer before a switch proceeds.
    @Published public var pendingConfirmation: PendingConfirmation?
    /// Load-time problems, e.g. an unreadable state file.
    @Published public private(set) var loadError: String?
    @Published public var language: InterfaceLanguage = .system

    public struct Notice: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case success, warning, failure }
        public var kind: Kind
        public var title: String
        public var details: [String]

        public init(kind: Kind, title: String, details: [String] = []) {
            self.kind = kind
            self.title = title
            self.details = details
        }
    }

    public struct PendingConfirmation: Equatable, Sendable {
        public var title: String
        public var message: String
        public var confirmTitle: String
        public var profileID: String
    }

    // MARK: - Init

    public init(
        paths: ClaudePaths = ClaudePaths(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.store = ConfigurationStore(paths: paths, fileManager: fileManager)
        self.credentials = CredentialStore(paths: paths, fileManager: fileManager)
        self.writer = ClaudeSettingsWriter(paths: paths, fileManager: fileManager)
        self.snapshot = writer.snapshot()

        var loaded = ClaudeBridgerConfiguration()
        var loadFailure: String?
        do {
            loaded = try store.load()
        } catch {
            loadFailure = error.localizedDescription
        }
        self.configuration = loaded
        self.loadError = loadFailure
        self.language = loaded.interfaceLanguage
        self.selectedProfileID = loaded.profiles.first?.id
        self.refreshSnapshot()
    }

    /// An in-memory instance for previews and tests.
    public static func preview() -> AppModel {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claudebridger-preview", isDirectory: true)
        return AppModel(paths: ClaudePaths(configDirectory: base, homeDirectory: base))
    }

    // MARK: - Derived state

    public var profiles: [BackendProfile] {
        configuration.profiles.map { stored in
            stored.profile(credential: credentials.credential(forProfile: stored.id) ?? "")
        }
    }

    public func profile(id: String) -> BackendProfile? {
        guard let stored = configuration.profiles.first(where: { $0.id == id }) else { return nil }
        return stored.profile(credential: credentials.credential(forProfile: id) ?? "")
    }

    public var selectedProfile: BackendProfile? {
        selectedProfileID.flatMap { profile(id: $0) }
    }

    /// The backend Claude Code is currently pointed at, according to the file itself.
    ///
    /// Read from the file rather than from our own record, so a hand-edited settings.json is
    /// reported as what it is.
    public var activeBaseURL: String? { snapshot.baseURL }

    public var isDraftDirty: Bool {
        guard let draft, let saved = profile(id: draft.id) else { return draft != nil }
        var comparableDraft = draft
        comparableDraft.credential = ""
        var comparableSaved = saved
        comparableSaved.credential = ""
        return comparableDraft != comparableSaved
    }

    /// Whether the profile is the one in use and the file already holds exactly it.
    public func isAlreadyPublished(_ id: String) -> Bool {
        guard let published = configuration.publishedProfile, published.id == id else { return false }
        guard let stored = configuration.profiles.first(where: { $0.id == id }) else { return false }
        return published == stored && snapshot.baseURL == stored.baseURL
    }

    public func isActive(_ id: String) -> Bool {
        configuration.activeProfileID == id
    }

    public var activationAvailability: ActivationAction.Availability {
        guard let draft else {
            return ActivationAction.Availability(isEnabled: false, title: "启用", help: "先选择一个后端")
        }
        let warnings = ActivationGuard.baseURLWarnings(draft.baseURL)
        let hasBlockingError = warnings.contains { $0.contains("没有填写") || $0.contains("不是一个合法") }
        return ActivationAction.availability(
            hasBaseURL: !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isDirty: isDraftDirty,
            hasErrors: hasBlockingError,
            isAlreadyActive: isActive(draft.id),
            isAlreadyPublished: isAlreadyPublished(draft.id)
        )
    }

    // MARK: - Snapshot

    public func refreshSnapshot() {
        snapshot = writer.snapshot()
    }

    // MARK: - Selection

    public func selectProfile(_ id: String?) {
        selectedProfileID = id
        guard let id, let profile = profile(id: id) else {
            draft = nil
            draftCredential = ""
            return
        }
        draft = profile
        draftCredential = profile.credential
    }

    // MARK: - Saving (ClaudeBridger's own file only)

    /// Saves the draft to ClaudeBridger's own state file. Touches nothing Claude Code reads.
    @discardableResult
    public func saveDraft() -> Bool {
        guard let draft else { return false }
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            notice = Notice(kind: .failure, title: "名称不能为空")
            return false
        }
        var stored = draft
        stored.name = trimmedName

        var updated = configuration
        if let index = updated.profiles.firstIndex(where: { $0.id == stored.id }) {
            updated.profiles[index] = StoredProfile(stored)
        } else {
            updated.profiles.append(StoredProfile(stored))
        }
        do {
            try credentials.setCredential(draftCredential, forProfile: stored.id)
            try store.save(updated)
            configuration = updated
            self.draft = stored
            notice = Notice(kind: .success, title: "已保存")
            return true
        } catch {
            notice = Notice(kind: .failure, title: "保存失败", details: [error.localizedDescription])
            return false
        }
    }

    // MARK: - Activation

    /// The first half of 启用: work out whether this needs confirming, and either ask or go.
    public func requestActivation() {
        guard let draft else { return }
        guard saveDraft() else { return }

        let knownBaseURLs = Set(configuration.profiles.map(\.baseURL))
        let assessment = ActivationGuard.assess(
            currentBaseURL: snapshot.baseURL,
            targetBaseURL: draft.baseURL,
            targetName: draft.name,
            knownBaseURLs: knownBaseURLs
        )
        if assessment.requiresConfirmation {
            pendingConfirmation = PendingConfirmation(
                title: assessment.title,
                message: assessment.message,
                confirmTitle: assessment.confirmTitle,
                profileID: draft.id
            )
            return
        }
        performActivation(profileID: draft.id)
    }

    /// Confirms a switch the guard asked about.
    public func confirmPendingActivation() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        performActivation(profileID: pending.profileID)
    }

    public func cancelPendingActivation() {
        pendingConfirmation = nil
    }

    /// The second half: write the files, then verify what landed.
    public func performActivation(profileID: String) {
        guard let profile = profile(id: profileID) else { return }
        let credential = credentials.credential(forProfile: profileID) ?? ""
        do {
            let result = try writer.activate(
                profile: profile,
                credential: credential,
                writeOnboardingFlag: true
            )
            var updated = configuration
            updated.activeProfileID = profileID
            updated.publishedProfile = StoredProfile(profile)
            updated.wroteOnboardingFlag = result.wroteOnboardingFlag
            try? store.save(updated)
            configuration = updated
            refreshSnapshot()

            var details = result.warnings
            if configuration.verifyAfterWrite {
                details += writer.verify(expected: profile, credential: credential)
            }
            if let backup = result.backupSettingsURL {
                details.append("已备份原 settings.json：" + backup.lastPathComponent)
            }
            if result.wroteOnboardingFlag {
                details.append("已在 ~/.claude.json 写入 hasCompletedOnboarding")
            }
            notice = Notice(
                kind: details.contains { $0.contains("期望") || $0.contains("没有找到") } ? .warning : .success,
                title: "已接入 " + profile.name,
                details: details
            )
        } catch {
            refreshSnapshot()
            notice = Notice(kind: .failure, title: "写入失败", details: [error.localizedDescription])
        }
    }

    /// Removes every managed key from settings.json, returning Claude Code to its official
    /// defaults. A backup is taken first, as with any write.
    public func restoreOfficialConfiguration() {
        var updated = configuration
        let currentBaseURL = snapshot.baseURL ?? BackupManager.unknownProfileSegment
        let manager = BackupManager(paths: paths)
        var details: [String] = []
        do {
            if let backup = try manager.backup(paths.settingsJSON, kind: .settings, profile: currentBaseURL) {
                details.append("已备份：" + backup.lastPathComponent)
            }
            guard let data = try? Data(contentsOf: paths.settingsJSON),
                  let text = String(data: data, encoding: .utf8) else {
                // Nothing to restore from.
                updated.activeProfileID = nil
                updated.publishedProfile = nil
                try store.save(updated)
                configuration = updated
                refreshSnapshot()
                notice = Notice(kind: .success, title: "已恢复官方配置")
                return
            }
            var document = try JSONDocument(source: text)
            for key in ManagedEnvironment.clearableKeys.sorted() {
                try document.removeKey(key, inObjectAt: ["env"])
            }
            try AtomicFile.write(document.render(), to: paths.settingsJSON)
            updated.activeProfileID = nil
            updated.publishedProfile = nil
            try? store.save(updated)
            configuration = updated
            refreshSnapshot()
            notice = Notice(kind: .success, title: "已恢复官方配置", details: details)
        } catch {
            refreshSnapshot()
            notice = Notice(kind: .failure, title: "恢复失败", details: [error.localizedDescription])
        }
    }

    // MARK: - Profiles

    public func createProfile(from preset: BackendPreset) {
        var id = preset.id
        var suffix = 2
        while configuration.profiles.contains(where: { $0.id == id }) {
            id = preset.id + "-" + String(suffix)
            suffix += 1
        }
        let profile = preset.makeProfile(id: id)
        var updated = configuration
        updated.profiles.append(StoredProfile(profile))
        do {
            try store.save(updated)
            configuration = updated
            draft = profile
            draftCredential = ""
            selectedProfileID = id
            notice = Notice(kind: .success, title: "已新建 " + profile.name, details: ["填写凭据后点「启用」即可接入。"])
        } catch {
            notice = Notice(kind: .failure, title: "新建失败", details: [error.localizedDescription])
        }
    }

    public func deleteProfile(id: String) {
        var updated = configuration
        updated.profiles.removeAll { $0.id == id }
        if updated.activeProfileID == id { updated.activeProfileID = nil }
        if updated.publishedProfile?.id == id { updated.publishedProfile = nil }
        do {
            try store.save(updated)
            try credentials.prune(keeping: Set(updated.profiles.map(\.id)))
            configuration = updated
            if selectedProfileID == id {
                selectedProfileID = updated.profiles.first?.id
                selectProfile(selectedProfileID)
            }
            notice = Notice(kind: .success, title: "已删除")
        } catch {
            notice = Notice(kind: .failure, title: "删除失败", details: [error.localizedDescription])
        }
    }

    public func setLanguage(_ language: InterfaceLanguage) {
        self.language = language
        var updated = configuration
        updated.interfaceLanguage = language
        try? store.save(updated)
        configuration = updated
    }

    public func setVerifyAfterWrite(_ enabled: Bool) {
        var updated = configuration
        updated.verifyAfterWrite = enabled
        try? store.save(updated)
        configuration = updated
    }

    public func dismissNotice() {
        notice = nil
    }
}
