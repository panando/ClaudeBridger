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
