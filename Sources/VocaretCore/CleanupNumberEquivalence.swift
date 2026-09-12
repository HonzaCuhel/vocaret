import CoreFoundation
import Foundation

/// Normalizes numbers only for validation. Returned text is never delivered to
/// the user: the AI remains responsible for all wording and formatting.
enum CleanupNumberEquivalence {
    struct Check {
        let original: String
        let cleaned: String
        let isSupported: Bool
    }

    private struct Replacement {
        var range: NSRange
        var value: String
    }

    static func check(original: String, cleaned: String) -> Check {
        let sourceDigits = digitReplacements(in: original)
        let outputDigits = digitReplacements(in: cleaned)
        let outputValues = Set(outputDigits.map(\.value))
        let source = replacing(sourceDigits, in: original)
        let output = replacing(outputDigits, in: cleaned)
        let missing = outputValues.subtracting(sourceDigits.map(\.value))
        guard !missing.isEmpty else {
            return Check(original: source, cleaned: output, isSupported: true)
        }
        let spoken = spokenReplacements(in: source, needed: missing)
        return Check(
            original: replacing(spoken, in: source), cleaned: output,
            isSupported: missing.isSubset(of: Set(spoken.map(\.value)))
        )
    }

    private static func digitReplacements(in text: String) -> [Replacement] {
        // Space grouping is unambiguous only for complete three-digit groups.
        // Decimal punctuation stays exact; 30,50 must never become 3050.
        let pattern = #"(?<![\p{L}\p{N}])[+−-]?(?:\p{N}{1,3}(?:[ \u00A0\u202F]\p{N}{3})+|\p{N}+)(?:[.,]\p{N}+)*(?!\p{N})"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            let value = string.substring(with: match.range)
                .filter { !$0.isWhitespace }.replacingOccurrences(of: "−", with: "-")
            return includingPrecedingSign(Replacement(range: match.range, value: value), in: string)
        }
    }

    private static func spokenReplacements(in text: String, needed: Set<String>) -> [Replacement] {
        let string = text as NSString
        let words = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+"#)
            .matches(in: string as String, range: NSRange(location: 0, length: string.length))
        let formatters = ["cs_CZ", "en_US", "de_DE", "fr_FR", "es_ES"].compactMap {
            CFNumberFormatterCreate(nil, Locale(identifier: $0) as NSLocale as CFLocale, .spellOutStyle)
        }
        var replacements: [Replacement] = []
        var skipUntil = 0
        for (index, word) in words.enumerated() where word.range.location >= skipUntil {
            // Bound native parsing to twelve words; reject larger/ambiguous
            // compounds rather than infer a number from an arbitrary prefix.
            let end = NSMaxRange(words[min(index + 11, words.count - 1)].range)
            let candidate = string.substring(with: NSRange(location: word.range.location, length: end - word.range.location)).lowercased()
            var best: Replacement?
            var longestConsumed = 0
            for formatter in formatters {
                var consumed = CFRange(location: 0, length: (candidate as NSString).length)
                guard let number = CFNumberFormatterCreateNumberFromString(nil, formatter, candidate as CFString, &consumed, 0),
                      consumed.location == 0, consumed.length > 0 else { continue }
                longestConsumed = max(longestConsumed, consumed.length)
                if consumed.length == (candidate as NSString).length, index + 12 < words.count {
                    // The bounded window might have cut a longer number in
                    // half. Do not authorize its prefix or reconsider its tail.
                    longestConsumed = string.length - word.range.location
                    best = nil
                    break
                }
                let range = NSRange(location: word.range.location, length: consumed.length)
                guard words.contains(where: { NSMaxRange($0.range) == NSMaxRange(range) }) else { continue }
                let value = number as NSNumber
                guard value.doubleValue.isFinite, abs(value.doubleValue) <= 1e15,
                      value.doubleValue.rounded() == value.doubleValue,
                      let roundTrip = CFNumberFormatterCreateStringWithNumber(nil, formatter, number),
                      CleanupGuard.normalizedWords(roundTrip as String) == CleanupGuard.normalizedWords(string.substring(with: range)) else { continue }
                let replacement = includingPrecedingSign(Replacement(range: range, value: value.stringValue), in: string)
                if replacement.range.length > (best?.range.length ?? 0) { best = replacement }
            }
            // Never reconsider the tail of an unaccepted compound: "thirty
            // five" must not authorize either 30 or 5 after a failed parse.
            skipUntil = max(NSMaxRange(word.range), word.range.location + longestConsumed)
            if let best, needed.contains(best.value) { replacements.append(best) }
        }
        return replacements
    }

    private static func includingPrecedingSign(_ number: Replacement, in string: NSString) -> Replacement {
        let prefix = string.substring(to: number.range.location)
        let regex = try! NSRegularExpression(pattern: #"([\p{L}\p{M}]+)\s+$"#)
        guard let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)),
              let word = CleanupGuard.normalizedWords((prefix as NSString).substring(with: match.range(at: 1))).first,
              ["minus", "negative", "negativ", "negativo", "moins", "menos"].contains(word) else { return number }
        return Replacement(
            range: NSRange(location: match.range.location, length: NSMaxRange(number.range) - match.range.location),
            value: "-" + number.value
        )
    }

    private static func replacing(_ replacements: [Replacement], in text: String) -> String {
        let result = NSMutableString(string: text)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: replacement.range, with: replacement.value)
        }
        return result as String
    }
}
