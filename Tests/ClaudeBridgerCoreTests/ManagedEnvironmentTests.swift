import XCTest
@testable import ClaudeBridgerCore

final class ManagedEnvironmentTests: XCTestCase {

    /// The safety boundary. If a key is not on this list the app must never write it, and the
    /// test that matters is that the list does not quietly grow to include something that belongs
    /// to the user.
    ///
    /// This is a deliberate, exhaustive list rather than a count, so widening the boundary has to
    /// be an explicit edit here. The four `_MODEL_NAME` entries were added in 1.0.1 to fix stale
    /// `/model` picker labels; note there is no `ANTHROPIC_MODEL_NAME` or subagent equivalent,
    /// because Claude Code defines none.
    func testWritableKeysAreTheWiringOnes() {
        XCTAssertEqual(
            ManagedEnvironment.writableKeys.sorted(),
            [
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "ANTHROPIC_DEFAULT_FABLE_MODEL",
                "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
                "ANTHROPIC_DEFAULT_OPUS_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
                "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
                "ANTHROPIC_MODEL",
                "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
                "CLAUDE_CODE_EFFORT_LEVEL",
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
                "CLAUDE_CODE_SUBAGENT_MODEL"
            ]
        )
    }

    func testApiKeyIsClearableButNeverWritten() {
        // ANTHROPIC_API_KEY is removed when the profile uses a bearer token, but the app has no
        // path that sets it on its own: leaving a stale one behind is what causes 401s.
        XCTAssertTrue(ManagedEnvironment.clearableKeys.contains(ManagedEnvironment.apiKey))
        XCTAssertFalse(ManagedEnvironment.writableKeys.contains(ManagedEnvironment.apiKey))
    }

    func testEveryClearableKeyIsAlsoWritableUnlessDeliberate() {
        let writeOnly = ManagedEnvironment.clearableKeys.subtracting(ManagedEnvironment.writableKeys)
        XCTAssertEqual(writeOnly, [ManagedEnvironment.apiKey])
    }

    func testCommonUserVariablesAreOutsideTheBoundary() {
        // Variables a user plausibly sets in the same env block, which the app must never touch.
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "API_TIMEOUT_MS", "BASH_DEFAULT_TIMEOUT_MS",
                    "DISABLE_TELEMETRY", "CLAUDE_CONFIG_DIR", "MY_OWN_VAR"] {
            XCTAssertFalse(ManagedEnvironment.writableKeys.contains(key), key)
            XCTAssertFalse(ManagedEnvironment.clearableKeys.contains(key), key)
        }
    }

    func testTierKeysAreDerivedFromTheTierEnum() {
        for tier in ModelTier.allCases {
            XCTAssertTrue(
                ManagedEnvironment.modelTierKeys.contains(tier.environmentKey),
                "\(tier) is missing from the managed key list"
            )
            XCTAssertTrue(ManagedEnvironment.writableKeys.contains(tier.environmentKey))
        }
    }

    func testSecretKeysAreTheCredentials() {
        XCTAssertEqual(
            ManagedEnvironment.secretKeys,
            ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]
        )
    }
}

final class BackendProfileTests: XCTestCase {

