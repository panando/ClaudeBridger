import XCTest
@testable import ClaudeBridgerCore

/// Migration from the 1.0.x shape.
///
/// This is the one place in 1.1.0 that reads existing user data through a shape it was not written
/// in: a stored boolean became a set of flags. A mistake here would not crash — it would silently
/// drop a setting, which is worse.
final class ProfileMigrationTests: XCTestCase {

    private func decodeProfile(_ json: String) throws -> StoredProfile {
        try JSONDecoder().decode(StoredProfile.self, from: Data(json.utf8))
    }

    /// The exact shape 1.0.1 wrote, including the boolean.
    private let oneOhOneProfile = """
    {
      "id": "deepseek",
      "name": "DeepSeek",
      "category": "国产大模型",
      "baseURL": "https://api.deepseek.com/anthropic",
      "credentialMode": "authToken",
      "models": {
        "primary": "deepseek-v4-pro[1m]",
        "haiku": "deepseek-v4-flash"
      },
      "modelDisplayNames": { "opus": "GLM 5.3 Flash" },
      "contextWindow": 1048576,
      "disableNonessentialTraffic": true,
      "effortLevel": "max"
    }
    """

    func testLegacyTrueBecomesTheFlag() throws {
        let stored = try decodeProfile(oneOhOneProfile)
        XCTAssertTrue(
            stored.flags.contains(.disableNonessentialTraffic),
            "a 1.0.1 profile with the boolean on must keep it on"
        )
    }

    func testLegacyFalseBecomesNoFlag() throws {
        let json = oneOhOneProfile.replacingOccurrences(
            of: "\"disableNonessentialTraffic\": true",
            with: "\"disableNonessentialTraffic\": false"
        )
        let stored = try decodeProfile(json)
        XCTAssertTrue(stored.flags.isEmpty)
    }

    /// The old field defaulted to `true`, so a profile that omitted it had the switch on. Decoding
    /// a missing key as "empty" would silently turn it off for those users.
    func testLegacyMissingKeyDefaultsToOn() throws {
        let json = oneOhOneProfile.replacingOccurrences(
            of: "  \"disableNonessentialTraffic\": true,\n",
            with: ""
        )
        XCTAssertFalse(json.contains("disableNonessentialTraffic"))
        let stored = try decodeProfile(json)
        XCTAssertTrue(
            stored.flags.contains(.disableNonessentialTraffic),
            "the old default was on, so omission must decode as on"
        )
    }

    func testLegacyFieldsOtherThanTheFlagStillArrive() throws {
        let stored = try decodeProfile(oneOhOneProfile)
        XCTAssertEqual(stored.id, "deepseek")
        XCTAssertEqual(stored.baseURL, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(stored.models["primary"], "deepseek-v4-pro[1m]")
        XCTAssertEqual(stored.modelDisplayNames["opus"], "GLM 5.3 Flash")
        XCTAssertEqual(stored.contextWindow, 1_048_576)
        XCTAssertEqual(stored.effortLevel, .max)
        XCTAssertTrue(stored.choices.isEmpty, "a 1.0.1 profile has no choices")
        XCTAssertTrue(stored.numerics.isEmpty)
        XCTAssertEqual(stored.customHeaders, "")
    }

    /// The legacy key must not be written back, or the file would carry two sources of truth.
    ///
    /// Note the flag's own name is also `disableNonessentialTraffic` (it appears inside the `flags`
    /// array), so this checks for the legacy *key* — a JSON object member — rather than the bare
    /// string, which would pass for the wrong reason.
    func testLegacyKeyIsNotReEncoded() throws {
        let stored = try decodeProfile(oneOhOneProfile)
        let reencoded = try JSONEncoder().encode(stored)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertNil(
            object["disableNonessentialTraffic"],
            "the legacy key must not survive a round trip"
        )
        XCTAssertNotNil(object["flags"], "the information should now live in flags")
        XCTAssertEqual(object["flags"] as? [String], ["disableNonessentialTraffic"])
    }

    func testRoundTripThroughBothShapesIsStable() throws {
        let stored = try decodeProfile(oneOhOneProfile)
        let encoded = try JSONEncoder().encode(stored)
        let reparsed = try JSONDecoder().decode(StoredProfile.self, from: encoded)
        XCTAssertEqual(stored, reparsed)
    }

    /// A whole 1.0.1 configuration file, as written by that version.
    func testWholeLegacyConfigurationLoads() throws {
        let json = """
        {
          "schemaVersion": 1,
          "profiles": [\(oneOhOneProfile)],
          "activeProfileID": "deepseek",
          "publishedProfile": \(oneOhOneProfile),
          "wroteOnboardingFlag": true,
          "verifyAfterWrite": true,
          "interfaceLanguage": "simplifiedChinese"
        }
        """
        let config = try JSONDecoder().decode(ClaudeBridgerConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.profiles.count, 1)
        XCTAssertEqual(config.profiles[0].flags, [.disableNonessentialTraffic])
        XCTAssertTrue(config.wroteOnboardingFlag)
        XCTAssertEqual(config.interfaceLanguage, .simplifiedChinese)
        XCTAssertEqual(config.publishedProfile?.flags, [.disableNonessentialTraffic])
    }
}

/// The 1M suffix, which is a view of the model string rather than a stored field.
final class OneMillionSuffixTests: XCTestCase {

