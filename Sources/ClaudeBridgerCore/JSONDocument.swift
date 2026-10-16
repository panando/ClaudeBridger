import Foundation

/// A JSON document that can be edited key by key without rewriting the parts it does not own.
///
/// Claude Code's settings.json is a file the user also hand-edits. Re-serialising the whole
/// document would reorder every key, normalise the indentation and drop any comment the user
/// added, so every switch would produce a diff that touches lines ClaudeBridger never meant to
/// change. This type instead records the byte span of each value and rewrites only the spans a
/// caller asks for: a value that changes is replaced in place, a key that is added is inserted
/// as a single member, and every other byte of the file survives untouched.
///
/// The parser accepts the JSON5-ish dialect editors put in these files — `//` and `/* */`
/// comments and a trailing comma before a closing brace or bracket — and preserves all of it,
/// because comments and commas are only ever skipped over, never rewritten.
public struct JSONDocument {

    // MARK: - Errors

    public enum ParseError: Error, LocalizedError, Equatable {
        case unexpectedEnd
        case unexpectedCharacter(String, offset: Int)
        case invalidEscape(offset: Int)
        case invalidUnicodeEscape(offset: Int)
        case trailingContent(offset: Int)
        case rootIsNotAnObject
        case notAnObject(path: String)
        case notAString(path: String)

        public var errorDescription: String? {
            switch self {
            case .unexpectedEnd:
                return "JSON 内容不完整"
            case let .unexpectedCharacter(character, offset):
                return "第 " + String(offset) + " 个字符处出现意外字符：" + character
            case let .invalidEscape(offset):
                return "第 " + String(offset) + " 个字符处的转义序列不合法"
            case let .invalidUnicodeEscape(offset):
                return "第 " + String(offset) + " 个字符处的 \\u 转义不合法"
            case let .trailingContent(offset):
                return "JSON 结尾第 " + String(offset) + " 个字符之后还有多余内容"
            case .rootIsNotAnObject:
                return "JSON 的顶层不是一个对象"
            case let .notAnObject(path):
                return "路径 " + path + " 不是一个对象"
            case let .notAString(path):
                return "路径 " + path + " 不是一个字符串"
            }
        }
    }

    // MARK: - Syntax tree

    /// A parsed value plus the span of source text it came from.
    public indirect enum Node {
        case object(ObjectNode)
        case array(ArrayNode)
        case string(StringNode)
        case scalar(ScalarNode)

        public var nodeRange: Range<String.Index> {
            switch self {
            case let .object(node): return node.open..<node.closeAfter
            case let .array(node): return node.open..<node.closeAfter
            case let .string(node): return node.range
            case let .scalar(node): return node.range
            }
        }
    }

    public struct Member {
        public let key: String
        public let keyRange: Range<String.Index>
        public let value: Node
        /// Key, colon and value together, so a member can be deleted as one span.
        public let span: Range<String.Index>
    }

    public struct ObjectNode {
        public let open: String.Index
        /// Index just past the closing brace.
        public let closeAfter: String.Index
        public let members: [Member]

        public var isEmpty: Bool { members.isEmpty }

        public func member(_ key: String) -> Member? { members.first { $0.key == key } }
    }

    public struct ArrayNode {
        public let open: String.Index
        public let closeAfter: String.Index
        public let elements: [Node]

        public var isEmpty: Bool { elements.isEmpty }
    }

    public struct StringNode {
        public let value: String
        /// Includes the surrounding quotes.
        public let range: Range<String.Index>
    }

    public struct ScalarNode {
        public let text: String
        public let range: Range<String.Index>
    }

    private struct Edit {
        let range: Range<String.Index>
        let replacement: String
    }

    // MARK: - State

    private(set) public var source: String
    private var root: Node
    private var edits: [Edit] = []

    /// Whitespace used for one indentation level when a new member has to be inserted.
    public var indentUnit: String = "  "

    // MARK: - Construction

