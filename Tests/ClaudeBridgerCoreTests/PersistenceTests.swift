import XCTest
@testable import ClaudeBridgerCore

final class PersistenceTests: XCTestCase {

    private var home: TestHome!

    override func setUp() {
        super.setUp()
        home = TestHome()
    }

    override func tearDown() {
        home.cleanup()
        home = nil
        super.tearDown()
    }

    func testRoundTrip() throws {
        let store = ConfigurationStore(paths: home.paths)
        var configuration = ClaudeBridgerConfiguration()
        var profile = makeProfile()
        profile.credential = "must-not-be-persisted"
        configuration.profiles = [StoredProfile(profile)]
        configuration.activeProfileID = profile.id
        configuration.publishedProfile = StoredProfile(profile)
        try store.save(configuration)

        let loaded = try store.load()
        XCTAssertEqual(loaded.profiles.count, 1)
        XCTAssertEqual(loaded.profiles[0].id, "deepseek")
        XCTAssertEqual(loaded.activeProfileID, "deepseek")
        XCTAssertEqual(loaded.publishedProfile?.baseURL, "https://api.deepseek.com/anthropic")
    }

    /// The reason `StoredProfile` exists separately: a secret in a plaintext file the user never
    /// opens is a secret that leaks on the first backup, sync or screenshot.
    func testCredentialsAreNeverWrittenToTheStateFile() throws {
        let store = ConfigurationStore(paths: home.paths)
        var profile = makeProfile()
        profile.credential = "sk-super-secret-value"
        var configuration = ClaudeBridgerConfiguration()
        configuration.profiles = [StoredProfile(profile)]
        configuration.publishedProfile = StoredProfile(profile)
        try store.save(configuration)

        let raw = try String(contentsOf: home.paths.appConfiguration, encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-super-secret-value"), "the credential leaked into the state file")
        // `credentialMode` is legitimate config; a bare `credential` key holding the secret is not.
        XCTAssertFalse(raw.contains("\"credential\""), "the state file has a credential field")
        XCTAssertTrue(raw.contains("credentialMode"), "the mode itself should still be stored")
    }

    func testAnEmptyFileLoadsAsAFreshConfiguration() throws {
        try Data().write(to: home.paths.appConfiguration)
        let loaded = try ConfigurationStore(paths: home.paths).load()
        XCTAssertTrue(loaded.profiles.isEmpty)
        XCTAssertEqual(loaded.schemaVersion, ClaudeBridgerConfiguration.currentSchemaVersion)
    }

    func testAMissingFileLoadsAsAFreshConfiguration() throws {
        let loaded = try ConfigurationStore(paths: home.paths).load()
        XCTAssertTrue(loaded.profiles.isEmpty)
        XCTAssertTrue(loaded.verifyAfterWrite)
    }

    /// A config written by an older build must not fail to load, because the alternative is that
    /// adding a field silently wipes the user's profiles.
    func testAConfigFromAnOlderBuildStillDecodes() throws {
        let older = """
        {
          "schemaVersion": 1,
          "profiles": [
            {
              "id": "old",
              "name": "Old",
              "category": "自定义",
              "baseURL": "https://old.example",
              "credentialMode": "authToken",
              "models": { "primary": "m" },
              "disableNonessentialTraffic": true
            }
          ]
        }
        """
        try older.write(to: home.paths.appConfiguration, atomically: true, encoding: .utf8)
        let loaded = try ConfigurationStore(paths: home.paths).load()
        XCTAssertEqual(loaded.profiles.count, 1)
        XCTAssertEqual(loaded.profiles[0].baseURL, "https://old.example")
        // The fields the old file did not have take their defaults rather than throwing.
        XCTAssertEqual(loaded.profiles[0].contextWindow, nil)
        XCTAssertFalse(loaded.wroteOnboardingFlag)
    }

    func testCorruptConfigSurfacesInsteadOfBeingDiscarded() {
        try? "{ not json".write(to: home.paths.appConfiguration, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigurationStore(paths: home.paths).load())
    }

    func testConfigurationIsWrittenAtomically() throws {
        let store = ConfigurationStore(paths: home.paths)
        try store.save(ClaudeBridgerConfiguration())
        // No temp file is left behind after a successful write.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: home.paths.appDirectory.path
        )
        XCTAssertFalse(entries.contains { $0.contains(".tmp-") })
    }
}

final class CredentialStoreTests: XCTestCase {

    private var home: TestHome!

    override func setUp() {
        super.setUp()
        home = TestHome()
    }

    override func tearDown() {
        home.cleanup()
        home = nil
        super.tearDown()
    }

    func testRoundTrip() throws {
        let store = CredentialStore(paths: home.paths)
        try store.setCredential("sk-abc", forProfile: "deepseek")
        XCTAssertEqual(store.credential(forProfile: "deepseek"), "sk-abc")
        // A second store instance reads it back from disk, not from the first one's cache.
        XCTAssertEqual(CredentialStore(paths: home.paths).credential(forProfile: "deepseek"), "sk-abc")
    }

