import Foundation

/// Everything the dashboard shows, computed from the record list. Pure.
public struct DashboardStats: Equatable, Sendable {
    public struct DayWords: Equatable, Sendable, Identifiable {
        public var id: Date { day }
        public var day: Date
        public var words: Int
    }

    public var totalWords = 0
    public var wordsToday = 0
    public var wordsThisWeek = 0
    public var totalSessions = 0
    public var totalRecordingSeconds = 0.0
    /// Words per minute of speech across all sessions (words / minutes spoken).
    public var averageWPM = 0.0
    /// Median transcription latency, what "fast" feels like day to day.
    public var medianLatency = 0.0
    /// Time saved versus typing at `typingWPM`.
    public var timeSavedSeconds = 0.0
    public var streakDays = 0
    /// 24 buckets, words dictated in each hour of the day (all time).
    public var wordsByHour = [Int](repeating: 0, count: 24)
    public var peakHour: Int?
    /// Last 14 days, oldest first.
    public var dailyWords: [DayWords] = []

    /// A comfortable touch-typist; the same baseline VoiceInk uses.
    public static let typingWPM = 40.0

    public static func compute(records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) -> DashboardStats {
        var stats = DashboardStats()
        guard !records.isEmpty else {
            stats.dailyWords = lastDays(14, now: now, calendar: calendar).map { DayWords(day: $0, words: 0) }
            return stats
        }

        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today)!
        var wordsPerDay: [Date: Int] = [:]
        var latencies: [Double] = []
        // Only records that carry timing take part in pace / time-saved maths;
        // imported ones (no timing) still count toward totals and streaks.
        var timedWords = 0

        for record in records {
            let words = record.wordCount
            stats.totalWords += words
            stats.totalSessions += 1
            if record.recordingSeconds > 0 {
                stats.totalRecordingSeconds += record.recordingSeconds
                timedWords += words
            }
            if record.transcriptionSeconds > 0 { latencies.append(record.transcriptionSeconds) }

            let day = calendar.startOfDay(for: record.date)
            wordsPerDay[day, default: 0] += words
            if day == today { stats.wordsToday += words }
            if day >= weekAgo { stats.wordsThisWeek += words }
            stats.wordsByHour[calendar.component(.hour, from: record.date)] += words
        }

        if stats.totalRecordingSeconds > 0 {
            stats.averageWPM = Double(timedWords) / (stats.totalRecordingSeconds / 60)
        }
        let sorted = latencies.sorted()
        stats.medianLatency = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let typingSeconds = Double(timedWords) / typingWPM * 60
        stats.timeSavedSeconds = max(0, typingSeconds - stats.totalRecordingSeconds)

        if let best = stats.wordsByHour.enumerated().max(by: { $0.element < $1.element }), best.element > 0 {
            stats.peakHour = best.offset
        }

        // Streak: consecutive days with at least one dictation, ending today or yesterday.
        var cursor = today
        if wordsPerDay[cursor] == nil { cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        while wordsPerDay[cursor] != nil {
            stats.streakDays += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        stats.dailyWords = lastDays(14, now: now, calendar: calendar).map { DayWords(day: $0, words: wordsPerDay[$0] ?? 0) }
        return stats
    }

    private static func lastDays(_ count: Int, now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }
}

/// Deterministic speaking-style measurements the coach builds on. No LLM.
public struct SpeechAnalysis: Equatable, Sendable {
    public struct Filler: Equatable, Sendable, Identifiable {
        public var id: String { word }
        public var word: String
        public var count: Int
    }

    public var totalWords = 0
    public var fillerCount = 0
    /// Fillers per 100 words.
    public var fillerRate = 0.0
    public var topFillers: [Filler] = []
    public var averageSentenceLength = 0.0
    /// Moving-average type/token ratio over 100-word windows (MATTR). Higher =
    /// richer. Conversational speech lands around 0.65–0.75; unlike raw TTR it
    /// does not fall as the user dictates more.
    public var vocabularyRichness = 0.0
    public var longestSentenceWords = 0

