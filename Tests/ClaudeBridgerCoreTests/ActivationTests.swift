import XCTest
@testable import ClaudeBridgerCore

final class ActivationGuardTests: XCTestCase {

    func testFirstActivationOnAFreshMachineDoesNotAsk() {
        let assessment = ActivationGuard.assess(
            currentBaseURL: nil,
            targetBaseURL: "https://api.deepseek.com/anthropic",
            targetName: "DeepSeek"
        )
        XCTAssertFalse(assessment.requiresConfirmation)
        XCTAssertTrue(assessment.warnings.isEmpty)
    }

    func testActivatingTheSameBackendDoesNotAsk() {
        let assessment = ActivationGuard.assess(
            currentBaseURL: "https://api.deepseek.com/anthropic",
            targetBaseURL: "https://api.deepseek.com/anthropic",
            targetName: "DeepSeek"
        )
        XCTAssertFalse(assessment.requiresConfirmation)
    }

    func testSwitchingBetweenManagedProfilesDoesNotAsk() {
        // Both endpoints belong to profiles this app manages, so this is the normal case. Asking
        // every time would train the user to dismiss the dialog that matters.
        let assessment = ActivationGuard.assess(
            currentBaseURL: "https://a.example",
            targetBaseURL: "https://b.example",
            targetName: "B",
            knownBaseURLs: ["https://a.example", "https://b.example"]
        )
        XCTAssertFalse(assessment.requiresConfirmation)
    }

    func testTakingOverAForeignConfigAsks() {
        let assessment = ActivationGuard.assess(
            currentBaseURL: "https://hand-edited.example",
            targetBaseURL: "https://api.deepseek.com/anthropic",
            targetName: "DeepSeek",
            knownBaseURLs: ["https://other.example"]
        )
        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.replacedBaseURL, "https://hand-edited.example")
        XCTAssertTrue(assessment.message.contains("hand-edited.example"))
        XCTAssertFalse(assessment.confirmTitle.isEmpty)
        // The user is told the old file is preserved.
        XCTAssertTrue(assessment.message.contains("备份"))
    }

    // MARK: - Warnings

    func testEmptyBaseURLWarns() {
        let warnings = ActivationGuard.baseURLWarnings("")
        XCTAssertFalse(warnings.isEmpty)
    }

    func testTrailingV1IsFlagged() {
        // The single hardest mistake to debug: Claude Code appends /v1/messages itself.
        let warnings = ActivationGuard.baseURLWarnings("https://api.example.com/v1")
        XCTAssertTrue(warnings.contains { $0.contains("/v1") }, "got: \(warnings)")
        let withSlash = ActivationGuard.baseURLWarnings("https://api.example.com/v1/")
        XCTAssertTrue(withSlash.contains { $0.contains("/v1") })
    }

    func testLoopbackIsFlagged() {
        let warnings = ActivationGuard.baseURLWarnings("http://127.0.0.1:4000")
        XCTAssertTrue(warnings.contains { $0.contains("本机") })
    }

    func testPlainHTTPToARemoteHostIsFlagged() {
        let warnings = ActivationGuard.baseURLWarnings("http://api.example.com")
        XCTAssertTrue(warnings.contains { $0.contains("http") })
    }

    func testAWellFormedVendorURLIsClean() {
        XCTAssertTrue(ActivationGuard.baseURLWarnings("https://api.deepseek.com/anthropic").isEmpty)
        XCTAssertTrue(ActivationGuard.baseURLWarnings("https://open.bigmodel.cn/api/anthropic").isEmpty)
        XCTAssertTrue(ActivationGuard.baseURLWarnings("https://api.kimi.com/coding/").isEmpty)
    }

    func testGarbageURLWarns() {
        XCTAssertFalse(ActivationGuard.baseURLWarnings("not a url").isEmpty)
    }
}

final class ActivationActionTests: XCTestCase {

    func testErrorsBlockTheButton() {
        let availability = ActivationAction.availability(
            hasBaseURL: true, isDirty: false, hasErrors: true,
            isAlreadyActive: false, isAlreadyPublished: false
        )
        XCTAssertFalse(availability.isEnabled)
    }

    func testDirtyBlocksTheButton() {
        let availability = ActivationAction.availability(
            hasBaseURL: true, isDirty: true, hasErrors: false,
            isAlreadyActive: false, isAlreadyPublished: false
        )
        XCTAssertFalse(availability.isEnabled)
        XCTAssertTrue(availability.help.contains("保存"))
    }

    func testMissingBaseURLBlocksTheButton() {
        let availability = ActivationAction.availability(
            hasBaseURL: false, isDirty: false, hasErrors: false,
            isAlreadyActive: false, isAlreadyPublished: false
        )
        XCTAssertFalse(availability.isEnabled)
    }

