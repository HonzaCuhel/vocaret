import Foundation

/// A speaking coach that reads your own dictations. Two layers:
/// 1. deterministic measurements (SpeechAnalysis) and a curated reading list
///    matched to what those measurements show — always available;
/// 2. a short personalised note written by the local LLM, when it is running.
public struct CoachReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var sampleSize: Int
    public var periodDays: Int
    public var wordsAnalyzed: Int
    public var fillerRate: Double
    public var topFillers: [String]
    public var averageSentenceLength: Double
    public var vocabularyRichness: Double
    public var averageWPM: Double
    /// Short, concrete observations, in the user's dominant language.
    public var observations: [String]
    /// LLM-written paragraph(s); nil when llama-server was unavailable.
    public var advice: String?
    public var books: [Book]

    public struct Book: Codable, Equatable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var author: String
        public var why: String
        public var czechEdition: String?
    }
}

public enum SpeechCoach {
    /// What a book helps with, so we can match books to measured weaknesses.
    enum Focus { case fillers, structure, clarity, delivery, storytelling, concision }

    struct CuratedBook {
        let title: String
        let author: String
        let czech: String?
        let focus: [Focus]
        let why: String
    }

    /// Real, in-print books. Czech editions listed where they exist.
    static let library: [CuratedBook] = [
        .init(title: "How to Speak (MIT lecture)", author: "Patrick Winston", czech: nil, focus: [.structure, .delivery],
              why: "One free hour that fixes how you open, structure and close a talk. Watch it before reading anything."),
        .init(title: "The Pyramid Principle", author: "Barbara Minto", czech: nil, focus: [.structure, .concision],
              why: "Say the conclusion first, then support it. The single best cure for rambling."),
        .init(title: "On Writing Well", author: "William Zinsser", czech: nil, focus: [.clarity, .concision],
              why: "About writing, but every chapter is about cutting clutter — which is exactly what filler words are."),
        .init(title: "The Sense of Style", author: "Steven Pinker", czech: nil, focus: [.clarity],
              why: "Why smart people are unclear (the curse of knowledge) and how to explain things the listener can follow."),
        .init(title: "TED Talks: The Official TED Guide to Public Speaking", author: "Chris Anderson",
              czech: "TED Talks: Průvodce veřejným vystupováním (Jan Melvil)", focus: [.delivery, .storytelling],
              why: "How to build one idea worth sharing and deliver it without notes."),
        .init(title: "Talk Like TED", author: "Carmine Gallo", czech: "Mluvte jako na TEDu (Grada)", focus: [.storytelling, .delivery],
              why: "Nine habits of the most-watched talks, with drills you can do in a week."),
        .init(title: "Moderní rétorika", author: "Alena Špačková", czech: "Moderní rétorika (Grada)", focus: [.delivery, .fillers],
              why: "Czech-language rhetoric handbook: breath, tempo, pauses instead of \"ehm\", and Czech-specific pitfalls."),
        .init(title: "Rétorika a řečová kultura", author: "Jiří Kraus", czech: "Rétorika a řečová kultura (Karolinum)", focus: [.clarity, .structure],
              why: "The academic Czech text on speaking well — dense, but the chapters on argument structure repay the effort."),
        .init(title: "How to Be Heard", author: "Julian Treasure", czech: nil, focus: [.delivery, .fillers],
              why: "Voice, pace, pauses and the habits that make people stop listening. Practical exercises."),
        .init(title: "Nonviolent Communication", author: "Marshall Rosenberg", czech: "Nenásilná komunikace (Portál)", focus: [.clarity],
              why: "Saying exactly what you observe, feel and need — a template for unambiguous sentences."),
        .init(title: "Made to Stick", author: "Chip & Dan Heath", czech: "Nápad za milion (Jan Melvil)", focus: [.storytelling, .concision],
              why: "Why some explanations survive and most evaporate; how to make yours concrete and memorable."),
    ]

