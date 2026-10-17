import XCTest
import ClaudeBridgerCore
@testable import ClaudeBridgerUI

/// The screen's orchestration: which file a save touches, when a switch asks for confirmation, and
/// whether a write that failed is reported as a success. The decisions themselves live in Core and
/// are tested there; these check the wiring.
@MainActor
final class AppModelTests: XCTestCase {

    private var root: URL!
    private var configDirectory: URL!
    private var home: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claudebridger-ui-" + UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private func makeModel() -> AppModel {
        AppModel(paths: ClaudePaths(configDirectory: configDirectory, homeDirectory: home))
    }

    private func writeSettings(_ text: String) {
        try? text.write(
            to: configDirectory.appendingPathComponent("settings.json"),
            atomically: true, encoding: .utf8
        )
    }

    private func readSettings() -> String {
        (try? String(contentsOf: configDirectory.appendingPathComponent("settings.json"), encoding: .utf8)) ?? ""
    }

    // MARK: - Saving touches only our own file

    func testSavingDoesNotWriteAnythingClaudeCodeReads() throws {
        writeSettings("{\n  \"env\": { \"MY_VAR\": \"untouched\" }\n}\n")
        let before = readSettings()

        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"
        XCTAssertTrue(model.saveDraft())

        // 保存 writes ClaudeBridger's state only. Claude Code's file is byte-identical.
        XCTAssertEqual(readSettings(), before)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configDirectory.appendingPathComponent("claudebridger/config.json").path
        ))
    }

    func testActivationWritesTheFilesAndReportsSuccess() throws {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"

        model.requestActivation()

        // No confirmation on a fresh machine, so the write already happened.
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.notice?.kind, .success)
        let settings = readSettings()
        XCTAssertTrue(settings.contains("https://api.deepseek.com/anthropic"))
        XCTAssertTrue(settings.contains("sk-ui-test"))
        XCTAssertEqual(model.activeBaseURL, "https://api.deepseek.com/anthropic")
    }

    func testABlockedWriteIsReportedAsAFailureAndTheFileIsUntouched() throws {
        let broken = "{\n  \"env\": { \"a\": 1,\n} garbage"
        writeSettings(broken)

        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"
        model.requestActivation()

        XCTAssertEqual(model.notice?.kind, .failure)
        XCTAssertEqual(readSettings(), broken, "a refused write must leave the file alone")
    }

    // MARK: - The confirmation gate

    func testTakingOverAHandEditedConfigAsksFirst() throws {
        writeSettings("{\n  \"env\": { \"ANTHROPIC_BASE_URL\": \"https://hand-edited.example\" }\n}\n")
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"

        model.requestActivation()

        let pending = try XCTUnwrap(model.pendingConfirmation)
        XCTAssertTrue(pending.message.contains("hand-edited.example"))
        // Nothing was written yet.
        XCTAssertTrue(readSettings().contains("hand-edited.example"))

        model.confirmPendingActivation()
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertTrue(readSettings().contains("https://api.deepseek.com/anthropic"))
    }

    func testCancellingAConfirmationWritesNothing() throws {
        let original = "{\n  \"env\": { \"ANTHROPIC_BASE_URL\": \"https://hand-edited.example\" }\n}\n"
        writeSettings(original)
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"
        model.requestActivation()
        model.cancelPendingActivation()

        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(readSettings(), original)
        XCTAssertEqual(model.notice?.kind, .success, "saving still succeeded; only the write was declined")
    }

    func testSwitchingBetweenOurOwnProfilesDoesNotAsk() throws {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-one"
        model.requestActivation()
        XCTAssertNil(model.pendingConfirmation)

        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "zhipu" }!)
        model.selectProfile(model.profiles.last?.id)
        model.draftCredential = "sk-two"
        model.requestActivation()

        XCTAssertNil(model.pendingConfirmation, "both endpoints are ours, so this is not a takeover")
        XCTAssertTrue(readSettings().contains("open.bigmodel.cn"))
    }

    // MARK: - Button state

    func testAnAppliedProfileGoesFlatAndComesBackWhenChanged() throws {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"

        // Before any write there is something to apply.
        XCTAssertTrue(model.activationAvailability.isEnabled)

        model.requestActivation()

        // The write landed and the file now holds exactly this profile, so there is nothing left to
        // apply and the button settles. Re-pressing it would only re-write the same bytes and take
        // another backup.
        XCTAssertFalse(
            model.activationAvailability.isEnabled,
            "nothing left to apply: " + model.activationAvailability.help
        )

        // A change brings it back, and the path is: edit, save, then the button is live again.
        model.draft?.setModel("deepseek-v4-flash", for: .opus)
        XCTAssertTrue(model.isDraftDirty)
        XCTAssertFalse(model.activationAvailability.isEnabled, "dirty blocks until saved")
        model.saveDraft()
        XCTAssertTrue(model.isDraftDirty == false)
        XCTAssertTrue(model.activationAvailability.isEnabled)

        model.requestActivation()
        XCTAssertFalse(model.activationAvailability.isEnabled, "applied again, so flat again")
    }

    func testAnEmptyBaseURLBlocksTheButton() {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "custom" }!)
        model.selectProfile(model.profiles.first?.id)
        XCTAssertFalse(model.activationAvailability.isEnabled)
    }

    // MARK: - Deletion

    func testDeletingAProfileDoesNotTouchClaudeCodesConfig() throws {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"
        model.requestActivation()
        let afterActivation = readSettings()

        model.deleteProfile(id: model.profiles.first!.id)

        XCTAssertTrue(model.profiles.isEmpty)
        // Deleting from this app's list is not the same as un-configuring Claude Code: the user has
        // to say so explicitly with 恢复官方配置.
        XCTAssertEqual(readSettings(), afterActivation)
    }

    func testDeletingAProfilePrunesItsCredential() throws {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        let id = model.profiles.first!.id
        model.selectProfile(id)
        model.draftCredential = "sk-ui-test"
        model.saveDraft()

        model.deleteProfile(id: id)

        let credentials = CredentialStore(paths: ClaudePaths(configDirectory: configDirectory, homeDirectory: home))
        XCTAssertNil(credentials.credential(forProfile: id), "the key must not outlive the profile")
    }

    // MARK: - Restore

    func testRestoreRemovesEveryManagedKeyAndKeepsTheRest() throws {
        writeSettings("""
        {
          "env": { "MY_VAR": "keep" },
          "permissions": { "allow": ["Bash(npm test)"] }
        }
        """)
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"
        model.requestActivation()

        model.restoreOfficialConfiguration()

        let settings = readSettings()
        XCTAssertFalse(settings.contains("ANTHROPIC_BASE_URL"))
        XCTAssertFalse(settings.contains("ANTHROPIC_AUTH_TOKEN"))
        XCTAssertTrue(settings.contains("\"MY_VAR\": \"keep\""), "the user's own variable survives")
        XCTAssertTrue(settings.contains("Bash(npm test)"))
        XCTAssertNil(model.activeBaseURL, "the status line must reflect the file, not our record")
        // The file has to still be parseable after a run of removals.
        XCTAssertNoThrow(try JSONDocument(source: settings))
    }

    func testRestoreTakesABackup() throws {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"
        model.requestActivation()

        model.restoreOfficialConfiguration()

        let backups = BackupManager(paths: ClaudePaths(configDirectory: configDirectory, homeDirectory: home))
            .listBackups()
        XCTAssertFalse(backups.isEmpty, "every write is reversible, including the restore")
    }

    // MARK: - Status is read from the file

    func testStatusReflectsAHandEditNotOurRecord() throws {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-ui-test"
        model.requestActivation()
        XCTAssertEqual(model.activeBaseURL, "https://api.deepseek.com/anthropic")

        // Something else changes the file behind our back.
        writeSettings("{\n  \"env\": { \"ANTHROPIC_BASE_URL\": \"https://manually-changed.example\" }\n}\n")
        model.refreshSnapshot()

        XCTAssertEqual(model.activeBaseURL, "https://manually-changed.example")
    }
}