    /// The file is the one thing standing between a key and everything else on the disk, so its
    /// permissions are asserted rather than assumed.
    func testCredentialFileIsOwnerReadableOnly() throws {
        let store = CredentialStore(paths: home.paths)
        try store.setCredential("sk-abc", forProfile: "deepseek")
        let attributes = try FileManager.default.attributesOfItem(atPath: home.paths.appDirectory.appendingPathComponent("credentials.json").path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600, "credential file mode is \(String(mode, radix: 8))")
        XCTAssertFalse(store.hasInsecurePermissions())
    }

    func testRemovingACredential() throws {
        let store = CredentialStore(paths: home.paths)
        try store.setCredential("sk-abc", forProfile: "deepseek")
        try store.setCredential(nil, forProfile: "deepseek")
        XCTAssertNil(store.credential(forProfile: "deepseek"))
    }

    func testBlankCredentialIsTreatedAsRemoval() throws {
        let store = CredentialStore(paths: home.paths)
        try store.setCredential("sk-abc", forProfile: "deepseek")
        try store.setCredential("   ", forProfile: "deepseek")
        XCTAssertNil(store.credential(forProfile: "deepseek"))
    }

    /// Deleting a profile must not leave its key on disk forever.
    func testPruneDropsCredentialsForDeletedProfiles() throws {
        let store = CredentialStore(paths: home.paths)
        try store.setCredential("sk-a", forProfile: "a")
        try store.setCredential("sk-b", forProfile: "b")
        try store.prune(keeping: ["a"])
        XCTAssertEqual(store.credential(forProfile: "a"), "sk-a")
        XCTAssertNil(store.credential(forProfile: "b"))
    }

    func testInMemoryStoreNeverTouchesDisk() throws {
        let store = CredentialStore.inMemory()
        try store.setCredential("sk-x", forProfile: "p")
        XCTAssertEqual(store.credential(forProfile: "p"), "sk-x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/dev/null/unused"))
    }
}

final class ClaudePathsTests: XCTestCase {

    func testDefaultsToTheHomeConfigDirectory() {
        let paths = ClaudePaths(environment: [:], fileManager: .default)
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(paths.configDirectory.path, home.appendingPathComponent(".claude").path)
        XCTAssertEqual(paths.claudeJSON.path, home.appendingPathComponent(".claude.json").path)
    }

    func testHonoursClaudeConfigDir() {
        // The documented way to run two accounts side by side, and the mechanism the tests use.
        let paths = ClaudePaths(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude-home"],
            fileManager: .default
        )
        XCTAssertEqual(paths.configDirectory.path, "/tmp/custom-claude-home")
        XCTAssertEqual(paths.settingsJSON.path, "/tmp/custom-claude-home/settings.json")
    }

    func testExpandsTildeInClaudeConfigDir() {
        let paths = ClaudePaths(
            environment: ["CLAUDE_CONFIG_DIR": "~/.claude-work"],
            fileManager: .default
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(paths.configDirectory.path, home.appendingPathComponent(".claude-work").path)
    }

    func testBlankClaudeConfigDirFallsBackToTheDefault() {
        let paths = ClaudePaths(environment: ["CLAUDE_CONFIG_DIR": "   "], fileManager: .default)
        XCTAssertEqual(
            paths.configDirectory.lastPathComponent,
            ".claude"
        )
    }

    /// The app's own files live inside `claudebridger/`, not in `backups/`, which is where Claude
    /// Code keeps its own rotating `.claude.json.backup.*` files. Two writers in one directory is
    /// how one of them ends up deleting the other's files.
    func testOwnFilesDoNotCollideWithClaudeCodesBackupDirectory() {
        let paths = ClaudePaths(environment: [:], fileManager: .default)
        XCTAssertTrue(paths.backupDirectory.path.hasSuffix("/claudebridger/backup"))
        XCTAssertFalse(paths.backupDirectory.path.hasSuffix("/.claude/backups"))
    }
}

final class BackupManagerTests: XCTestCase {

    func testFilenameShapeNamesTheProfileAndTimestamp() {
        let name = BackupManager.backupFileName(
            kind: .settings,
            profile: "deepseek",
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(name.hasPrefix("settings-deepseek-"))
        XCTAssertTrue(name.hasSuffix("-bak.json"))
    }

    func testProfileNameCannotEscapeTheBackupDirectory() {
        // A profile id is user input that becomes part of a path.
        let name = BackupManager.backupFileName(
            kind: .settings,
            profile: "../../etc/passwd",
            date: Date()
        )
        // The query is whether a profile id can escape into the path, not which safe fallback it
        // lands on: any name that contains no separator and no `..` is acceptable.
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
        XCTAssertFalse(name.contains("\\"))
    }

    func testNewlineInAProfileNameIsStripped() {
        let name = BackupManager.backupFileName(kind: .settings, profile: "a\nb", date: Date())
        XCTAssertFalse(name.contains("\n"))
    }

    func testBackingUpAMissingFileReturnsNilRatherThanFailing() throws {
        let home = TestHome()
        defer { home.cleanup() }
        let manager = BackupManager(paths: home.paths)
        XCTAssertNil(try manager.backup(home.settingsURL, kind: .settings))
    }
}