    /// Analyze the most recent `days` of dictation and produce a report.
    /// `generate` is the LLM hook (nil-returning when unavailable).
    public static func report(
        records: [DictationRecord],
        days: Int = 14,
        now: Date = Date(),
        generate: ((_ system: String, _ user: String) async -> String?)? = nil
    ) async -> CoachReport {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = records.filter { $0.date >= cutoff }
        let texts = recent.map(\.text)
        let analysis = SpeechAnalysis.analyze(texts: texts)
        let stats = DashboardStats.compute(records: recent, now: now)

        var focus: [Focus] = []
        var observations: [String] = []
        let czech = looksCzech(texts)

        if analysis.fillerRate >= 4 {
            focus.append(.fillers)
            let list = analysis.topFillers.prefix(3).map { "„\($0.word)“ ×\($0.count)" }.joined(separator: ", ")
            observations.append(czech
                ? "Vata tvoří \(fmt(analysis.fillerRate)) % slov — nejčastěji \(list). Zkus místo výplně udělat pauzu; ticho zní jistěji než „ehm“."
                : "Fillers make up \(fmt(analysis.fillerRate))% of your words — mostly \(list). Try a pause instead; silence sounds more confident than \"um\".")
        } else if analysis.totalWords > 100 {
            observations.append(czech
                ? "Vaty máš málo (\(fmt(analysis.fillerRate)) %) — to je nadprůměrně čistý projev."
                : "Very few fillers (\(fmt(analysis.fillerRate))%) — that is a cleaner delivery than most.")
        }

        if analysis.averageSentenceLength >= 22 {
            focus.append(.concision); focus.append(.structure)
            observations.append(czech
                ? "Průměrná věta má \(fmt(analysis.averageSentenceLength)) slov, nejdelší \(analysis.longestSentenceWords). Dlouhá souvětí posluchač ztrácí — řekni závěr první, pak důvody."
                : "Your average sentence runs \(fmt(analysis.averageSentenceLength)) words, the longest \(analysis.longestSentenceWords). Long chains lose listeners — lead with the conclusion, then the reasons.")
        } else if analysis.averageSentenceLength > 0, analysis.averageSentenceLength < 7 {
            focus.append(.structure)
            observations.append(czech
                ? "Věty jsou velmi krátké (∅ \(fmt(analysis.averageSentenceLength)) slov). Zkus je občas spojit důvodem — „protože“, „takže“ — ať myšlenka drží pohromadě."
                : "Sentences are very short (avg \(fmt(analysis.averageSentenceLength)) words). Try linking them with a reason — \"because\", \"so\" — so the thought holds together.")
        }

        if analysis.vocabularyRichness > 0, analysis.vocabularyRichness < 0.35, analysis.totalWords > 200 {
            focus.append(.clarity)
            observations.append(czech
                ? "Slovník se hodně opakuje (pestrost \(fmt(analysis.vocabularyRichness * 100)) %). Zkus jednou denně nahradit obvyklé slovo přesnějším."
                : "Your vocabulary repeats a lot (richness \(fmt(analysis.vocabularyRichness * 100))%). Once a day, swap a usual word for a more precise one.")
        }

        if stats.averageWPM > 0 {
            if stats.averageWPM > 175 {
                focus.append(.delivery)
                observations.append(czech
                    ? "Mluvíš rychle (\(Int(stats.averageWPM)) slov/min). Pro srozumitelnost je ideál 130–160; zpomal na začátku vět."
                    : "You speak fast (\(Int(stats.averageWPM)) wpm). 130–160 is the sweet spot for clarity; slow down at the start of sentences.")
            } else if stats.averageWPM < 100 {
                focus.append(.delivery)
                observations.append(czech
                    ? "Tempo je pomalé (\(Int(stats.averageWPM)) slov/min) — často to znamená hledání slov. Připrav si první větu, než zmáčkneš klávesu."
                    : "Your pace is slow (\(Int(stats.averageWPM)) wpm) — usually a sign of searching for words. Have the first sentence ready before you press the key.")
            } else {
                observations.append(czech
                    ? "Tempo \(Int(stats.averageWPM)) slov/min je akorát — dobře se poslouchá."
                    : "\(Int(stats.averageWPM)) wpm is a comfortable pace — easy to follow.")
            }
        }

        if observations.isEmpty {
            observations.append(czech
                ? "Zatím málo dat — nadiktuj pár delších myšlenek a vrať se sem."
                : "Not enough data yet — dictate a few longer thoughts and come back.")
        }
        if focus.isEmpty { focus = [.structure, .storytelling] }

        // Books: those matching the strongest weaknesses first, then broaden.
        var picked: [CuratedBook] = []
        for f in focus {
            for book in library where book.focus.contains(f) && !picked.contains(where: { $0.title == book.title }) {
                picked.append(book)
                if picked.count == 3 { break }
            }
            if picked.count == 3 { break }
        }
        for book in library where picked.count < 3 && !picked.contains(where: { $0.title == book.title }) {
            picked.append(book)
        }

        var report = CoachReport(
            generatedAt: now, sampleSize: recent.count, periodDays: days, wordsAnalyzed: analysis.totalWords,
            fillerRate: analysis.fillerRate, topFillers: analysis.topFillers.map(\.word),
            averageSentenceLength: analysis.averageSentenceLength, vocabularyRichness: analysis.vocabularyRichness,
            averageWPM: stats.averageWPM, observations: observations, advice: nil,
            books: picked.map { .init(title: $0.title, author: $0.author, why: $0.why, czechEdition: $0.czech) }
        )

        if let generate, analysis.totalWords >= 60 {
            let samples = recent.suffix(12).map(\.text).joined(separator: "\n— ")
            let user = """
            Measurements over the last \(days) days (\(recent.count) dictations, \(analysis.totalWords) words):
            - filler words: \(fmt(analysis.fillerRate)) per 100 words (top: \(analysis.topFillers.prefix(4).map(\.word).joined(separator: ", ")))
            - average sentence length: \(fmt(analysis.averageSentenceLength)) words
            - vocabulary richness: \(fmt(analysis.vocabularyRichness * 100)) %
            - speaking pace: \(Int(stats.averageWPM)) words per minute

            Recent dictations, verbatim:
            — \(samples)
            """
            report.advice = await generate(LLMPrompts.coachSystem(czech: czech), user)
        }
        return report
    }

    static func looksCzech(_ texts: [String]) -> Bool {
        let joined = texts.joined(separator: " ").lowercased()
        let czechMarkers: Set<Character> = ["ě", "š", "č", "ř", "ž", "ý", "á", "í", "é", "ú", "ů"]
        let count = joined.filter { czechMarkers.contains($0) }.count
        return count > joined.count / 60
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
}