/// Regression: reopening the app with a saved configuration left the detail pane empty.
///
/// `init` restored `selectedProfileID` but never populated `draft`, so the sidebar showed a row as
/// selected while `DetailView` — which gates on `draft` — drew the empty state. Clicking the row
/// did nothing either, because SwiftUI does not call a selection setter when the value is
/// unchanged, so the already-set id never reached `selectProfile`.
@MainActor
final class RelaunchSelectionTests: XCTestCase {

    private var root: URL!
    private var configDirectory: URL!
    private var home: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claudebridger-relaunch-" + UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private func paths() -> ClaudePaths {
        ClaudePaths(configDirectory: configDirectory, homeDirectory: home)
    }

    /// Builds a model, saves a profile, and returns a fresh model — as a relaunch would.
    private func makeRelaunchedModel() -> AppModel {
        let first = AppModel(paths: paths())
        first.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        first.selectProfile(first.profiles.first?.id)
        first.draftCredential = "sk-relaunch-test"
        XCTAssertTrue(first.saveDraft())

        return AppModel(paths: paths())
    }

    func testRelaunchSelectsAProfileAndShowsItsDetails() {
        let model = makeRelaunchedModel()

        XCTAssertEqual(model.profiles.count, 1, "the saved profile must survive a relaunch")
        XCTAssertNotNil(model.selectedProfileID, "a profile should be selected on launch")
        XCTAssertNotNil(
            model.draft,
            "draft must be populated on launch, or the detail pane renders the empty state"
        )
        XCTAssertEqual(model.draft?.name, "DeepSeek")
        XCTAssertEqual(model.draft?.baseURL, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(model.draftCredential, "sk-relaunch-test", "the stored credential must come back too")
    }

    func testRelaunchWithNoProfilesShowsTheEmptyState() {
        let model = AppModel(paths: paths())
        XCTAssertNil(model.selectedProfileID)
        XCTAssertNil(model.draft)
    }

    /// Re-selecting the row that is already selected must populate the draft, because that is
    /// exactly what the user does when the pane looks empty.
    func testReselectingTheSameProfileStillPopulatesTheDraft() {
        let model = makeRelaunchedModel()
        let id = try! XCTUnwrap(model.selectedProfileID)

        model.draft = nil
        model.draftCredential = ""
        XCTAssertNil(model.draft)

        model.selectProfile(id)
        XCTAssertNotNil(model.draft, "re-selecting an already-selected profile must load it")
    }
}

