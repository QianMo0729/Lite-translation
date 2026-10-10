import Foundation
import PDFKit

/// The full text of the document the user has open. The screen only shows one page of it;
/// this supplies what the document is about and how it uses a term elsewhere.
public struct DocumentText: Sendable {
    /// One entry per page, with line breaks and end-of-line hyphenation removed.
    public var pages: [String]

    public init(pages: [String]) {
        self.pages = pages
    }

    /// Reads a PDF's text layer. Nil for scanned PDFs and for files that aren't PDFs.
    public init?(pdfAt url: URL) {
        guard let document = PDFDocument(url: url) else { return nil }
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string?.flattened ?? "" }
        guard pages.contains(where: { !$0.isEmpty }) else { return nil }
        self.pages = pages
    }

    /// What the document is about: its opening lines, and its abstract when it has one.
    public func overview(budget: Int = 400) -> String {
        var opening = ""
        for page in pages where opening.count < 2500 {
            opening += page + " "
        }
        opening = String(opening.prefix(2500))
        guard let abstract = opening.firstRange(of: #/\babstract\b/#.ignoresCase()) else {
            return opening.truncated(to: budget)
        }
        let title = String(opening[..<abstract.lowerBound]).truncated(to: budget / 4)
        let body = String(opening[abstract.upperBound...])
            .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            .truncated(to: budget - title.count)
        return title.isEmpty ? body : "\(title) \(body)"
    }

    /// The overview, or nothing when the reader already has the document's opening in front of them.
    public func overview(notIn screenText: String) -> String {
        let text = overview()
        let sample = String(text.matchKey.dropFirst(text.count / 2).prefix(30))
        return !sample.isEmpty && screenText.matchKey.contains(sample) ? "" : text
    }

    /// The earliest sentences in the document that use `term`, which is usually where it is
    /// introduced or defined. Empty when that introduction is already in `screenText`: the
    /// reader is looking at it, and later uses only pull the translation away from this one.
    public func mentions(of term: String, notIn screenText: String, limit: Int = 2) -> [String] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 3 else { return [] }
        let screenKey = screenText.matchKey
        var found: [String] = []
        for page in pages {
            var remainder = page.startIndex..<page.endIndex
            while let match = page.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: remainder) {
                remainder = match.upperBound..<page.endIndex
                guard page.isWholeWord(match) else { continue }
                // A few words either side of the match identify this particular use.
                let vicinity = page.window(around: match, radius: 14).matchKey
                if screenKey.contains(vicinity) { return found }
                let sentence = page.sentence(around: match)
                if found.contains(sentence) { continue }
                found.append(sentence)
                if found.count == limit { return found }
            }
        }
        return found
    }
}

extension String {
    /// PDF text comes with a line break at the end of every printed line.
    var flattened: String {
        replacing(#/(\p{L})-\n(\p{Ll})/#) { "\($0.output.1)\($0.output.2)" }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func truncated(to limit: Int) -> String {
        guard count > limit, limit > 0 else { return limit > 0 ? self : "" }
        let cut = prefix(limit)
        let lastSpace = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return cut[..<lastSpace] + "…"
    }

    func isWholeWord(_ range: Range<String.Index>) -> Bool {
        // Only meaningful for scripts that put spaces between words.
        guard self[range].allSatisfy(\.isASCII) else { return true }
        let before = range.lowerBound > startIndex ? self[index(before: range.lowerBound)] : " "
        let after = range.upperBound < endIndex ? self[range.upperBound] : " "
        return !before.isLetter && !after.isLetter
    }

    func window(around range: Range<String.Index>, radius: Int) -> String {
        let lower = index(range.lowerBound, offsetBy: -radius, limitedBy: startIndex) ?? startIndex
        let upper = index(range.upperBound, offsetBy: radius, limitedBy: endIndex) ?? endIndex
        return String(self[lower..<upper])
    }

    /// The sentence containing `range`, or about 160 characters either side when its ends can't be found.
    func sentence(around range: Range<String.Index>, reach: Int = 160) -> String {
        let closers: Set<Character> = [".", "?", "!"]
        let wideClosers: Set<Character> = ["。", "？", "！"]

        var start = range.lowerBound
        var steps = 0
        while start > startIndex, steps < reach {
            let previous = index(before: start)
            if wideClosers.contains(self[previous]) { break }
            if self[previous].isWhitespace, previous > startIndex, closers.contains(self[index(before: previous)]) { break }
            start = previous
            steps += 1
        }

        var end = range.upperBound
        steps = 0
        while end < endIndex, steps < reach {
            let character = self[end]
            end = index(after: end)
            steps += 1
            if wideClosers.contains(character) { break }
            if closers.contains(character), end == endIndex || self[end].isWhitespace { break }
        }
        return self[start..<end].trimmingCharacters(in: .whitespaces)
    }
}