    func testEnvironmentValuesCoverEveryConfiguredTier() {
        let profile = makeProfile()
        let pairs = Dictionary(uniqueKeysWithValues: profile.environmentValues().map { ($0.key, $0.value) })
        XCTAssertEqual(pairs["ANTHROPIC_BASE_URL"], "https://api.deepseek.com/anthropic")
        XCTAssertEqual(pairs["ANTHROPIC_MODEL"], "deepseek-v4-pro[1m]")
        XCTAssertEqual(pairs["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "deepseek-v4-flash")
        XCTAssertEqual(pairs["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1048576")
        XCTAssertEqual(pairs["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "1048576")
        XCTAssertEqual(pairs["CLAUDE_CODE_EFFORT_LEVEL"], "max")
        XCTAssertEqual(pairs["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
    }

    func testUnsetTiersAreNotWritten() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setModel("only-primary", for: .primary)
        let keys = Set(profile.environmentValues().map(\.key))
        XCTAssertTrue(keys.contains("ANTHROPIC_MODEL"))
        XCTAssertFalse(keys.contains("ANTHROPIC_DEFAULT_OPUS_MODEL"))
        XCTAssertFalse(keys.contains("ANTHROPIC_DEFAULT_SONNET_MODEL"))
    }

    func testWhitespaceOnlyModelIsTreatedAsUnset() {
        var profile = BackendProfile(id: "x", name: "X")
        profile.setModel("   ", for: .primary)
        XCTAssertNil(profile.model(for: .primary))
        profile.setModel("  m  ", for: .primary)
        XCTAssertEqual(profile.model(for: .primary), "m")
    }

    func testCredentialHeaderFollowsTheMode() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.credential = "sk"
        profile.credentialMode = .authToken
        var keys = Set(profile.environmentValues().map(\.key))
        XCTAssertTrue(keys.contains("ANTHROPIC_AUTH_TOKEN"))
        XCTAssertFalse(keys.contains("ANTHROPIC_API_KEY"))

        profile.credentialMode = .apiKey
        keys = Set(profile.environmentValues().map(\.key))
        XCTAssertTrue(keys.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(keys.contains("ANTHROPIC_AUTH_TOKEN"))

        profile.credentialMode = .none
        keys = Set(profile.environmentValues().map(\.key))
        XCTAssertFalse(keys.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(keys.contains("ANTHROPIC_AUTH_TOKEN"))
    }

    func testPublishedComparisonIgnoresIdentityAndCredential() {
        var a = makeProfile()
        var b = makeProfile()
        b.id = "different"
        b.name = "Renamed"
        b.category = "自定义"
        b.credential = "a-different-secret"
        XCTAssertTrue(a.hasSamePublishedSettings(as: b), "identity and secret must not count as a change")

        b.effortLevel = .low
        XCTAssertFalse(a.hasSamePublishedSettings(as: b), "a real setting must count")

        a.effortLevel = .low
        XCTAssertTrue(a.hasSamePublishedSettings(as: b))
    }
}

final class BackendPresetTests: XCTestCase {

    func testEveryPresetEndpointOmitsTheV1Suffix() {
        // Claude Code appends /v1/messages itself, so a preset that ships /v1 would 404 on the
        // first request, and the failure looks like a server problem.
        for preset in BackendPreset.builtIn where !preset.baseURL.isEmpty {
            XCTAssertFalse(
                preset.baseURL.hasSuffix("/v1") || preset.baseURL.hasSuffix("/v1/"),
                preset.name + " ships a /v1 suffix"
            )
        }
    }

    func testPresetProfilesFillEveryTier() {
        // The failure this prevents: a preset that sets only the primary model, leaving the
        // background tiers requesting a Claude model name from a vendor that has never heard of it.
        for preset in BackendPreset.builtIn where !preset.models.isEmpty {
            let profile = preset.makeProfile(id: preset.id)
            for tier in ModelTier.allCases {
                XCTAssertNotNil(
                    profile.model(for: tier),
                    preset.name + " does not fill \(tier)"
                )
            }
        }
    }

    func testPresetProfilesNeverPrefillCredentials() {
        for preset in BackendPreset.builtIn {
            XCTAssertTrue(preset.makeProfile(id: preset.id).credential.isEmpty, preset.name)
        }
    }

    func testPresetsCarryTheirSource() {
        // Every endpoint here is a claim about a vendor's API, and a claim without a citation is
        // one nobody can check when the vendor changes it.
        for preset in BackendPreset.builtIn {
            XCTAssertFalse(preset.source.isEmpty, preset.name + " has no source")
            XCTAssertFalse(preset.note.isEmpty, preset.name + " has no note")
        }
    }

    func testGroupsCoverEveryPresetExactlyOnce() {
        let groups = BackendPreset.groups(BackendPreset.builtIn)
        let flattened = groups.flatMap(\.presets)
        XCTAssertEqual(flattened.count, BackendPreset.builtIn.count)
        XCTAssertEqual(Set(flattened.map(\.id)), Set(BackendPreset.builtIn.map(\.id)))
    }

    func testKnownVendorEndpoints() {
        let byID = Dictionary(uniqueKeysWithValues: BackendPreset.builtIn.map { ($0.id, $0.baseURL) })
        XCTAssertEqual(byID["deepseek"], "https://api.deepseek.com/anthropic")
        XCTAssertEqual(byID["zhipu"], "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(byID["moonshot"], "https://api.moonshot.cn/anthropic")
        XCTAssertEqual(byID["kimi-code"], "https://api.kimi.com/coding/")
        XCTAssertEqual(byID["dashscope"], "https://dashscope.aliyuncs.com/apps/anthropic")
    }
}

/// The display-name family, which exists for exactly four tiers.
///
/// Claude Code's reference lists `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL_NAME`. There
/// is no `ANTHROPIC_MODEL_NAME` and no subagent variant, so the app must never write one: a key
/// Claude Code ignores is worse than no key, because it looks like it works.
final class ModelDisplayNameTests: XCTestCase {

    func testOnlyTheFourAliasTiersSupportADisplayName() {
        XCTAssertTrue(ModelTier.opus.supportsDisplayName)
        XCTAssertTrue(ModelTier.sonnet.supportsDisplayName)
        XCTAssertTrue(ModelTier.haiku.supportsDisplayName)
        XCTAssertTrue(ModelTier.fable.supportsDisplayName)

        XCTAssertFalse(ModelTier.primary.supportsDisplayName)
        XCTAssertFalse(ModelTier.subagent.supportsDisplayName)
        XCTAssertNil(ModelTier.primary.displayNameKey)
        XCTAssertNil(ModelTier.subagent.displayNameKey)
    }

    func testDisplayNameKeysMatchTheOfficialNames() {
        XCTAssertEqual(ModelTier.opus.displayNameKey, "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME")
        XCTAssertEqual(ModelTier.sonnet.displayNameKey, "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME")
        XCTAssertEqual(ModelTier.haiku.displayNameKey, "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME")
        XCTAssertEqual(ModelTier.fable.displayNameKey, "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME")
    }

    /// The exact mistake this guards: inventing an `ANTHROPIC_MODEL_NAME`.
    func testNoInventedKeysAreEverWritten() {
        var profile = makeProfile()
        profile.setDisplayName("x", for: .primary)
        profile.setDisplayName("x", for: .subagent)
        let keys = Set(profile.environmentValues().map(\.key))
        XCTAssertFalse(keys.contains("ANTHROPIC_MODEL_NAME"))
        XCTAssertFalse(keys.contains("CLAUDE_CODE_SUBAGENT_MODEL_NAME"))
        XCTAssertTrue(profile.modelDisplayNames.isEmpty, "an unsupported tier must not store a label")
    }

    func testDisplayNamesAreEmittedBesideTheirModel() {
        var profile = makeProfile()
        profile.setModel("glm-5.3-flash[1m]", for: .opus)
        profile.setDisplayName("GLM 5.3 Flash", for: .opus)
        let pairs = profile.environmentValues()
        let keys = pairs.map(\.key)
        let modelIndex = try! XCTUnwrap(keys.firstIndex(of: "ANTHROPIC_DEFAULT_OPUS_MODEL"))
        let nameIndex = try! XCTUnwrap(keys.firstIndex(of: "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"))
        XCTAssertEqual(nameIndex, modelIndex + 1, "the label should follow its model")
        XCTAssertEqual(pairs[nameIndex].value, "GLM 5.3 Flash")
    }

    /// A label without a model would describe nothing, so it is not emitted.
    func testADisplayNameIsNotEmittedWithoutItsModel() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setDisplayName("orphan label", for: .opus)
        let keys = Set(profile.environmentValues().map(\.key))
        XCTAssertFalse(keys.contains("ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"))
    }

    func testDisplayNameKeysAreInsideTheManagedBoundary() {
        for tier in ModelTier.allCases where tier.supportsDisplayName {
            let key = try! XCTUnwrap(tier.displayNameKey)
            XCTAssertTrue(ManagedEnvironment.writableKeys.contains(key), key)
            XCTAssertTrue(ManagedEnvironment.clearableKeys.contains(key), key)
        }
    }

    func testBlankDisplayNameIsTreatedAsUnset() {
        var profile = makeProfile()
        profile.setDisplayName("   ", for: .opus)
        XCTAssertNil(profile.displayName(for: .opus))
        profile.setDisplayName("  Trimmed  ", for: .opus)
        XCTAssertEqual(profile.displayName(for: .opus), "Trimmed")
    }

    func testChangingADisplayNameCountsAsAPublishedChange() {
        var a = makeProfile()
        var b = makeProfile()
        XCTAssertTrue(a.hasSamePublishedSettings(as: b))
        b.setDisplayName("Different label", for: .haiku)
        XCTAssertFalse(
            a.hasSamePublishedSettings(as: b),
            "a display name is written to the file, so changing it is a real change"
        )
        a.setDisplayName("Different label", for: .haiku)
        XCTAssertTrue(a.hasSamePublishedSettings(as: b))
    }
}