    func testRecognisesBothSpellings() {
        XCTAssertTrue(ModelTier.has1M("deepseek-v4-pro[1m]"))
        XCTAssertTrue(ModelTier.has1M("some-model[1M]"))
        XCTAssertTrue(ModelTier.has1M("some-model [1M]"))
        XCTAssertFalse(ModelTier.has1M("deepseek-v4-pro"))
        XCTAssertFalse(ModelTier.has1M("[1m]-prefix-only"))
    }

    func testStrippingHandlesEverySpelling() {
        XCTAssertEqual(ModelTier.stripping1M(from: "m[1m]"), "m")
        XCTAssertEqual(ModelTier.stripping1M(from: "m[1M]"), "m")
        XCTAssertEqual(ModelTier.stripping1M(from: "m [1M]"), "m")
        XCTAssertEqual(ModelTier.stripping1M(from: "m"), "m")
        // A doubled suffix must not survive one pass, which is why stripping loops.
        XCTAssertEqual(ModelTier.stripping1M(from: "m[1m][1M]"), "m")
    }

    func testAppendingNormalisesToTheCanonicalForm() {
        XCTAssertEqual(ModelTier.appending1M(to: "m"), "m[1m]")
        XCTAssertEqual(ModelTier.appending1M(to: "m[1M]"), "m[1m]", "a non-canonical input is normalised")
        XCTAssertEqual(ModelTier.appending1M(to: "m [1M]"), "m[1m]")
        XCTAssertEqual(ModelTier.appending1M(to: ""), "")
    }

    func testCheckboxReflectsAPreExistingSuffix() {
        // The reason no migration is needed: a profile that already says `[1m]` just shows checked.
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setModel("deepseek-v4-pro[1m]", for: .primary)
        XCTAssertTrue(profile.is1M(for: .primary))

        profile.setModel("other-model", for: .opus)
        XCTAssertFalse(profile.is1M(for: .opus))
    }

    func testSettingTheCheckboxEditsTheModelString() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setModel("m", for: .primary)

        profile.set1M(true, for: .primary)
        XCTAssertEqual(profile.model(for: .primary), "m[1m]")
        XCTAssertTrue(profile.is1M(for: .primary))

        profile.set1M(false, for: .primary)
        XCTAssertEqual(profile.model(for: .primary), "m")
        XCTAssertFalse(profile.is1M(for: .primary))
    }

    func testSettingTheCheckboxOnAnEmptyTierIsANoOp() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.set1M(true, for: .primary)
        XCTAssertNil(profile.model(for: .primary), "no model means nothing to suffix")
    }

    /// A display label describes the model, so it must not advertise the client-side hint.
    func testSettingTheCheckboxStripsTheSuffixFromTheDisplayName() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setModel("m", for: .opus)
        profile.setDisplayName("m[1m]", for: .opus)

        profile.set1M(true, for: .opus)

        XCTAssertEqual(profile.displayName(for: .opus), "m")
    }

    func testSuffixSurvivesIntoTheWrittenEnvironment() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setModel("m", for: .primary)
        profile.set1M(true, for: .primary)
        let written = Dictionary(uniqueKeysWithValues: profile.environmentValues().map { ($0.key, $0.value) })
        XCTAssertEqual(written["ANTHROPIC_MODEL"], "m[1m]")
    }
}

