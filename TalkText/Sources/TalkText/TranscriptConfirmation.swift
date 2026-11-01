import Foundation

/// Tracks how much of a live draft the recognizer has settled on. A word is
/// confirmed once two consecutive full-context passes agree on it and on every
/// word before it. A later pass that changes a confirmed word moves the
/// boundary back to that word, so confirmation never claims text that changed.
struct TranscriptConfirmation: Equatable, Sendable {
    private var previousWords: [String] = []

    /// Characters of `text`, from the start, that two passes agree on. The
    /// boundary sits at the end of the last agreed word.
    mutating func update(with text: String) -> Int {
        let words = Self.words(in: text)
        defer { previousWords = words.map(\.normalized) }
        var agreed = 0
        while agreed < words.count, agreed < previousWords.count,
              words[agreed].normalized == previousWords[agreed] {
            agreed += 1
        }
        guard agreed > 0 else { return 0 }
        return text.distance(from: text.startIndex, to: words[agreed - 1].range.upperBound)
    }

    /// Case and surrounding punctuation often settle a pass later than the
    /// word itself ("Friday" then "Friday."), so they do not block agreement.
    private static func words(in text: String) -> [(normalized: String, range: Range<String.Index>)] {
        var words: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let wordStart = start { words.append(word(text, wordStart..<index)) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let wordStart = start { words.append(word(text, wordStart..<text.endIndex)) }
        return words
    }

    private static func word(_ text: String, _ range: Range<String.Index>) -> (String, Range<String.Index>) {
        let normalized = text[range]
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            .lowercased()
        return (normalized, range)
    }
}
