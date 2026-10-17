import XCTest
@testable import ClaudeBridgerCore

/// The promise the app makes to the user: your settings survive, and every write is reversible.
final class ClaudeSettingsWriterTests: XCTestCase {

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

    private func writer() -> ClaudeSettingsWriter {
        ClaudeSettingsWriter(paths: home.paths)
    }

    // MARK: - The safety promise

    func testWritePreservesEveryUnmanagedKey() throws {
        // A settings.json that looks like a real one: the user's own variables sit in the same
        // `env` object the app writes to, and everything else in the file must be untouched.
        home.write(settings: """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "env": {
            "HTTPS_PROXY": "http://127.0.0.1:7890",
            "API_TIMEOUT_MS": "1200000",
            "MY_OWN_VAR": "keep me"
          },
          "permissions": {
            "allow": ["Bash(npm test)", "Read(//tmp/**)"],
            "deny": ["Bash(rm -rf /)"]
          },
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [{ "type": "command", "command": "echo hi" }] }
            ]
          },
          "statusLine": { "type": "command", "command": "my-status" }
        }
        """)

        let profile = makeProfile()
        _ = try writer().activate(profile: profile, credential: "sk-secret", writeOnboardingFlag: false)

        let rendered = home.read()
        let env = home.environment(in: rendered)
        // Unmanaged variables survive, byte for byte.
        XCTAssertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7890")
        XCTAssertEqual(env["API_TIMEOUT_MS"], "1200000")
        XCTAssertEqual(env["MY_OWN_VAR"], "keep me")
        // Unmanaged top-level keys survive, including their nesting.
        XCTAssertTrue(rendered.contains("Bash(npm test)"))
        XCTAssertTrue(rendered.contains("Bash(rm -rf /)"))
        XCTAssertTrue(rendered.contains("PreToolUse"))
        XCTAssertTrue(rendered.contains("my-status"))
        XCTAssertTrue(rendered.contains("schemastore"))
        // And the managed keys landed.
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://api.deepseek.com/anthropic")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "sk-secret")
        XCTAssertNotNil(home.parseJSON(rendered))
    }

    func testSwitchClearsThePreviousBackendsKeys() throws {
        home.write(settings: """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://old.example",
            "ANTHROPIC_MODEL": "old-model",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "old-opus",
            "KEEP_ME": "yes"
          }
        }
        """)

        var next = BackendProfile(id: "next", name: "Next", baseURL: "https://new.example")
        next.setModel("new-primary", for: .primary)
        _ = try writer().activate(profile: next, credential: "sk-new", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://new.example")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "new-primary")
        // The tier the new profile does not set is cleared, so the old backend's model name cannot
        // be requested from the new endpoint.
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"])
        XCTAssertEqual(env["KEEP_ME"], "yes")
    }

    func testSwitchingCredentialModeRemovesTheConflictingVariable() throws {
        // The documented cause of 401s: both credential variables present at once.
        home.write(settings: """
        {
          "env": {
            "ANTHROPIC_API_KEY": "sk-from-api-key"
          }
        }
        """)

        var profile = makeProfile()
        profile.credentialMode = .authToken
        _ = try writer().activate(profile: profile, credential: "sk-token", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "sk-token")
        XCTAssertNil(env["ANTHROPIC_API_KEY"], "the conflicting variable must be cleared")
    }

    func testEverythingIsBackedUpBeforeItIsReplaced() throws {
        home.write(settings: "{\n  \"env\": { \"ANTHROPIC_BASE_URL\": \"https://old.example\" }\n}\n")
        home.write(claudeJSON: "{\n  \"hasCompletedOnboarding\": true,\n  \"mcpServers\": {}\n}\n")

        let result = try writer().activate(
            profile: makeProfile(), credential: "sk", writeOnboardingFlag: false
        )

        let backupSettings = try XCTUnwrap(result.backupSettingsURL)
        let backupGlobal = try XCTUnwrap(result.backupGlobalConfigURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupSettings.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupGlobal.path))
        // The backup holds what was there before, not what was just written.
        let backedUp = try String(contentsOf: backupSettings, encoding: .utf8)
        XCTAssertTrue(backedUp.contains("https://old.example"))
        let backedUpGlobal = try String(contentsOf: backupGlobal, encoding: .utf8)
        XCTAssertTrue(backedUpGlobal.contains("mcpServers"))
    }

