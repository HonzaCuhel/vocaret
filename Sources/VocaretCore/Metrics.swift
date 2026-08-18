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
    /// Type/token ratio — unique words over all words. Higher = richer.
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
        var uniqueWords = Set<String>()
        var sentenceLengths: [Int] = []

        for text in texts {
            var lower = text.lowercased()
            for phrase in fillerPhrases {
                let occurrences = lower.components(separatedBy: phrase).count - 1
                if occurrences > 0 {
                    fillerCounts[phrase, default: 0] += occurrences
                    lower = lower.replacingOccurrences(of: phrase, with: " ")
                }
            }
            for sentence in lower.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
                let words = sentence
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                guard !words.isEmpty else { continue }
                sentenceLengths.append(words.count)
                for word in words {
                    analysis.totalWords += 1
                    uniqueWords.insert(word)
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
        analysis.vocabularyRichness = analysis.totalWords > 0 ? Double(uniqueWords.count) / Double(analysis.totalWords) : 0
        return analysis
    }
}
