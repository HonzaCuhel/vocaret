import AppKit

/// Pure sizing policy shared by the AppKit panel and its tests.
public enum RecorderHUDLayout {
    private static let transcriptWidth: CGFloat = 496
    private static let transcriptFont = NSFont.systemFont(ofSize: 17, weight: .medium)

    public static func panelSize(transcript: String) -> CGSize {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CGSize(width: 560, height: 72) }
        let lines = visibleLineCount(for: trimmed)
        return CGSize(width: 560, height: CGFloat(76 + 20 * lines))
    }

    static func visibleLineCount(for transcript: String) -> Int {
        let attributes: [NSAttributedString.Key: Any] = [.font: transcriptFont]
        let bounds = (transcript as NSString).boundingRect(
            with: CGSize(width: transcriptWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = transcriptFont.ascender - transcriptFont.descender + transcriptFont.leading
        return min(4, max(1, Int(ceil((bounds.height - 0.5) / lineHeight))))
    }
}