/// Behaviour flags, choices and numerics.
final class ConfigurationOptionTests: XCTestCase {

    func testOnlyTheTokenReminderIsThirdPartyOnly() {
        // The other two keys Cherry Studio uses turned out to be documented, so claiming they were
        // undocumented would be wrong. This pins that finding.
        let undocumented = EnvironmentFlag.allCases.filter { !$0.provenance.isOfficial }
        XCTAssertEqual(undocumented, [.totalTokensReminderOff])
    }

    func testTheAttributionFlagIsInverted() {
        // Getting this backwards would turn the block *on* while appearing to turn it off.
        XCTAssertEqual(EnvironmentFlag.omitAttributionHeader.onValue, "0")
        XCTAssertEqual(EnvironmentFlag.totalTokensReminderOff.onValue, "off")
        XCTAssertEqual(EnvironmentFlag.disableCompact.onValue, "1")
    }

    func testEveryFlagKeyIsDistinctAndManaged() {
        let keys = EnvironmentFlag.allCases.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate flag key")
        for flag in EnvironmentFlag.allCases {
            XCTAssertTrue(ManagedEnvironment.writableKeys.contains(flag.key), flag.key)
            XCTAssertTrue(ManagedEnvironment.clearableKeys.contains(flag.key), flag.key)
        }
    }

    func testFlagsWriteTheirOnValueAndClearWhenOff() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setFlag(.omitAttributionHeader, on: true)
        profile.setFlag(.disableCompact, on: true)
        var written = Dictionary(uniqueKeysWithValues: profile.environmentValues().map { ($0.key, $0.value) })
        XCTAssertEqual(written["CLAUDE_CODE_ATTRIBUTION_HEADER"], "0")
        XCTAssertEqual(written["DISABLE_COMPACT"], "1")

        profile.setFlag(.disableCompact, on: false)
        written = Dictionary(uniqueKeysWithValues: profile.environmentValues().map { ($0.key, $0.value) })
        XCTAssertNil(written["DISABLE_COMPACT"], "an off flag writes nothing")
        XCTAssertEqual(written["CLAUDE_CODE_ATTRIBUTION_HEADER"], "0", "the other flag is unaffected")
    }

    func testAProfileStartsWithNoFlags() {
        let profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        XCTAssertTrue(profile.flags.isEmpty, "the app must not enable behaviour the user did not pick")
    }

    func testPresetsTurnOnTheTrafficSwitch() {
        for preset in BackendPreset.builtIn where !preset.models.isEmpty {
            let profile = preset.makeProfile(id: preset.id)
            XCTAssertTrue(
                profile.isOn(.disableNonessentialTraffic),
                preset.name + " should enable the third-party traffic switch"
            )
        }
    }

    // MARK: - Choices

    func testToolSearchOffersTheDocumentedValues() {
        let values = EnvironmentChoice.toolSearch.options.compactMap(\.value)
        XCTAssertEqual(values, ["true", "auto", "auto:5", "false"])
        XCTAssertEqual(EnvironmentChoice.toolSearch.options.first?.value, nil, "first option is unset")
    }

    func testUnsetIsDistinctFromAnyValue() {
        let choice = EnvironmentChoice.toolSearch
        XCTAssertEqual(choice.optionID(forValue: nil), "unset")
        XCTAssertEqual(choice.optionID(forValue: "true"), "true")
        // A value with no matching option must not be silently rewritten.
        XCTAssertEqual(choice.optionID(forValue: "auto:12"), "custom")
    }

    func testChoiceRoundTripsThroughTheEnvironment() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.setChoice(.toolSearch, value: "true")
        let written = Dictionary(uniqueKeysWithValues: profile.environmentValues().map { ($0.key, $0.value) })
        XCTAssertEqual(written["ENABLE_TOOL_SEARCH"], "true")

        profile.setChoice(.toolSearch, value: nil)
        XCTAssertNil(profile.choiceValue(.toolSearch))
        XCTAssertFalse(profile.environmentValues().contains { $0.key == "ENABLE_TOOL_SEARCH" })
    }

    // MARK: - Numerics

    func testNumericRangesAreEnforced() {
        XCTAssertEqual(NumericSetting.autoCompactPercent.range, 1...100)
        XCTAssertNil(NumericSetting.autoCompactPercent.validate("").errorMessage)
        XCTAssertNil(NumericSetting.autoCompactPercent.validate("87").errorMessage)
        XCTAssertNotNil(NumericSetting.autoCompactPercent.validate("0").errorMessage)
        XCTAssertNotNil(NumericSetting.autoCompactPercent.validate("101").errorMessage)
        XCTAssertNotNil(NumericSetting.autoCompactPercent.validate("abc").errorMessage)
        XCTAssertNotNil(NumericSetting.autoCompactPercent.validate("-5").errorMessage)
    }

    func testEmptyNumericMeansNotSet() {
        XCTAssertEqual(NumericSetting.apiTimeoutMs.validate("").normalizedValue, nil)
        XCTAssertEqual(NumericSetting.apiTimeoutMs.validate(" 1200000 ").normalizedValue, "1200000")
    }

    func testNumericsAreEmittedInDeclarationOrder() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        // Set them out of order; the written block should still be in enum order.
        profile.setNumeric(.autoCompactPercent, value: "87")
        profile.setNumeric(.apiTimeoutMs, value: "1200000")
        let keys = profile.environmentValues().map(\.key).filter { ManagedEnvironment.numericKeys.contains($0) }
        XCTAssertEqual(keys, ["API_TIMEOUT_MS", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"])
    }
}

