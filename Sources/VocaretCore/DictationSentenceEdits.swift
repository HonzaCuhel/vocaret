import Foundation

/// Require an explicit edit for every source sentence rather than a free-form summary.
enum DictationSentenceEdits {
    static func key(_ index: Int) -> String { String(format: "%04d", index) }

    static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"(?<=[.!?])\s+(?=\p{Lu})"#, with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func render(_ output: String, original: String) throws -> String {
        let edits = try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
        let count = sentences(original).count
        guard Set(edits.keys) == Set((0..<count).map(key)) else {
            throw OpenAIDictationCleanerError.invalidResponse
        }
        let values = (0..<count).compactMap { edits[key($0)] }
            .map(PlainDictationDocument.plainText).filter { !$0.isEmpty }
        guard !values.isEmpty else { throw OpenAIDictationCleanerError.emptyOutput }
        var paragraphs: [String] = []
        var prose: [String] = []
        func flush() {
            if !prose.isEmpty { paragraphs.append(prose.joined(separator: " ")); prose = [] }
        }
        for value in values {
            if value.contains("\n") {
                flush()
                paragraphs.append(value)
            } else {
                prose.append(value)
                if prose.count == 3 { flush() }
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    static func format(count: Int) -> [String: Any] {
        let keys = (0..<count).map(key)
        return ["type": "json_schema", "name": "sentence_edits", "strict": true,
                "schema": ["type": "object", "additionalProperties": false,
                           "required": keys, "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, ["type": "string"]) })]]
    }
}
