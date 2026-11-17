import Foundation

/// Remove presentation markup before pasting plain dictation text.
enum PlainDictationDocument {
    static func withoutSpokenOrdinal(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)^(?:a\s+)?(?:za prvé|za druhé|za třetí|zaprvé|zadruhé|zatřetí|firstly|secondly|thirdly)\s*[:,]?\s*"#, with: "", options: .regularExpression)
    }

    static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^[ \t]*```[^\n]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*[-*]\s+"#, with: "• ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*([^\n]+?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