    func testAFreshProfileCanBeActivated() {
        let availability = ActivationAction.availability(
            hasBaseURL: true, isDirty: false, hasErrors: false,
            isAlreadyActive: false, isAlreadyPublished: false
        )
        XCTAssertTrue(availability.isEnabled)
        XCTAssertEqual(availability.title, "启用")
    }

    func testAnAppliedProfileGoesFlat() {
        // Both true means the file already holds exactly this, so there is nothing to apply.
        let availability = ActivationAction.availability(
            hasBaseURL: true, isDirty: false, hasErrors: false,
            isAlreadyActive: true, isAlreadyPublished: true
        )
        XCTAssertFalse(availability.isEnabled)
    }

    func testAChangedActiveProfileComesBackToLife() {
        // isAlreadyActive but not published: the settings changed since they were applied. This is
        // the path out, and it must stay open.
        let availability = ActivationAction.availability(
            hasBaseURL: true, isDirty: false, hasErrors: false,
            isAlreadyActive: true, isAlreadyPublished: false
        )
        XCTAssertTrue(availability.isEnabled)
    }
}

final class ActivationVerificationTests: XCTestCase {

    private func snapshot(
        exists: Bool = true,
        unparseable: Bool = false,
        baseURL: String? = "https://api.deepseek.com/anthropic",
        models: [String: String] = [:],
        displayNames: [String: String] = [:],
        flagValues: [String: String] = [:],
        choiceValues: [String: String] = [:],
        numericValues: [String: String] = [:],
        customHeaders: String? = nil,
        keys: Set<String> = []
    ) -> SettingsSnapshot {
        SettingsSnapshot(
            fileExists: exists,
            baseURL: baseURL,
            models: models,
            modelDisplayNames: displayNames,
            flagValues: flagValues,
            choiceValues: choiceValues,
            numericValues: numericValues,
            customHeaders: customHeaders,
            managedKeysPresent: keys,
            totalEnvironmentKeys: keys.count,
            isUnparseable: unparseable,
            parseErrorMessage: nil,
            environmentIsNotAnObject: false,
            hasCompletedOnboarding: false
        )
    }

    func testAMatchingWriteHasNoWarnings() {
        var expected = makeProfile()
        expected.setModel(nil, for: .opus)
        let warnings = ActivationVerification.warnings(
            expected: expected,
            credential: "sk",
            snapshot: snapshot(
                models: [
                    ModelTier.primary.rawValue: "deepseek-v4-pro[1m]",
                    ModelTier.haiku.rawValue: "deepseek-v4-flash"
                ],
                // The snapshot has to carry every flag the profile turns on, or verification
                // correctly reports it missing. `makeProfile` stands in for a preset, so it has the
                // traffic switch on.
                flagValues: [EnvironmentFlag.disableNonessentialTraffic.key: "1"],
                keys: ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"]
            )
        )
        XCTAssertEqual(warnings, [])
    }

    func testMissingFileIsReported() {
        let warnings = ActivationVerification.warnings(
            expected: makeProfile(), credential: "sk", snapshot: snapshot(exists: false)
        )
        XCTAssertTrue(warnings.contains { $0.contains("没有找到") })
    }

    func testCredentialModeNoneDoesNotExpectACredential() {
        var expected = makeProfile()
        expected.credentialMode = .none
        let warnings = ActivationVerification.warnings(
            expected: expected,
            credential: "",
            snapshot: snapshot(
                models: [
                    ModelTier.primary.rawValue: "deepseek-v4-pro[1m]",
                    ModelTier.haiku.rawValue: "deepseek-v4-flash"
                ],
                flagValues: [EnvironmentFlag.disableNonessentialTraffic.key: "1"],
                keys: ["ANTHROPIC_BASE_URL"]
            )
        )
        XCTAssertEqual(warnings, [])
    }

    func testWrongBaseURLIsReported() {
        let warnings = ActivationVerification.warnings(
            expected: makeProfile(),
            credential: "sk",
            snapshot: snapshot(baseURL: "https://wrong.example", keys: ["ANTHROPIC_AUTH_TOKEN"])
        )
        XCTAssertTrue(warnings.contains { $0.contains("base_url") })
    }

    func testMissingCredentialVariableIsReported() {
        let warnings = ActivationVerification.warnings(
            expected: makeProfile(),
            credential: "sk",
            snapshot: snapshot(keys: ["ANTHROPIC_BASE_URL"])
        )
        XCTAssertTrue(warnings.contains { $0.contains("ANTHROPIC_AUTH_TOKEN") })
    }
}
