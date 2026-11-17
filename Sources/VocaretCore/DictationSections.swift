import Foundation

/// Split only a coherent spoken task sequence; isolated ordinals remain ordinary speech.
enum DictationSections {
    struct Section: Equatable { let ordinal: Int?; let text: String }

    static func split(_ text: String) -> [Section] {
        let source = text as NSString
        let patterns = [
            #"(?i)\b(?:zaprvé|za prvé|první věc|firstly|first task)\b"#,
            #"(?i)\b(?:za druhé|zadruhé|secondly|second task)\b"#,
            #"(?i)\b(?:za třetí|zatřetí|thirdly|third task)\b"#
        ]
        let matches = patterns.map { pattern in
            try! NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(location: 0, length: source.length))
        }
        guard let second = matches[1].first(where: { second in matches[0].contains { $0.range.location < second.range.location } }),
              let first = matches[0].last(where: { $0.range.location < second.range.location }) else {
            return [Section(ordinal: nil, text: text)]
        }
        var starts = [first.range.location, second.range.location]
        // A later repair may revise an earlier task. Keep its complete context
        // in one request rather than finalizing the earlier section too soon.
        let laterTasks = source.substring(from: second.range.location)
        if laterTasks.range(of: #"(?i)\b(?:oprav\p{L}*|vrátím|vracím|vlastně|teda ne|tedy ne|actually|correction|i mean|make that|nein|non pardon|perdón)\b"#, options: .regularExpression) != nil {
            return [Section(ordinal: nil, text: text)]
        }
        if let third = matches[2].first(where: { $0.range.location > second.range.location }) { starts.append(third.range.location) }
        var result: [Section] = []
        if starts[0] > 0 {
            let introduction = source.substring(to: starts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fillerOnly = introduction.range(of: #"(?i)^(?:(?:a|no|takže|and|well|so)[\s,.:]*)+$"#, options: .regularExpression) != nil
            if !introduction.isEmpty, !fillerOnly { result.append(Section(ordinal: nil, text: introduction)) }
        }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : source.length
            result.append(Section(ordinal: index + 1, text: source.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return result
    }
}