    /// Czech and English fillers, lower-cased. Multi-word entries are matched
    /// as phrases before single words are counted.
    public static let fillerPhrases = ["you know", "sort of", "kind of", "že jo", "tak nějak", "jako by"]
    public static let fillerWords: Set<String> = [
        "ehm", "hmm", "hm", "eee", "jako", "vlastně", "prostě", "takže", "jakoby", "jo", "teda", "tedy",
        "um", "uh", "er", "like", "basically", "actually", "literally", "right",
    ]

    public static func analyze(texts: [String]) -> SpeechAnalysis {
        var analysis = SpeechAnalysis()
        guard !texts.isEmpty else { return analysis }

        var fillerCounts: [String: Int] = [:]
        var tokens: [String] = []
        var sentenceLengths: [Int] = []

        for text in texts {
            for rawSentence in splitSentences(text) {
                var lower = rawSentence.lowercased()
                for phrase in fillerPhrases {
                    let occurrences = lower.components(separatedBy: phrase).count - 1
                    if occurrences > 0 {
                        fillerCounts[phrase, default: 0] += occurrences
                        lower = lower.replacingOccurrences(of: phrase, with: " ")
                    }
                }
                let words = lower
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                guard !words.isEmpty else { continue }
                sentenceLengths.append(words.count)
                for word in words {
                    analysis.totalWords += 1
                    tokens.append(word)
                    if fillerWords.contains(word) { fillerCounts[word, default: 0] += 1 }
                }
            }
        }

        analysis.fillerCount = fillerCounts.values.reduce(0, +)
        analysis.fillerRate = analysis.totalWords > 0 ? Double(analysis.fillerCount) / Double(analysis.totalWords) * 100 : 0
        analysis.topFillers = fillerCounts
            .map { Filler(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
            .prefix(6)
            .map { $0 }
        analysis.averageSentenceLength = sentenceLengths.isEmpty ? 0 : Double(sentenceLengths.reduce(0, +)) / Double(sentenceLengths.count)
        analysis.longestSentenceWords = sentenceLengths.max() ?? 0
        analysis.vocabularyRichness = movingAverageTTR(tokens, window: 100)
        return analysis
    }

    /// Sentence boundaries: `.`, `!` or `?` (plus any closing quote) followed
    /// by whitespace and something that can start a sentence — a capital
    /// letter, an opening quote, or a digit ("5 minut.", "18. srpna jedeme.")
    /// — or the end of the text. Splitting on every period instead would chop
    /// Czech ordinals ("v 9. patře"), abbreviations ("např.") and decimals
    /// ("2.5", never followed by whitespace) into one-word "sentences".
    static func splitSentences(_ text: String) -> [String] {
        let ns = text as NSString
        let matches = sentenceBoundary.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var sentences: [String] = []
        var start = 0
        for match in matches {
            let end = match.range.location + match.range.length
            sentences.append(ns.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
        if start < ns.length { sentences.append(ns.substring(from: start)) }
        return sentences
    }
    private static let sentenceBoundary = try! NSRegularExpression(
        pattern: #"[.!?]+[”“»"')\]]*(?=\s+[\p{Lu}\p{Nd}„“"'(\[]|\s*$)"#)

    /// Mean type/token ratio over sliding `window`-token windows (MATTR). Raw
    /// TTR falls as the corpus grows (Heaps' law), so a heavy user would be
    /// told their vocabulary "repeats a lot" just for dictating more. MATTR is
    /// stable across sample sizes; falls back to raw TTR below one window.
    static func movingAverageTTR(_ tokens: [String], window: Int) -> Double {
        guard !tokens.isEmpty else { return 0 }
        guard tokens.count > window else { return Double(Set(tokens).count) / Double(tokens.count) }
        var counts: [String: Int] = [:]
        var distinct = 0
        var sum = 0.0
        var windows = 0
        for (index, token) in tokens.enumerated() {
            if counts[token, default: 0] == 0 { distinct += 1 }
            counts[token, default: 0] += 1
            if index >= window {
                let leaving = tokens[index - window]
                counts[leaving]! -= 1
                if counts[leaving] == 0 { distinct -= 1 }
            }
            if index >= window - 1 {
                sum += Double(distinct) / Double(window)
                windows += 1
            }
        }
        return sum / Double(windows)
    }
}