    /// Parses `source`. Whitespace-only input is treated as an empty object, which is what a
    /// fresh settings.json that someone created with `touch` amounts to.
    public init(source: String, indentUnit: String = "  ") throws {
        self.indentUnit = indentUnit
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.source = "{}\n"
        } else {
            self.source = source
        }
        var parser = JSONParser(text: self.source)
        let node = try parser.parseDocument()
        self.root = node
    }

    /// Renders a blank document holding `{}`.
    public static func empty() -> JSONDocument {
        try! JSONDocument(source: "{}\n")
    }

    // MARK: - Reading

    /// The document's top level object.
    public var rootObject: ObjectNode? {
        if case let .object(node) = root { return node }
        return nil
    }

    /// The value at `path`, e.g. `["env"]` or `["env", "ANTHROPIC_MODEL"]`.
    public func value(atPath path: [String]) -> Node? {
        var current: Node = root
        for key in path {
            guard case let .object(node) = current, let member = node.member(key) else { return nil }
            current = member.value
        }
        return current
    }

    /// The object at `path`, when that path holds an object.
    public func object(atPath path: [String]) -> ObjectNode? {
        guard let node = value(atPath: path), case let .object(object) = node else { return nil }
        return object
    }

    /// The string at `path`, when that path holds a string.
    public func string(atPath path: [String]) -> String? {
        guard let node = value(atPath: path), case let .string(string) = node else { return nil }
        return string.value
    }

    /// Every key currently present in the object at `path`.
    public func keys(atPath path: [String]) -> [String] {
        object(atPath: path)?.members.map(\.key) ?? []
    }

    // MARK: - Writing

    /// Sets `key` inside the object at `parentPath` to `value`, replacing an existing member's
    /// value in place or inserting a new member when the key is absent.
    public mutating func setString(_ value: String, forKey key: String, inObjectAt parentPath: [String]) throws {
        try setValue(Self.jsonString(value), forKey: key, inObjectAt: parentPath)
    }

    /// Sets `key` to a raw JSON literal (a number, a boolean, or an already-encoded fragment).
    /// The caller is responsible for `raw` being valid JSON.
    public mutating func setRawValue(_ raw: String, forKey key: String, inObjectAt parentPath: [String]) throws {
        try setValue(raw, forKey: key, inObjectAt: parentPath)
    }

    /// Removes `key` from the object at `parentPath`. No-op when the key or the object is absent.
    ///
    /// Removing a key is how ClaudeBridger clears a variable it used to manage: it never leaves a
    /// stale `ANTHROPIC_API_KEY` behind, which the official docs say conflicts with
    /// `ANTHROPIC_AUTH_TOKEN`.
    ///
    /// The removed span has to include a separator as well as the member, or the two neighbouring
    /// members end up separated by a comma with nothing between it and the brace. Removing the key
    /// that happens to be last is the common case — `env` is built in order — so this is not an
    /// edge case: deleting several keys in a row is exactly what "restore official configuration"
    /// does.
    public mutating func removeKey(_ key: String, inObjectAt parentPath: [String]) throws {
        guard let object = object(atPath: parentPath),
              let index = object.members.firstIndex(where: { $0.key == key }) else { return }
        let member = object.members[index]
        let span: Range<String.Index>
        if index + 1 < object.members.count {
            // Not the last member: take the member and everything up to the next one, which
            // includes the comma that separated them.
            span = member.span.lowerBound..<object.members[index + 1].span.lowerBound
        } else if index > 0 {
            // Last member: take the separating comma that precedes it instead.
            span = object.members[index - 1].span.upperBound..<member.span.upperBound
        } else {
            span = member.span
        }
        edits.append(Edit(range: span, replacement: ""))
        try applyEditsAndReparse()
    }

    /// Ensures an object exists at `path`, creating it (and any missing intermediate object) when
    /// absent. Returns the resulting object.
    @discardableResult
    public mutating func ensureObject(atPath path: [String]) throws -> ObjectNode {
        if let existing = object(atPath: path) { return existing }
        guard !path.isEmpty else {
            throw ParseError.rootIsNotAnObject
        }
        // Create the parent first, so each step only ever has to add one member.
        let parentPath = Array(path.dropLast())
        if !parentPath.isEmpty {
            try ensureObject(atPath: parentPath)
        }
        let key = path[path.count - 1]
        try setValue("{}", forKey: key, inObjectAt: parentPath)
        guard let created = object(atPath: path) else {
            throw ParseError.notAnObject(path: path.joined(separator: "."))
        }
        return created
    }

    /// The document as text: the original bytes, with exactly the requested edits applied.
    public func render() -> String {
        Self.apply(edits: edits, to: source)
    }

    // MARK: - Edit mechanics

    private mutating func setValue(_ raw: String, forKey key: String, inObjectAt parentPath: [String]) throws {
        guard let object = object(atPath: parentPath) else {
            throw ParseError.notAnObject(path: parentPath.isEmpty ? "<root>" : parentPath.joined(separator: "."))
        }
        if let member = object.member(key) {
            edits.append(Edit(range: member.value.nodeRange, replacement: raw))
        } else {
            edits.append(insertionEdit(for: key, value: raw, in: object))
        }
        try applyEditsAndReparse()
    }

    /// The edit that adds a member to `object`.
    ///
    /// Insertion replaces the whitespace between the last member and the closing brace rather
    /// than the brace itself, so the separator comma lands at the end of the previous line. Doing
    /// it at the brace is what produces the classic `"opus"\n,\n  "env"` result, where the comma
    /// gets a line of its own.
    private func insertionEdit(for key: String, value raw: String, in object: ObjectNode) -> Edit {
        let closeBrace = source.index(before: object.closeAfter)
        let baseIndent = leadingWhitespaceOfLine(containing: object.open)
        let quotedKey = Self.jsonString(key)
        // A file written on one line stays on one line.
        let objectSpansLines = source[object.open..<object.closeAfter].contains("\n")
        if let last = object.members.last {
            if !objectSpansLines {
                return Edit(
                    range: last.span.upperBound..<closeBrace,
                    replacement: ", " + quotedKey + ": " + raw
                )
            }
            // Members exist, so the indent is whatever the file already uses.
            let memberIndent = leadingWhitespaceOfLine(containing: last.keyRange.lowerBound)
            let tail = source[last.span.upperBound..<closeBrace]
            // A brace that shares the last member's line becomes a newline-terminated block; a
            // brace already on its own line keeps that shape.
            let closingOnOwnLine = tail.contains("\n")
            let replacement = ",\n" + memberIndent + quotedKey + ": " + raw
                + (closingOnOwnLine ? "\n" + baseIndent : "")
            return Edit(range: last.span.upperBound..<closeBrace, replacement: replacement)
        }
        if !objectSpansLines {
            return Edit(
                range: source.index(after: object.open)..<closeBrace,
                replacement: quotedKey + ": " + raw
            )
        }
        let memberIndent = baseIndent + indentUnit
        let afterOpen = source.index(after: object.open)
        let replacement = "\n" + memberIndent + quotedKey + ": " + raw + "\n" + baseIndent
        return Edit(range: afterOpen..<closeBrace, replacement: replacement)
    }

    /// The whitespace from the start of `index`'s line up to the first non-whitespace character.
    private func leadingWhitespaceOfLine(containing index: String.Index) -> String {
        var start = index
        while start > source.startIndex {
            let previous = source.index(before: start)
            if source[previous] == "\n" { break }
            start = previous
        }
        var result = ""
        var cursor = start
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\t" {
            result.append(source[cursor])
            cursor = source.index(after: cursor)
        }
        return result
    }

    /// Applies the pending edits, adopts the result as the new source and reparses.
    ///
    /// Reparsing after every structural change is what lets several edits be chained: an inserted
    /// `env` object has no spans in the old source, but it does in the rendered text. The cost is
    /// one parse per edit on a file of a few kilobytes, which is nothing next to a wrong write.
    private mutating func applyEditsAndReparse() throws {
        let rendered = Self.apply(edits: edits, to: source)
        edits = []
        source = rendered
        var parser = JSONParser(text: rendered)
        root = try parser.parseDocument()
    }

    private static func apply(edits: [Edit], to source: String) -> String {
        guard !edits.isEmpty else { return source }
        let ordered = edits.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var output = ""
        var cursor = source.startIndex
        for edit in ordered {
            // Overlapping edits would mean two operations claimed the same bytes; keep the first
            // and drop the later one rather than producing corrupted JSON.
            guard edit.range.lowerBound >= cursor else { continue }
            output += source[cursor..<edit.range.lowerBound]
            output += edit.replacement
            cursor = edit.range.upperBound
        }
        output += source[cursor...]
        return output
    }

    /// Escapes a Swift string as a JSON string literal, quotes included.
    static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

