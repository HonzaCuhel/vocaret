import Foundation

/// Tiny localisation layer: English strings are the keys; Czech comes from the
/// table below. Add a language by adding a table. `L("Dashboard")`.
public enum L10n {
    /// Resolved UI language: "cs" or "en".
    public static var languageCode: String {
        switch SettingsStore.shared.uiLanguage {
        case "cs": return "cs"
        case "en": return "en"
        default:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("cs") ? "cs" : "en"
        }
    }

    public static func t(_ english: String) -> String {
        guard languageCode == "cs" else { return english }
        return cs[english] ?? english
    }

    /// Whisper language codes offered for auto-detection, with native names.
    public static let detectableLanguages: [(code: String, name: String)] = [
        ("cs", "Čeština"), ("en", "English"), ("sk", "Slovenčina"), ("de", "Deutsch"),
        ("pl", "Polski"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
        ("uk", "Українська"), ("ru", "Русский"), ("pt", "Português"), ("nl", "Nederlands"),
    ]

    static let cs: [String: String] = [
        // Sidebar / sections
        "Dashboard": "Přehled", "History": "Historie", "Meetings": "Schůzky", "Coach": "Kouč", "Settings": "Nastavení",
        "Whisper ready": "Whisper připraven", "Loading model…": "Načítám model…",
        "Accessibility granted": "Zpřístupnění povoleno", "Accessibility missing": "Chybí Zpřístupnění",
        "Local LLM installed": "Lokální LLM nainstalován", "LLM not set up": "LLM není nastaven",
        // Dashboard
        "Good morning": "Dobré ráno", "Good afternoon": "Dobré odpoledne", "Good evening": "Dobrý večer",
        "Words today": "Slova dnes", "Speaking pace": "Tempo řeči", "words per minute": "slov za minutu",
        "Time saved": "Ušetřený čas", "Streak": "Série", "day": "den", "days in a row": "dní v řadě",
        "Last 14 days": "Posledních 14 dní", "Peak dictation hours": "Kdy nejvíc diktuješ",
        "No dictated words in this period yet.": "V tomto období zatím nic nadiktováno.", "Nothing yet.": "Zatím nic.",
        "Recent transcripts": "Poslední přepisy", "See all": "Zobrazit vše", "Copy": "Kopírovat", "Copied": "Zkopírováno",
        "Your dictations will appear here.": "Tady se objeví tvoje diktáty.",
        // History
        "Search transcripts": "Hledat v přepisech", "Select a dictation": "Vyber diktát", "Copy last": "Kopírovat poslední",
        "Clear all history…": "Smazat celou historii…", "Delete": "Smazat", "words": "slov",
        // Meetings
        "Copy transcript": "Kopírovat přepis", "Show in Finder": "Zobrazit ve Finderu", "Open": "Otevřít",
        "No meeting selected": "Není vybraná schůzka", "Refresh": "Obnovit", "Open folder": "Otevřít složku",
        // Coach
        "Speaking coach": "Řečový kouč",
        "Reads your last two weeks of dictation — on this Mac only — and tells you what to work on.": "Přečte tvoje diktáty z posledních dvou týdnů — jen na tomto Macu — a řekne, na čem zapracovat.",
        "Analyze my speaking": "Analyzuj můj projev", "Analyze again": "Analyzovat znovu", "Analyzing…": "Analyzuji…",
        "What I noticed": "Čeho jsem si všiml", "Your coach says": "Kouč říká", "Worth reading": "Stojí za přečtení",
        "Filler words": "Vata", "Sentence length": "Délka věty", "Vocabulary": "Slovník", "Pace": "Tempo",
        "of all words": "ze všech slov", "words on average": "slov v průměru", "unique words": "unikátních slov",
        "Nothing to coach yet": "Zatím není co koučovat", "Dictate for a day or two, then come back.": "Diktuj den dva a vrať se.",
        "Picked for you from a curated list, based on the measurements above.": "Vybráno pro tebe z kurátorovaného seznamu podle měření výše.",
        "General picks — nothing in the measurements stood out yet. Dictate more and the list adapts.": "Obecné tipy — v měření zatím nic nevyčnívá. Diktuj víc a seznam se přizpůsobí.",
        // Settings
        "Shortcuts": "Zkratky", "Dictation": "Diktování", "Meeting": "Schůzka", "Change": "Změnit", "Cancel": "Zrušit", "Press a shortcut…": "Stiskni zkratku…",
        "Hold to talk (release inserts); a quick tap toggles": "Podrž a mluv (puštění vloží); krátký ťuk přepíná",
        "Changes to shortcuts apply after you restart Vocaret.": "Změny zkratek se projeví po restartu Vocaretu.",
        "Language": "Jazyk", "Transcribe": "Přepisovat", "Auto-detect": "Automaticky",
        "Auto-detect chooses between:": "Automatická detekce vybírá mezi:",
        "Speech model": "Model řeči", "Speech engine": "Rozpoznávač řeči",
        "Parakeet has no language control: it can drift to English on short or unclear Czech. Try it, compare, switch back if it misbehaves. Downloads ~500 MB on first use.": "Parakeet nemá řízení jazyka: u krátké nebo nezřetelné češtiny může sklouznout do angličtiny. Vyzkoušej, porovnej, případně přepni zpět. Při prvním použití stáhne ~500 MB.",
        "A new model downloads on next launch. Smaller models are much worse at Czech.": "Nový model se stáhne při příštím spuštění. Menší modely jsou v češtině výrazně horší.",
        "AI cleanup (local LLM)": "AI úprava (lokální LLM)", "Clean dictation with AI (adds ~1–2 s)": "Upravit diktát pomocí AI (přidá ~1–2 s)",
        "Structure meeting notes with AI": "Strukturovat poznámky ze schůzek pomocí AI",
        "llama-server installed": "llama-server nainstalován", "Not installed — run scripts/setup_llm.sh in the project folder": "Není nainstalován — spusť scripts/setup_llm.sh ve složce projektu",
        "One term per line. Vocaret always spells these your way, and the AI cleanup is told about them.": "Jeden výraz na řádek. Vocaret je vždy napíše po tvém a AI úprava o nich ví.",
        "Save vocabulary": "Uložit slovník", "corrections learned automatically": "oprav naučených automaticky",
        "Behaviour": "Chování", "Show the recording overlay": "Zobrazovat překryv při nahrávání",
        "Pause Spotify / Music while recording, resume after": "Pozastavit Spotify / Hudbu při nahrávání, poté obnovit",
        "Keep a history of dictations on this Mac": "Ukládat historii diktátů na tomto Macu",
        "Keep raw meeting audio after transcribing": "Ponechat surový zvuk schůzek po přepisu",
        "Keep the speech model loaded (faster, ~800 MB RAM)": "Držet model řeči načtený (rychlejší, ~800 MB RAM)",
        "Start Vocaret at login": "Spouštět Vocaret po přihlášení",
        "Appearance": "Vzhled", "Follow System": "Podle systému", "Light": "Světlý", "Dark": "Tmavý",
        "Interface language": "Jazyk rozhraní", "System": "Systémový",
        "Permissions": "Oprávnění",
        "Accessibility granted — text is typed at your cursor": "Zpřístupnění povoleno — text se píše na pozici kurzoru",
        "Accessibility missing — transcripts go to the clipboard": "Chybí Zpřístupnění — přepisy jdou do schránky", "Fix…": "Opravit…",
        "Open Microphone settings": "Otevřít nastavení mikrofonu", "Open System Audio Recording settings": "Otevřít nastavení nahrávání systémového zvuku",
        "Data": "Data", "Dictation history": "Historie diktátů", "Meeting transcripts": "Přepisy schůzek", "Models": "Modely",
        "Nothing here ever leaves this Mac. See PRIVACY.md for the exact details.": "Nic odsud neopouští tento Mac. Detaily v PRIVACY.md.",
        "Press *Analyze my speaking*. Measurements are computed locally; the personal note comes from the local LLM if it is set up.": "Stiskni *Analyzuj můj projev*. Měření se počítají lokálně; osobní poznámku napíše lokální LLM, pokud je nastaven.",
        // Menu
        "Open Vocaret…": "Otevřít Vocaret…", "⚠︎ Accessibility not granted — click to fix": "⚠︎ Zpřístupnění není povoleno — klikni pro opravu",
        "Start Dictation": "Spustit diktování", "Stop Dictation & Insert": "Ukončit diktování a vložit",
        "Start Meeting Transcription": "Spustit přepis schůzky", "Stop Meeting & Transcribe": "Ukončit schůzku a přepsat",
        "Cancel Recording": "Zrušit nahrávání", "Hold Hotkey to Talk (release inserts)": "Podržet zkratku a mluvit (puštění vloží)",
        "Show Recording Overlay": "Zobrazovat překryv při nahrávání", "Pause Music While Recording": "Pozastavit hudbu při nahrávání",
        "Clean Dictation with AI": "Upravovat diktát pomocí AI", "Structure Meetings with AI": "Strukturovat schůzky pomocí AI",
        "Keep Meeting Audio Files": "Ponechat zvukové soubory schůzek", "Start at Login": "Spouštět po přihlášení",
        "Add Word to Vocabulary…": "Přidat slovo do slovníku…", "Edit Vocabulary…": "Upravit slovník…",
        "Copy Last Dictation": "Kopírovat poslední diktát", "Open Dictation History": "Otevřít historii diktátů",
        "Open Meetings Folder": "Otevřít složku schůzek", "Check Permissions…": "Zkontrolovat oprávnění…", "Quit Vocaret": "Ukončit Vocaret",
        "Recording dictation…": "Nahrávám diktát…", "Transcribing dictation…": "Přepisuji diktát…",
        "Recording meeting…": "Nahrávám schůzku…", "Processing meeting…": "Zpracovávám schůzku…",
        // Main menu (⌘-shortcuts while the window is open)
        "Hide Vocaret": "Skrýt Vocaret", "Edit": "Úpravy", "Undo": "Zpět", "Redo": "Znovu", "Cut": "Vyjmout",
        "Paste": "Vložit", "Select All": "Vybrat vše", "Window": "Okno", "Close": "Zavřít", "Minimize": "Minimalizovat",
        // Confirmations + settings details
        "Delete all transcripts?": "Smazat všechny přepisy?", "Delete All": "Smazat vše",
        "This removes the dictation history files from this Mac. It cannot be undone.": "Smaže soubory s historií diktátů z tohoto Macu. Nelze vrátit zpět.",
        "Delete this transcript?": "Smazat tento přepis?",
        "It is removed from the history files on this Mac. It cannot be undone.": "Bude odstraněn ze souborů historie na tomto Macu. Nelze vrátit zpět.",
        "Custom: ": "Vlastní: ",
        "Available when running the built Vocaret.app (scripts/build_app.sh).": "Dostupné při spuštění sestavené Vocaret.app (scripts/build_app.sh).",
        "macOS is waiting for your approval in System Settings → General → Login Items.": "macOS čeká na tvé schválení v Nastavení systému → Obecné → Položky přihlášení.",
        "Open…": "Otevřít…",
        "is already the meeting shortcut — choose a different one.": "už je zkratka pro schůzky — zvol jinou.",
        "is already the dictation shortcut — choose a different one.": "už je zkratka pro diktování — zvol jinou.",
    ]
}

/// Shorthand used throughout the UI.
@inline(__always) public func L(_ english: String) -> String { L10n.t(english) }