/// Deletion must never happen without a confirmation.
///
/// Deleting is the one action that destroys something the user typed and that no file on disk can
/// restore: the credential is pruned along with the profile.
@MainActor
final class DeletionConfirmationTests: XCTestCase {

    private var root: URL!
    private var configDirectory: URL!
    private var home: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claudebridger-delete-" + UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        configDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    private func makeModel() -> AppModel {
        AppModel(paths: ClaudePaths(configDirectory: configDirectory, homeDirectory: home))
    }

    private func seededModel() -> AppModel {
        let model = makeModel()
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "deepseek" }!)
        model.selectProfile(model.profiles.first?.id)
        model.draftCredential = "sk-delete-test"
        model.saveDraft()
        return model
    }

    func testRequestingDeletionRemovesNothing() {
        let model = seededModel()
        let id = model.profiles.first!.id

        model.requestDeletion(id: id)

        XCTAssertNotNil(model.pendingDeletion, "a confirmation must be raised")
        XCTAssertEqual(model.profiles.count, 1, "nothing may be removed before confirmation")
    }

    func testConfirmingDeletionRemovesTheProfile() {
        let model = seededModel()
        let id = model.profiles.first!.id
        model.requestDeletion(id: id)

        model.confirmDeletion()

        XCTAssertNil(model.pendingDeletion)
        XCTAssertTrue(model.profiles.isEmpty)
    }

    func testCancellingDeletionKeepsTheProfile() {
        let model = seededModel()
        let id = model.profiles.first!.id
        model.requestDeletion(id: id)

        model.cancelDeletion()

        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(model.profiles.count, 1, "cancelling must keep the profile")
        // The credential survives too, because nothing was pruned.
        let credentials = CredentialStore(paths: ClaudePaths(configDirectory: configDirectory, homeDirectory: home))
        XCTAssertEqual(credentials.credential(forProfile: id), "sk-delete-test")
    }

    func testTheConfirmationSaysDeletionIsIrreversible() {
        let model = seededModel()
        model.requestDeletion(id: model.profiles.first!.id)
        let pending = try! XCTUnwrap(model.pendingDeletion)
        XCTAssertTrue(pending.message.contains("无法撤销"))
        XCTAssertTrue(pending.message.contains("DeepSeek"), "it should name the profile")
        XCTAssertEqual(pending.confirmTitle, "删除")
    }

    /// Deleting the active backend does not undo the configuration it wrote, and the dialog has to
    /// say so — otherwise someone deletes it expecting the endpoint to revert.
    func testTheConfirmationForTheActiveProfileExplainsWhatItDoesNotDo() {
        let model = seededModel()
        model.requestActivation()
        model.confirmPendingActivation()
        XCTAssertTrue(model.isActive(model.profiles.first!.id))

        model.requestDeletion(id: model.profiles.first!.id)

        let pending = try! XCTUnwrap(model.pendingDeletion)
        XCTAssertTrue(pending.isActive)
        XCTAssertTrue(
            pending.message.contains("settings.json"),
            "it must explain that the written configuration stays"
        )
        XCTAssertTrue(pending.message.contains("恢复官方配置"), "and point at the way to undo it")
    }

    func testDeletingAnInactiveProfileSaysItDoesNotTouchClaudeCode() {
        let model = seededModel()
        model.requestActivation()
        model.confirmPendingActivation()
        // A second profile, never activated.
        model.createProfile(from: BackendPreset.builtIn.first { $0.id == "zhipu" }!)
        let inactiveID = model.profiles.last!.id

        model.requestDeletion(id: inactiveID)

        let pending = try! XCTUnwrap(model.pendingDeletion)
        XCTAssertFalse(pending.isActive)
        XCTAssertTrue(pending.message.contains("不会改动 Claude Code"))
    }

    func testRequestingDeletionForAnUnknownProfileDoesNothing() {
        let model = seededModel()
        model.requestDeletion(id: "does-not-exist")
        XCTAssertNil(model.pendingDeletion)
    }
}