/// A recursive-descent JSON reader that records where every value came from.
///
/// Comments and trailing commas are skipped, never recorded, so they pass through to the output
/// unchanged.
struct JSONParser {
    let text: String
    var index: String.Index

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    private var offset: Int { text.distance(from: text.startIndex, to: index) }

    mutating func parseDocument() throws -> JSONDocument.Node {
        skipTrivia()
        guard index < text.endIndex else { throw JSONDocument.ParseError.unexpectedEnd }
        let value = try parseValue()
        skipTrivia()
        guard index >= text.endIndex else {
            throw JSONDocument.ParseError.trailingContent(offset: offset)
        }
        return value
    }

    // MARK: - Trivia

    private mutating func skipTrivia() {
        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                index = text.index(after: index)
                continue
            }
            if character == "/", let next = peek(1) {
                if next == "/" {
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if next == "*" {
                    index = text.index(index, offsetBy: 2)
                    while index < text.endIndex {
                        if text[index] == "*", peek(1) == "/" {
                            index = text.index(index, offsetBy: 2)
                            break
                        }
                        index = text.index(after: index)
                    }
                    continue
                }
            }
            break
        }
    }

    private func peek(_ distance: Int) -> Character? {
        guard let target = text.index(index, offsetBy: distance, limitedBy: text.endIndex),
              target < text.endIndex else { return nil }
        return text[target]
    }

    // MARK: - Values

    private mutating func parseValue() throws -> JSONDocument.Node {
        guard index < text.endIndex else { throw JSONDocument.ParseError.unexpectedEnd }
        switch text[index] {
        case "{": return .object(try parseObject())
        case "[": return .array(try parseArray())
        case "\"": return .string(try parseString())
        default: return .scalar(try parseScalar())
        }
    }

    private mutating func parseObject() throws -> JSONDocument.ObjectNode {
        let open = index
        index = text.index(after: index)
        var members: [JSONDocument.Member] = []
        skipTrivia()
        if index < text.endIndex, text[index] == "}" {
            index = text.index(after: index)
            return JSONDocument.ObjectNode(open: open, closeAfter: index, members: [])
        }
        while true {
            skipTrivia()
            guard index < text.endIndex else { throw JSONDocument.ParseError.unexpectedEnd }
            let memberStart = index
            let keyNode = try parseString()
            skipTrivia()
            guard index < text.endIndex, text[index] == ":" else {
                throw JSONDocument.ParseError.unexpectedCharacter(
                    index < text.endIndex ? String(text[index]) : "<结尾>", offset: offset
                )
            }
            index = text.index(after: index)
            skipTrivia()
            let value = try parseValue()
            let span = memberStart..<value.nodeRange.upperBound
            members.append(
                JSONDocument.Member(key: keyNode.value, keyRange: keyNode.range, value: value, span: span)
            )
            skipTrivia()
            guard index < text.endIndex else { throw JSONDocument.ParseError.unexpectedEnd }
            if text[index] == "," {
                index = text.index(after: index)
                skipTrivia()
                // A trailing comma before the closing brace is legal here and is kept as-is.
                if index < text.endIndex, text[index] == "}" { break }
                continue
            }
            if text[index] == "}" { break }
            throw JSONDocument.ParseError.unexpectedCharacter(String(text[index]), offset: offset)
        }
        guard index < text.endIndex, text[index] == "}" else {
            throw JSONDocument.ParseError.unexpectedEnd
        }
        index = text.index(after: index)
        return JSONDocument.ObjectNode(open: open, closeAfter: index, members: members)
    }

    private mutating func parseArray() throws -> JSONDocument.ArrayNode {
        let open = index
        index = text.index(after: index)
        var elements: [JSONDocument.Node] = []
        skipTrivia()
        if index < text.endIndex, text[index] == "]" {
            index = text.index(after: index)
            return JSONDocument.ArrayNode(open: open, closeAfter: index, elements: [])
        }
        while true {
            skipTrivia()
            elements.append(try parseValue())
            skipTrivia()
            guard index < text.endIndex else { throw JSONDocument.ParseError.unexpectedEnd }
            if text[index] == "," {
                index = text.index(after: index)
                skipTrivia()
                if index < text.endIndex, text[index] == "]" { break }
                continue
            }
            if text[index] == "]" { break }
            throw JSONDocument.ParseError.unexpectedCharacter(String(text[index]), offset: offset)
        }
        guard index < text.endIndex, text[index] == "]" else {
            throw JSONDocument.ParseError.unexpectedEnd
        }
        index = text.index(after: index)
        return JSONDocument.ArrayNode(open: open, closeAfter: index, elements: elements)
    }

    private mutating func parseString() throws -> JSONDocument.StringNode {
        guard index < text.endIndex, text[index] == "\"" else {
            throw JSONDocument.ParseError.unexpectedCharacter(
                index < text.endIndex ? String(text[index]) : "<结尾>", offset: offset
            )
        }
        let start = index
        index = text.index(after: index)
        var value = ""
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                index = text.index(after: index)
                return JSONDocument.StringNode(value: value, range: start..<index)
            }
            if character == "\\" {
                let escapeStart = index
                index = text.index(after: index)
                guard index < text.endIndex else { throw JSONDocument.ParseError.unexpectedEnd }
                let escape = text[index]
                index = text.index(after: index)
                switch escape {
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "/": value.append("/")
                case "b": value.append("\u{08}")
                case "f": value.append("\u{0C}")
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "u":
                    guard let hex = hexQuad() else {
                        throw JSONDocument.ParseError.invalidUnicodeEscape(
                            offset: text.distance(from: text.startIndex, to: escapeStart)
                        )
                    }
                    if let scalar = Unicode.Scalar(hex) {
                        value.unicodeScalars.append(scalar)
                    } else {
                        throw JSONDocument.ParseError.invalidUnicodeEscape(
                            offset: text.distance(from: text.startIndex, to: escapeStart)
                        )
                    }
                default:
                    throw JSONDocument.ParseError.invalidEscape(
                        offset: text.distance(from: text.startIndex, to: escapeStart)
                    )
                }
                continue
            }
            value.append(character)
            index = text.index(after: index)
        }
        throw JSONDocument.ParseError.unexpectedEnd
    }

    /// Reads the four hex digits of a `\u` escape; the scalar is returned as a UTF-16 code unit.
    private mutating func hexQuad() -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < text.endIndex, let digit = text[index].hexDigitValue else { return nil }
            value = value << 4 | UInt32(digit)
            index = text.index(after: index)
        }
        return value
    }

    private mutating func parseScalar() throws -> JSONDocument.ScalarNode {
        let start = index
        let terminators: Set<Character> = [",", "}", "]", " ", "\t", "\n", "\r", "/"]
        while index < text.endIndex, !terminators.contains(text[index]) {
            index = text.index(after: index)
        }
        guard start < index else {
            throw JSONDocument.ParseError.unexpectedCharacter(
                index < text.endIndex ? String(text[index]) : "<结尾>", offset: offset
            )
        }
        let raw = String(text[start..<index])
        switch raw {
        case "true", "false", "null":
            break
        default:
            // A number, or something malformed that the caller will notice on the next parse.
            guard raw.first == "-" || raw.first?.isNumber == true else {
                throw JSONDocument.ParseError.unexpectedCharacter(raw, offset: text.distance(from: text.startIndex, to: start))
            }
        }
        return JSONDocument.ScalarNode(text: raw, range: start..<index)
    }
}
