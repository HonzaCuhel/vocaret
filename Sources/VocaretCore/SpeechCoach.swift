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
        /// What the book is good for, in general.
        public var why: String
        /// Why it was picked for THIS user, from the measurements — or the
        /// LLM's one-liner. Nil = general recommendation.
        public var pickedBecause: String?
        public var url: String
        public var czechEdition: String?
        public var czechURL: String?
    }
}

public enum SpeechCoach {
    /// What a book helps with, so we can match books to measured weaknesses.
    enum Focus { case fillers, structure, clarity, delivery, storytelling, concision }

    struct CuratedBook {
        let title: String
        let author: String
        let url: String
        let czech: String?
        let czechURL: String?
        let focus: [Focus]
        let why: String
    }

    /// Real, in-print books. Czech editions listed where they exist.
    static let library: [CuratedBook] = [
        .init(title: "How to Speak (MIT lecture)", author: "Patrick Winston",
              url: "https://ocw.mit.edu/courses/res-tll-005-how-to-speak-january-iap-2018/",
              czech: nil, czechURL: nil, focus: [.structure, .delivery],
              why: "One free hour that fixes how you open, structure and close a talk. Watch it before reading anything."),
        .init(title: "The Pyramid Principle", author: "Barbara Minto",
              url: "https://www.barbaraminto.com/",
              czech: nil, czechURL: nil, focus: [.structure, .concision],
              why: "Say the conclusion first, then support it. The single best cure for rambling."),
        .init(title: "On Writing Well", author: "William Zinsser",
              url: "https://openlibrary.org/works/OL2718017W",
              czech: nil, czechURL: nil, focus: [.clarity, .concision],
              why: "About writing, but every chapter is about cutting clutter — which is exactly what filler words are."),
        .init(title: "The Sense of Style", author: "Steven Pinker",
              url: "https://stevenpinker.com/publications/sense-style-thinking-persons-guide-writing-21st-century",
              czech: nil, czechURL: nil, focus: [.clarity],
              why: "Why smart people are unclear (the curse of knowledge) and how to explain things the listener can follow."),
        .init(title: "TED Talks: The Official TED Guide to Public Speaking", author: "Chris Anderson",
              url: "https://www.ted.com/read/ted-talks-the-official-ted-guide-to-public-speaking",
              czech: "TED Talks: Průvodce veřejným vystupováním (Jan Melvil)",
              czechURL: "https://www.databazeknih.cz/search?q=TED+Talks+Anderson",
              focus: [.delivery, .storytelling],
              why: "How to build one idea worth sharing and deliver it without notes."),
        .init(title: "Talk Like TED", author: "Carmine Gallo",
              url: "https://www.goodreads.com/search?q=talk+like+ted+carmine+gallo",
              czech: "Mluvte jako na TEDu (Grada)",
              czechURL: "https://www.grada.cz/vyhledavani/?q=Mluvte+jako+na+TEDu",
              focus: [.storytelling, .delivery],
              why: "Nine habits of the most-watched talks, with drills you can do in a week."),
        .init(title: "Moderní rétorika", author: "Alena Špačková",
              url: "https://www.grada.cz/moderni-retorika-11453/",
              czech: "Moderní rétorika (Grada)", czechURL: "https://www.grada.cz/moderni-retorika-11453/",
              focus: [.delivery, .fillers],
              why: "Czech-language rhetoric handbook: breath, tempo, pauses instead of \"ehm\", and Czech-specific pitfalls."),
        .init(title: "Rétorika a řečová kultura", author: "Jiří Kraus",
              url: "https://karolinum.cz/knihy/kraus-retorika-a-recova-kultura-14953",
              czech: "Rétorika a řečová kultura (Karolinum)", czechURL: "https://karolinum.cz/knihy/kraus-retorika-a-recova-kultura-14953",
              focus: [.clarity, .structure],
              why: "The academic Czech text on speaking well — dense, but the chapters on argument structure repay the effort."),
        .init(title: "How to Be Heard", author: "Julian Treasure",
              url: "https://www.goodreads.com/search?q=how+to+be+heard+julian+treasure",
              czech: nil, czechURL: nil, focus: [.delivery, .fillers],
              why: "Voice, pace, pauses and the habits that make people stop listening. Practical exercises."),
        .init(title: "Nonviolent Communication", author: "Marshall Rosenberg",
              url: "https://www.goodreads.com/search?q=nonviolent+communication",
              czech: "Nenásilná komunikace (Portál)", czechURL: "https://www.databazeknih.cz/search?q=Nen%C3%A1siln%C3%A1+komunikace",
              focus: [.clarity],
              why: "Saying exactly what you observe, feel and need — a template for unambiguous sentences."),
        .init(title: "Made to Stick", author: "Chip & Dan Heath",
              url: "https://heathbrothers.com/books/made-to-stick/",
              czech: "Nápad za milion (Jan Melvil)", czechURL: "https://www.databazeknih.cz/search?q=N%C3%A1pad+za+milion",
              focus: [.storytelling, .concision],
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
        /// Human reason per focus, shown as "picked because …" under each book.
        var reasons: [Focus: String] = [:]
        var observations: [String] = []
        let czech = looksCzech(texts)
        func want(_ f: Focus, _ reason: String) { if !focus.contains(f) { focus.append(f) }; reasons[f] = reasons[f] ?? reason }

        if analysis.fillerRate >= 2 {
            want(.fillers, czech ? "vata \(fmt(analysis.fillerRate)) % slov" : "\(fmt(analysis.fillerRate))% filler words")
        }
        if analysis.fillerRate >= 4 {
            let list = analysis.topFillers.prefix(3).map { "„\($0.word)“ ×\($0.count)" }.joined(separator: ", ")
            observations.append(czech
                ? "Vata tvoří \(fmt(analysis.fillerRate)) % slov — nejčastěji \(list). Zkus místo výplně udělat pauzu; ticho zní jistěji než „ehm“."
                : "Fillers make up \(fmt(analysis.fillerRate))% of your words — mostly \(list). Try a pause instead; silence sounds more confident than \"um\".")
        } else if analysis.totalWords > 100 {
            observations.append(czech
                ? "Vaty máš málo (\(fmt(analysis.fillerRate)) %) — to je nadprůměrně čistý projev."
                : "Very few fillers (\(fmt(analysis.fillerRate))%) — that is a cleaner delivery than most.")
        }

        if analysis.averageSentenceLength >= 16 {
            want(.concision, czech ? "věty ∅ \(fmt(analysis.averageSentenceLength)) slov" : "sentences average \(fmt(analysis.averageSentenceLength)) words")
        }
        if analysis.averageSentenceLength >= 22 {
            want(.structure, czech ? "dlouhá souvětí (max \(analysis.longestSentenceWords) slov)" : "long chains (up to \(analysis.longestSentenceWords) words)")
            observations.append(czech
                ? "Průměrná věta má \(fmt(analysis.averageSentenceLength)) slov, nejdelší \(analysis.longestSentenceWords). Dlouhá souvětí posluchač ztrácí — řekni závěr první, pak důvody."
                : "Your average sentence runs \(fmt(analysis.averageSentenceLength)) words, the longest \(analysis.longestSentenceWords). Long chains lose listeners — lead with the conclusion, then the reasons.")
        } else if analysis.averageSentenceLength > 0, analysis.averageSentenceLength < 7 {
            want(.structure, czech ? "velmi krátké věty (∅ \(fmt(analysis.averageSentenceLength)))" : "very short sentences (avg \(fmt(analysis.averageSentenceLength)))")
            observations.append(czech
                ? "Věty jsou velmi krátké (∅ \(fmt(analysis.averageSentenceLength)) slov). Zkus je občas spojit důvodem — „protože“, „takže“ — ať myšlenka drží pohromadě."
                : "Sentences are very short (avg \(fmt(analysis.averageSentenceLength)) words). Try linking them with a reason — \"because\", \"so\" — so the thought holds together.")
        }

        if analysis.vocabularyRichness > 0, analysis.vocabularyRichness < 0.42, analysis.totalWords > 200 {
            want(.clarity, czech ? "pestrost slovníku \(fmt(analysis.vocabularyRichness * 100)) %" : "vocabulary richness \(fmt(analysis.vocabularyRichness * 100))%")
        }
        if analysis.vocabularyRichness > 0, analysis.vocabularyRichness < 0.35, analysis.totalWords > 200 {
            observations.append(czech
                ? "Slovník se hodně opakuje (pestrost \(fmt(analysis.vocabularyRichness * 100)) %). Zkus jednou denně nahradit obvyklé slovo přesnějším."
                : "Your vocabulary repeats a lot (richness \(fmt(analysis.vocabularyRichness * 100))%). Once a day, swap a usual word for a more precise one.")
        }

        if stats.averageWPM > 0 {
            if stats.averageWPM > 175 {
                want(.delivery, czech ? "tempo \(Int(stats.averageWPM)) slov/min" : "\(Int(stats.averageWPM)) wpm pace")
                observations.append(czech
                    ? "Mluvíš rychle (\(Int(stats.averageWPM)) slov/min). Pro srozumitelnost je ideál 130–160; zpomal na začátku vět."
                    : "You speak fast (\(Int(stats.averageWPM)) wpm). 130–160 is the sweet spot for clarity; slow down at the start of sentences.")
            } else if stats.averageWPM < 100 {
                want(.delivery, czech ? "pomalé tempo \(Int(stats.averageWPM)) slov/min" : "slow pace, \(Int(stats.averageWPM)) wpm")
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
        let generalPicks = focus.isEmpty
        if generalPicks { focus = [.structure, .storytelling, .clarity] }

        // Candidate books: those matching the strongest weaknesses first, in
        // the speaker's language first, then broaden.
        // Round-robin over the focuses so three picks cover three weaknesses
        // instead of the first weakness taking every slot; within a focus the
        // speaker's own language comes first.
        var perFocus: [[CuratedBook]] = focus.map { f in
            let matching = library.filter { $0.focus.contains(f) }
            return czech ? matching.sorted { ($0.czech != nil) && ($1.czech == nil) }
                         : matching.sorted { ($0.czech == nil) && ($1.czech != nil) }
        }
        var candidates: [CuratedBook] = []
        var progressed = true
        while progressed {
            progressed = false
            for i in perFocus.indices {
                while let next = perFocus[i].first {
                    perFocus[i].removeFirst()
                    if !candidates.contains(where: { $0.title == next.title }) {
                        candidates.append(next); progressed = true; break
                    }
                }
            }
        }
        for book in library where !candidates.contains(where: { $0.title == book.title }) { candidates.append(book) }

        func reasonFor(_ book: CuratedBook) -> String? {
            guard !generalPicks else { return nil }
            for f in focus where book.focus.contains(f) { if let r = reasons[f] { return r } }
            return nil
        }
        var picked: [CoachReport.Book] = candidates.prefix(3).map {
            .init(title: $0.title, author: $0.author, why: $0.why, pickedBecause: reasonFor($0),
                  url: $0.url, czechEdition: $0.czech, czechURL: $0.czechURL)
        }
        var report = CoachReport(
            generatedAt: now, sampleSize: recent.count, periodDays: days, wordsAnalyzed: analysis.totalWords,
            fillerRate: analysis.fillerRate, topFillers: analysis.topFillers.map(\.word),
            averageSentenceLength: analysis.averageSentenceLength, vocabularyRichness: analysis.vocabularyRichness,
            averageWPM: stats.averageWPM, observations: observations, advice: nil,
            books: picked
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

            // Let the model choose 3 of the top 6 candidates based on what the
            // person actually talks about — but only titles from the list.
            let shortlist = Array(candidates.prefix(6))
            let menu = shortlist.map { "- \($0.title) — \($0.author): \($0.why)" }.joined(separator: "\n")
            if let choice = await generate(LLMPrompts.coachBooksSystem(czech: czech),
                                           "\(user)\n\nBOOK LIST:\n\(menu)") {
                let chosen = parseBookChoice(choice, from: shortlist)
                if chosen.count >= 2 {
                    picked = chosen.map { entry in
                        let book = entry.book
                        return .init(title: book.title, author: book.author, why: book.why,
                                     pickedBecause: entry.reason ?? reasonFor(book),
                                     url: book.url, czechEdition: book.czech, czechURL: book.czechURL)
                    }
                    report.books = picked
                }
            }
        }
        return report
    }

    /// Parses "Title :: reason" lines; ignores anything not in the shortlist.
    static func parseBookChoice(_ text: String, from shortlist: [CuratedBook]) -> [(book: CuratedBook, reason: String?)] {
        var out: [(CuratedBook, String?)] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t"))
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "::")
            let titlePart = parts[0].lowercased()
            guard let book = shortlist.first(where: { titlePart.contains($0.title.lowercased().prefix(18)) }),
                  !out.contains(where: { $0.0.title == book.title }) else { continue }
            let reason = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            out.append((book, reason?.isEmpty == false ? reason : nil))
            if out.count == 3 { break }
        }
        return out
    }

    static func looksCzech(_ texts: [String]) -> Bool {
        let joined = texts.joined(separator: " ").lowercased()
        let czechMarkers: Set<Character> = ["ě", "š", "č", "ř", "ž", "ý", "á", "í", "é", "ú", "ů"]
        let count = joined.filter { czechMarkers.contains($0) }.count
        return count > joined.count / 60
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
}