/// `ANTHROPIC_CUSTOM_HEADERS`, which is free text and therefore the easiest thing to get wrong.
final class CustomHeadersTests: XCTestCase {

    func testParsesNameValueLines() {
        let parsed = CustomHeaders.parse("X-A: 1\nX-B: two")
        XCTAssertEqual(parsed.pairs.count, 2)
        XCTAssertEqual(parsed.pairs[0].name, "X-A")
        XCTAssertEqual(parsed.pairs[0].value, "1")
        XCTAssertTrue(parsed.problems.isEmpty)
    }

    func testSplitsOnTheFirstColonOnly() {
        // A value may legitimately contain a colon, e.g. a URL.
        let parsed = CustomHeaders.parse("X-Url: https://example.com:8443/path")
        XCTAssertEqual(parsed.pairs.first?.value, "https://example.com:8443/path")
    }

    func testBlankLinesAreIgnored() {
        XCTAssertEqual(CustomHeaders.parse("\n\n  \n").pairs.count, 0)
        XCTAssertTrue(CustomHeaders.parse("").problems.isEmpty)
    }

    func testALineWithoutAColonIsReportedNotDropped() {
        let parsed = CustomHeaders.parse("X-Good: 1\nthis-line-has-no-colon")
        XCTAssertEqual(parsed.pairs.count, 1)
        XCTAssertEqual(parsed.problems.count, 1)
        XCTAssertTrue(parsed.problems[0].contains("冒号"))
    }

    func testAnEmptyNameOrValueIsReported() {
        XCTAssertEqual(CustomHeaders.parse(": value").problems.count, 1)
        XCTAssertEqual(CustomHeaders.parse("X-Name:").problems.count, 1)
    }

    func testRoundTripsThroughTheProfile() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.customHeaders = "X-A: 1\n\nX-B: 2\n"
        let written = Dictionary(uniqueKeysWithValues: profile.environmentValues().map { ($0.key, $0.value) })
        XCTAssertEqual(written["ANTHROPIC_CUSTOM_HEADERS"], "X-A: 1\nX-B: 2")
    }

    func testBlankHeadersWriteNothing() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.customHeaders = "   \n  "
        XCTAssertNil(profile.normalizedCustomHeaders)
        XCTAssertFalse(profile.environmentValues().contains { $0.key == "ANTHROPIC_CUSTOM_HEADERS" })
    }

    func testProblemsAreVisibleBeforeWriting() {
        var profile = BackendProfile(id: "x", name: "X", baseURL: "https://x.example")
        profile.customHeaders = "broken line without colon"
        XCTAssertFalse(profile.customHeaderProblems.isEmpty)
    }
}
