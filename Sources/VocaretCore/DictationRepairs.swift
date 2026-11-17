import Foundation

/// Apply narrowly quoted speech repairs while leaving all surrounding text intact.
enum DictationRepairs {
    struct Edit: Decodable { let before: String; let after: String }
    struct Response: Decodable { let edits: [Edit] }

    static func consistsOfSimpleTokenCorrections(_ output: String) throws -> Bool {
        let edits = try JSONDecoder().decode(Response.self, from: Data(output.utf8)).edits
        let pattern = #"\b[\p{L}\p{N}]+,\s*(?:ne|no|nein|non),\s*([\p{L}\p{N}]+)\b"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return !edits.isEmpty && edits.allSatisfy { edit in
            let before = edit.before as NSString
            let range = NSRange(location: 0, length: before.length)
            guard regex.firstMatch(in: edit.before, range: range) != nil else { return false }
            // The quote may contain a whole sentence, but everything outside
            // the explicit token swap must remain byte-for-byte unchanged.
            return regex.stringByReplacingMatches(in: edit.before, range: range, withTemplate: "$1") == edit.after
        }
    }

    static func needsRepair(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(?:teda\s*,?\s*ne|tedy\s*,?\s*ne|ne\s*,|vlastně|uvědomuju|opravuji|oprava|změň ho|actually|i mean|make that|nein|non\s*,?\s*pardon|perdón)(?=\W|$)"#, options: .regularExpression) != nil
    }

    static func apply(_ output: String, to original: String) throws -> String {
        let edits = try JSONDecoder().decode(Response.self, from: Data(output.utf8)).edits
        var result = original
        // Locate every quote against the original, then replace backwards so
        // offsets and repeated replacement text cannot affect later matches.
        var replacements: [(Range<String.Index>, String)] = []
        for edit in edits {
            guard !edit.before.isEmpty, let range = original.range(of: edit.before),
                  original[range.upperBound...].range(of: edit.before) == nil,
                  !replacements.contains(where: { $0.0.overlaps(range) }) else {
                throw OpenAIDictationCleanerError.invalidResponse
            }
            replacements.append((range, edit.after))
        }
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: replacement)
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              CleanupNumberEquivalence.check(original: original, cleaned: result).isSupported else {
            throw OpenAIDictationCleanerError.invalidResponse
        }
        return result
    }

    static var format: [String: Any] {
        ["type": "json_schema", "name": "speech_repairs", "strict": true,
         "schema": ["type": "object", "additionalProperties": false, "required": ["edits"],
                    "properties": ["edits": ["type": "array", "items": [
                        "type": "object", "additionalProperties": false, "required": ["before", "after"],
                        "properties": ["before": ["type": "string"], "after": ["type": "string"]]]]]]]
    }
}