    func testBackupIsTakenEvenWhenSwitchingBetweenManagedProfiles() throws {
        // The trap this guards against: treating our own previous write as "safe to skip", which
        // leaves the only destructive action as the only one with no way back.
        _ = try writer().activate(
            profile: makeProfile(id: "a", baseURL: "https://a.example"),
            credential: "sk-a",
            writeOnboardingFlag: false
        )
        let second = try writer().activate(
            profile: makeProfile(id: "b", baseURL: "https://b.example"),
            credential: "sk-b",
            writeOnboardingFlag: false
        )
        let backup = try XCTUnwrap(second.backupSettingsURL)
        let contents = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(contents.contains("https://a.example"))
    }

    func testBackupsNeverOverwriteEachOther() throws {
        home.write(settings: "{\n  \"env\": {}\n}\n")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = BackupManager(paths: home.paths)
        let first = try manager.backup(home.settingsURL, kind: .settings, profile: "x", now: fixed)
        let second = try manager.backup(home.settingsURL, kind: .settings, profile: "x", now: fixed)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.path, second?.path)
        XCTAssertEqual(manager.listBackups().count, 2)
    }

    // MARK: - Refusals

    func testUnparseableSettingsIsRefusedNotOverwritten() throws {
        let broken = "{\n  \"env\": { \"ANTHROPIC_BASE_URL\": \"https://a.example\",\n}\n" + "garbage"
        home.write(settings: broken)
        XCTAssertThrowsError(
            try writer().activate(profile: makeProfile(), credential: "sk", writeOnboardingFlag: false)
        ) { error in
            guard case ClaudeSettingsWriter.WriterError.settingsFileUnparseable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        // The file is exactly as it was: a tool must never "repair" a config by discarding it.
        XCTAssertEqual(home.read(), broken)
    }

    func testEnvThatIsNotAnObjectIsRefused() throws {
        let original = "{\n  \"env\": \"oops\"\n}\n"
        home.write(settings: original)
        XCTAssertThrowsError(
            try writer().activate(profile: makeProfile(), credential: "sk", writeOnboardingFlag: false)
        ) { error in
            guard case ClaudeSettingsWriter.WriterError.environmentNotAnObject = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(home.read(), original)
    }

    func testMissingBaseURLIsRefused() {
        var profile = makeProfile()
        profile.baseURL = "   "
        XCTAssertThrowsError(
            try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        )
    }

    func testMissingCredentialIsRefusedWhenTheModeNeedsOne() {
        let profile = makeProfile()
        XCTAssertThrowsError(
            try writer().activate(profile: profile, credential: "  ", writeOnboardingFlag: false)
        )
    }

    // MARK: - The onboarding flag

    func testOnboardingFlagIsWrittenIntoTheGlobalConfig() throws {
        home.write(claudeJSON: "{\n  \"mcpServers\": { \"x\": {} },\n  \"theme\": \"dark\"\n}\n")
        let result = try writer().activate(
            profile: makeProfile(), credential: "sk", writeOnboardingFlag: true
        )
        XCTAssertTrue(result.wroteOnboardingFlag)
        let global = home.parseJSON(home.readClaudeJSON())
        XCTAssertEqual(global?["hasCompletedOnboarding"] as? Bool, true)
        // The rest of a file that holds the sign-in session must survive.
        XCTAssertNotNil(global?["mcpServers"])
        XCTAssertEqual(global?["theme"] as? String, "dark")
    }

    func testOnboardingFlagIsNotRewrittenWhenAlreadySet() throws {
        home.write(claudeJSON: "{\n  \"hasCompletedOnboarding\": true\n}\n")
        let before = home.readClaudeJSON()
        let result = try writer().activate(
            profile: makeProfile(), credential: "sk", writeOnboardingFlag: true
        )
        XCTAssertFalse(result.wroteOnboardingFlag)
        XCTAssertEqual(home.readClaudeJSON(), before)
    }

    func testOnboardingFlagIsCreatedWhenTheFileIsMissing() throws {
        let result = try writer().activate(
            profile: makeProfile(), credential: "sk", writeOnboardingFlag: true
        )
        XCTAssertTrue(result.wroteOnboardingFlag)
        let global = home.parseJSON(home.readClaudeJSON())
        XCTAssertEqual(global?["hasCompletedOnboarding"] as? Bool, true)
    }

    func testUnparseableGlobalConfigIsSkippedWithAWarningAndSettingsStillLand() throws {
        home.write(claudeJSON: "this is not json at all")
        let result = try writer().activate(
            profile: makeProfile(), credential: "sk", writeOnboardingFlag: true
        )
        XCTAssertFalse(result.wroteOnboardingFlag)
        XCTAssertFalse(result.warnings.isEmpty, "the user has to be told the flag was skipped")
        // The global config is left alone; the settings that did work still landed.
        XCTAssertEqual(home.readClaudeJSON(), "this is not json at all")
        XCTAssertEqual(
            home.environment(in: home.read())["ANTHROPIC_BASE_URL"],
            "https://api.deepseek.com/anthropic"
        )
    }

    // MARK: - Snapshot

    func testSnapshotReportsWhatIsThere() throws {
        home.write(settings: """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://a.example",
            "ANTHROPIC_MODEL": "m",
            "MY_VAR": "x"
          }
        }
        """)
        let snapshot = writer().snapshot()
        XCTAssertTrue(snapshot.fileExists)
        XCTAssertFalse(snapshot.isUnparseable)
        XCTAssertEqual(snapshot.baseURL, "https://a.example")
        XCTAssertEqual(snapshot.models[ModelTier.primary.rawValue], "m")
        XCTAssertEqual(snapshot.totalEnvironmentKeys, 3)
        XCTAssertTrue(snapshot.managedKeysPresent.contains("ANTHROPIC_BASE_URL"))
        XCTAssertFalse(snapshot.managedKeysPresent.contains("MY_VAR"))
    }

    func testSnapshotOnAMissingFile() {
        let snapshot = writer().snapshot()
        XCTAssertFalse(snapshot.fileExists)
        XCTAssertNil(snapshot.baseURL)
    }

    // MARK: - Verification

    func testVerificationPassesAfterAGoodWrite() throws {
        _ = try writer().activate(profile: makeProfile(), credential: "sk", writeOnboardingFlag: false)
        let problems = writer().verify(expected: makeProfile(), credential: "sk")
        XCTAssertEqual(problems, [])
    }

    func testVerificationCatchesATamperedFile() throws {
        _ = try writer().activate(profile: makeProfile(), credential: "sk", writeOnboardingFlag: false)
        // Simulate something else rewriting the file after the write.
        home.write(settings: "{\n  \"env\": { \"ANTHROPIC_BASE_URL\": \"https://someone-else.example\" }\n}\n")
        let problems = writer().verify(expected: makeProfile(), credential: "sk")
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.contains { $0.contains("base_url") })
    }

    // MARK: - Repeatability

    func testActivatingTwiceWithTheSameProfileIsStable() throws {
        let profile = makeProfile()
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        let first = home.read()
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        XCTAssertEqual(home.read(), first, "re-activating must not keep growing the file")
    }

    func testWrittenValuesMatchTheProfilesDeclaredEnvironment() throws {
        let profile = makeProfile()
        _ = try writer().activate(profile: profile, credential: "sk-secret", writeOnboardingFlag: false)
        let env = home.environment(in: home.read())
        for (key, value) in profile.environmentValues() {
            XCTAssertEqual(env[key], value, "mismatch for \(key)")
        }
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        XCTAssertEqual(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1048576")
    }
}

/// Display names, end to end through a real write.
final class DisplayNameWriteTests: XCTestCase {

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

    private func writer() -> ClaudeSettingsWriter {
        ClaudeSettingsWriter(paths: home.paths)
    }

    private func profileWithDisplayNames() -> BackendProfile {
        var profile = makeProfile()
        profile.setModel("glm-5.3-flash[1m]", for: .opus)
        profile.setDisplayName("GLM 5.3 Flash", for: .opus)
        profile.setDisplayName("DeepSeek Flash", for: .haiku)
        return profile
    }

    func testDisplayNamesReachTheFileAndVerify() throws {
        let profile = profileWithDisplayNames()
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "GLM 5.3 Flash")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"], "DeepSeek Flash")
        XCTAssertNotNil(home.parseJSON(home.read()))
        XCTAssertEqual(writer().verify(expected: profile, credential: "sk"), [])
    }

    /// The reported bug, as a test: a stale label from a previous setup must not survive.
    func testSwitchingClearsStaleDisplayNamesFromThePreviousBackend() throws {
        home.write(settings: """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://old.example",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "old-model",
            "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "55b1070d-1b41-4e8c-a555-29747704a148:Some Old Label",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "55b1070d-1b41-4e8c-a555-29747704a148:MiniMax-M3",
            "KEEP_ME": "yes"
          }
        }
        """)

        // The new profile sets models but no labels, so the labels must disappear.
        var next = BackendProfile(id: "next", name: "Next", baseURL: "https://new.example")
        next.setModel("deepseek-v4.1-flash[1m]", for: .primary)
        next.setModel("deepseek-v4.1-flash[1m]", for: .opus)
        _ = try writer().activate(profile: next, credential: "sk", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "the stale label must be cleared")
        XCTAssertNil(env["ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "deepseek-v4.1-flash[1m]")
        XCTAssertEqual(env["KEEP_ME"], "yes", "unmanaged keys still survive")
    }

    func testVerificationCatchesAMismatchedLabel() throws {
        let profile = profileWithDisplayNames()
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        // Someone edits the label behind our back.
        home.write(settings: home.read().replacingOccurrences(
            of: "GLM 5.3 Flash", with: "Wrong Label"
        ))
        let problems = writer().verify(expected: profile, credential: "sk")
        XCTAssertTrue(problems.contains { $0.contains("显示名") }, "got: \(problems)")
    }

    func testLabelsAreNotWrittenForTiersWithoutAModel() throws {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setModel("m", for: .primary)
        profile.setDisplayName("orphan", for: .opus)  // no opus model
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"])
        XCTAssertNil(env["ANTHROPIC_MODEL_NAME"], "there is no such variable")
    }
}

/// The 1.1.0 options, end to end through a real write.
///
/// The first test here is the one that matters most: it is a replay of a bug caught in review,
/// where the widening of the managed-key boundary would have deleted a value a user had set by hand.
final class ConfigurationOptionWriteTests: XCTestCase {

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

    private func writer() -> ClaudeSettingsWriter {
        ClaudeSettingsWriter(paths: home.paths)
    }

    /// A hand-set numeric must survive a backend switch.
    ///
    /// The real file this came from had `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = 87`, set by hand, and no
    /// profile of ours mentions it. Before `userOwnedKeys` existed, activating any profile deleted
    /// it — the app silently discarding a deliberate user value, which is exactly what it promises
    /// never to do.
    func testHandSetNumericsSurviveABackendSwitch() throws {
        home.write(settings: """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://old.example",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "87",
            "API_TIMEOUT_MS": "1200000",
            "BASH_MAX_TIMEOUT_MS": "900000",
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "32000"
          }
        }
        """)

        var next = BackendProfile(id: "next", name: "Next", baseURL: "https://new.example")
        next.setModel("m", for: .primary)
        _ = try writer().activate(profile: next, credential: "sk", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertEqual(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "87", "a hand-set value must survive")
        XCTAssertEqual(env["API_TIMEOUT_MS"], "1200000")
        XCTAssertEqual(env["BASH_MAX_TIMEOUT_MS"], "900000")
        XCTAssertEqual(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"], "32000")
        // And the endpoint really did move, so this is not a do-nothing test.
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://new.example")
    }

    /// The same keys *are* written when a profile asks for them.
    func testAProfileCanOverrideAHandSetNumeric() throws {
        home.write(settings: """
        { "env": { "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "87" } }
        """)
        var profile = makeProfile()
        profile.setNumeric(.autoCompactPercent, value: "50")
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        XCTAssertEqual(home.environment(in: home.read())["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "50")
    }

    func testRestoreOfficialConfigurationKeepsHandSetNumerics() throws {
        home.write(settings: """
        { "env": { "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "87", "MY_VAR": "keep" } }
        """)
        // Restore is driven from AppModel, but the key list it walks is the boundary itself.
        for key in ManagedEnvironment.clearableKeys {
            XCTAssertNotEqual(
                key, "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
                "restore must not remove a value the user set by hand"
            )
        }
    }

    func testFlagsReachTheFileWithTheRightValues() throws {
        var profile = makeProfile()
        profile.setFlag(.omitAttributionHeader, on: true)
        profile.setFlag(.disableCompact, on: true)
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertEqual(env["CLAUDE_CODE_ATTRIBUTION_HEADER"], "0", "the inverted flag writes 0")
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        XCTAssertEqual(writer().verify(expected: profile, credential: "sk"), [])
    }

    func testSwitchingClearsThePreviousBackendsFlags() throws {
        home.write(settings: """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://old.example",
            "DISABLE_COMPACT": "1",
            "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "87"
          }
        }
        """)
        var next = BackendProfile(id: "next", name: "Next", baseURL: "https://new.example")
        next.setModel("m", for: .primary)
        _ = try writer().activate(profile: next, credential: "sk", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertNil(env["DISABLE_COMPACT"], "an owned flag from the previous backend is cleared")
        XCTAssertNil(env["CLAUDE_CODE_ATTRIBUTION_HEADER"])
        XCTAssertEqual(env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "87", "the user-owned one is not")
    }

    func testChoicesAndHeadersReachTheFile() throws {
        var profile = makeProfile()
        profile.setChoice(.toolSearch, value: "true")
        profile.customHeaders = "X-Relay: abc\nX-Team: infra"
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)

        let env = home.environment(in: home.read())
        XCTAssertEqual(env["ENABLE_TOOL_SEARCH"], "true")
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_HEADERS"], "X-Relay: abc\nX-Team: infra")
        XCTAssertEqual(writer().verify(expected: profile, credential: "sk"), [])
    }

    func testVerificationCatchesAWronglyValuedFlag() throws {
        var profile = makeProfile()
        profile.setFlag(.omitAttributionHeader, on: true)
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)

        // Someone flips the inverted flag to the value that means the opposite.
        home.write(settings: home.read().replacingOccurrences(
            of: "\"CLAUDE_CODE_ATTRIBUTION_HEADER\": \"0\"",
            with: "\"CLAUDE_CODE_ATTRIBUTION_HEADER\": \"1\""
        ))
        let problems = writer().verify(expected: profile, credential: "sk")
        XCTAssertTrue(
            problems.contains { $0.contains("署名块") },
            "verification must catch a flag set to the wrong value, not just a missing one: \(problems)"
        )
    }

    func testVerificationCatchesAMissingNumeric() throws {
        var profile = makeProfile()
        profile.setNumeric(.apiTimeoutMs, value: "1200000")
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        home.write(settings: home.read().replacingOccurrences(
            of: "\"API_TIMEOUT_MS\": \"1200000\",\n", with: ""
        ).replacingOccurrences(of: "\"API_TIMEOUT_MS\": \"1200000\"", with: "\"X\": \"1\""))
        let problems = writer().verify(expected: profile, credential: "sk")
        XCTAssertTrue(problems.contains { $0.contains("API 超时") }, "got: \(problems)")
    }

    func testSnapshotReportsTheNewGroups() throws {
        home.write(settings: """
        {
          "env": {
            "DISABLE_COMPACT": "1",
            "ENABLE_TOOL_SEARCH": "auto",
            "API_TIMEOUT_MS": "999",
            "ANTHROPIC_CUSTOM_HEADERS": "X-A: 1"
          }
        }
        """)
        let snapshot = writer().snapshot()
        XCTAssertEqual(snapshot.flagValues["DISABLE_COMPACT"], "1")
        XCTAssertEqual(snapshot.choiceValues["ENABLE_TOOL_SEARCH"], "auto")
        XCTAssertEqual(snapshot.numericValues["API_TIMEOUT_MS"], "999")
        XCTAssertEqual(snapshot.customHeaders, "X-A: 1")
    }

    func testEverythingRoundTripsThroughAWriteAndSnapshot() throws {
        var profile = makeProfile()
        profile.setFlag(.omitAttributionHeader, on: true)
        profile.setFlag(.agentTeams, on: true)
        profile.setChoice(.systemPrompt, value: "0")
        profile.setNumeric(.bashMaxTimeoutMs, value: "600000")
        profile.customHeaders = "X-One: 1"
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)

        let snapshot = writer().snapshot()
        XCTAssertEqual(snapshot.flagValues["CLAUDE_CODE_ATTRIBUTION_HEADER"], "0")
        XCTAssertEqual(snapshot.flagValues["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"], "1")
        XCTAssertEqual(snapshot.choiceValues["CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT"], "0")
        XCTAssertEqual(snapshot.numericValues["BASH_MAX_TIMEOUT_MS"], "600000")
        XCTAssertEqual(snapshot.customHeaders, "X-One: 1")
        XCTAssertEqual(writer().verify(expected: profile, credential: "sk"), [])
    }
}

/// Verification has to stay quiet about values it deliberately does not manage.
///
/// Found by the end-to-end run: the write side preserved a hand-set value correctly, but
/// verification then reported it as a mismatch, so activating a hand-tuned file would raise a
/// warning every single time. Both halves of the user-owned rule have to agree.
final class UserOwnedVerificationTests: XCTestCase {

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

    private func writer() -> ClaudeSettingsWriter { ClaudeSettingsWriter(paths: home.paths) }

    func testPreexistingUserOwnedNumericDoesNotFailVerification() throws {
        home.write(settings: """
        {
          "env": {
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "87",
            "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000"
          }
        }
        """)
        var profile = makeProfile()
        profile.setFlag(.disableNonessentialTraffic, on: true)
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        XCTAssertEqual(writer().verify(expected: profile, credential: "sk"), [])
        XCTAssertEqual(
            home.environment(in: home.read())["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"], "87",
            "and the value is still there"
        )
    }

    func testAValueTheProfileDoesSetIsStillVerified() throws {
        home.write(settings: """
        { "env": { "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "87" } }
        """)
        var profile = makeProfile()
        profile.setNumeric(.autoCompactPercent, value: "50")
        _ = try writer().activate(profile: profile, credential: "sk", writeOnboardingFlag: false)
        XCTAssertEqual(writer().verify(expected: profile, credential: "sk"), [])

        // And a drift is still caught.
        home.write(settings: home.read().replacingOccurrences(of: "\"50\"", with: "\"60\""))
        let problems = writer().verify(expected: profile, credential: "sk")
        XCTAssertTrue(problems.contains { $0.contains("自动压缩") }, "got: \(problems)")
    }
}
