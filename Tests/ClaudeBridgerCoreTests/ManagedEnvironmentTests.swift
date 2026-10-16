import XCTest
@testable import ClaudeBridgerCore

final class ManagedEnvironmentTests: XCTestCase {

    /// The safety boundary. If a key is not on this list the app must never write it, and the
    /// test that matters is that the list does not quietly grow to include something that belongs
    /// to the user.
    func testWritableKeysAreTheWiringOnes() {
        XCTAssertEqual(
            ManagedEnvironment.writableKeys.sorted(),
            [
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "ANTHROPIC_DEFAULT_FABLE_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL",
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
