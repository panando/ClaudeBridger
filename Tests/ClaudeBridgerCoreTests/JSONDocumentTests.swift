import XCTest
@testable import ClaudeBridgerCore

/// The editor's whole reason for existing: it must be impossible for a write to damage a part of
/// the file it was not asked about.
final class JSONDocumentTests: XCTestCase {

    // MARK: - Surgical edits

    func testReplacingAValueChangesOnlyThatValue() throws {
        let original = """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "env": {
            "ANTHROPIC_BASE_URL": "https://a.example",
            "ANTHROPIC_AUTH_TOKEN": "sk-old"
          },
          "permissions": {
            "allow": ["Bash(npm test)"]
          }
        }
        """
        var document = try JSONDocument(source: original)
        try document.setString("sk-new", forKey: "ANTHROPIC_AUTH_TOKEN", inObjectAt: ["env"])
        let rendered = document.render()

        XCTAssertTrue(rendered.contains("\"ANTHROPIC_AUTH_TOKEN\": \"sk-new\""))
        XCTAssertTrue(rendered.contains("https://a.example"))
        XCTAssertTrue(rendered.contains("Bash(npm test)"))
        XCTAssertTrue(rendered.contains("schemastore"))
        // Exactly one line differs, so a user reviewing the change sees one line.
        let before = original.split(separator: "\n", omittingEmptySubsequences: false)
        let after = rendered.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.count, 1)
    }

    func testInsertingAKeyAddsExactlyOneLine() throws {
        let original = """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://a.example"
          }
        }
        """
        var document = try JSONDocument(source: original)
        try document.setString("deepseek-v4-pro", forKey: "ANTHROPIC_MODEL", inObjectAt: ["env"])
        let rendered = document.render()
        XCTAssertTrue(rendered.contains("\"ANTHROPIC_MODEL\": \"deepseek-v4-pro\""))
        let before = original.split(separator: "\n", omittingEmptySubsequences: false)
        let after = rendered.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertNoThrow(try JSONDocument(source: rendered))
    }

    func testInsertionCommaLandsAtEndOfPreviousLine() throws {
        // The classic formatting failure: a comma pushed onto its own line.
        var document = try JSONDocument(source: "{\n  \"model\": \"opus\"\n}\n")
        try document.setString("https://x.example", forKey: "env", inObjectAt: [])
        let rendered = document.render()
        XCTAssertTrue(rendered.contains("\"model\": \"opus\",\n"), "got:\n" + rendered)
        XCTAssertFalse(rendered.contains("\n,\n"), "got:\n" + rendered)
        XCTAssertNotNil(try? JSONDocument(source: rendered))
    }

    func testCreatingAMissingEnvObjectKeepsOtherKeys() throws {
        var document = try JSONDocument(source: "{\n  \"model\": \"opus\",\n  \"permissions\": {}\n}\n")
        try document.ensureObject(atPath: ["env"])
        try document.setString("https://x.example", forKey: "ANTHROPIC_BASE_URL", inObjectAt: ["env"])
        let rendered = document.render()
        XCTAssertTrue(rendered.contains("\"env\""))
        XCTAssertTrue(rendered.contains("\"model\": \"opus\""))
        XCTAssertTrue(rendered.contains("\"permissions\": {}"))
        XCTAssertNotNil(try? JSONDocument(source: rendered))
    }

    func testRemovingAKeyLeavesValidJSON() throws {
        let original = """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://a.example",
            "ANTHROPIC_API_KEY": "sk-stale"
          }
        }
        """
        var document = try JSONDocument(source: original)
        try document.removeKey("ANTHROPIC_API_KEY", inObjectAt: ["env"])
        let rendered = document.render()
        XCTAssertFalse(rendered.contains("ANTHROPIC_API_KEY"))
        XCTAssertTrue(rendered.contains("https://a.example"))
        XCTAssertNotNil(try? JSONDocument(source: rendered))
        // The remaining member must not be left with a dangling separator.
        XCTAssertFalse(rendered.contains(",\n  }"))
    }

    func testRemovingAnAbsentKeyIsANoOp() throws {
        let original = "{\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n"
        var document = try JSONDocument(source: original)
        try document.removeKey("NOT_THERE", inObjectAt: ["env"])
        XCTAssertEqual(document.render(), original)
    }

    // MARK: - Comments and layout survive

    func testLineAndBlockCommentsSurviveAnEdit() throws {
        let original = """
        {
          // which backend this is
          "env": {
            /* the endpoint */
            "ANTHROPIC_BASE_URL": "https://a.example", // trailing note
          }
        }
        """
        var document = try JSONDocument(source: original)
        try document.setString("https://b.example", forKey: "ANTHROPIC_BASE_URL", inObjectAt: ["env"])
        let rendered = document.render()
        XCTAssertTrue(rendered.contains("// which backend this is"))
        XCTAssertTrue(rendered.contains("/* the endpoint */"))
        XCTAssertTrue(rendered.contains("// trailing note"))
        XCTAssertTrue(rendered.contains("https://b.example"))
    }

    func testTrailingCommaIsAccepted() throws {
        let document = try JSONDocument(source: "{\n  \"a\": 1,\n}\n")
        XCTAssertEqual(document.string(atPath: ["a"]), nil, "a number is not a string")
        XCTAssertNotNil(document.value(atPath: ["a"]))
    }

    // MARK: - Reading

    func testReadHelpers() throws {
        let document = try JSONDocument(source: """
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://a.example",
            "ANTHROPIC_MODEL": "m"
          }
        }
        """)
        XCTAssertEqual(document.string(atPath: ["env", "ANTHROPIC_BASE_URL"]), "https://a.example")
        XCTAssertEqual(document.keys(atPath: ["env"]).sorted(), ["ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL"])
        XCTAssertNil(document.string(atPath: ["env", "MISSING"]))
        XCTAssertNil(document.string(atPath: ["nothing", "here"]))
    }

    func testUnicodeAndEscapesRoundTrip() throws {
        var document = JSONDocument.empty()
        try document.setString("he said \"hi\"\n\ttab — 中文", forKey: "x", inObjectAt: [])
        let rendered = document.render()
        let reparsed = try JSONDocument(source: rendered)
        XCTAssertEqual(reparsed.string(atPath: ["x"]), "he said \"hi\"\n\ttab — 中文")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(rendered.utf8)))
    }

    func testEmptyFileBecomesAnObject() throws {
        var document = try JSONDocument(source: "")
        try document.setString("v", forKey: "k", inObjectAt: [])
        let rendered = document.render()
        XCTAssertTrue(rendered.contains("\"k\": \"v\""))
        XCTAssertNotNil(try JSONDocument(source: rendered).rootObject)
    }

    // MARK: - Refusals

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try JSONDocument(source: "{\"a\": }"))
        XCTAssertThrowsError(try JSONDocument(source: "{\"a\": 1"))
        XCTAssertThrowsError(try JSONDocument(source: "{\"a\": 1} trailing"))
    }

    func testWritingIntoANonObjectThrows() throws {
        let document = try JSONDocument(source: "{\n  \"env\": \"not an object\"\n}\n")
        XCTAssertNil(document.object(atPath: ["env"]))
        var mutable = document
        XCTAssertThrowsError(
            try mutable.setString("x", forKey: "k", inObjectAt: ["env"])
        )
    }

    func testMultipleEditsChainCorrectly() throws {
        // Each structural edit reparses, so an object created by one edit must be addressable by
        // the next. This is the case that breaks an implementation which caches spans.
        var document = try JSONDocument(source: "{\n  \"model\": \"opus\"\n}\n")
        try document.ensureObject(atPath: ["env"])
        try document.setString("https://a.example", forKey: "ANTHROPIC_BASE_URL", inObjectAt: ["env"])
        try document.setString("tok", forKey: "ANTHROPIC_AUTH_TOKEN", inObjectAt: ["env"])
        try document.setString("m1", forKey: "ANTHROPIC_MODEL", inObjectAt: ["env"])
        try document.removeKey("ANTHROPIC_MODEL", inObjectAt: ["env"])
        let rendered = document.render()
        let env = try JSONDocument(source: rendered).keys(atPath: ["env"]).sorted()
        XCTAssertEqual(env, ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"])
        XCTAssertTrue(rendered.contains("\"model\": \"opus\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(rendered.utf8)))
    }
}
