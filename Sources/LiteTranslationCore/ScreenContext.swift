import CoreGraphics
import Foundation

/// A line of text recognised on screen. Rects are in image pixels with a top-left origin.
public struct ScreenLine: Sendable {
    public var text: String
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

/// A paragraph of on-screen text.
public struct ScreenParagraph: Sendable {
    public var text: String
    public var rect: CGRect
    public var lines: [ScreenLine]

    public init(text: String, rect: CGRect, lines: [ScreenLine]) {
        self.text = text
        self.rect = rect
        self.lines = lines
    }
}

/// What was visible in the window the user was looking at when they asked for a translation.
public struct ScreenContext: Sendable {
    public var appName: String?
    public var windowTitle: String?
    /// In reading order, so neighbours in this array are neighbours in the text.
    public var paragraphs: [ScreenParagraph]
    /// Where the pointer was, in the same coordinate space as the paragraph rects.
    public var pointer: CGPoint?

    public init(appName: String? = nil, windowTitle: String? = nil, paragraphs: [ScreenParagraph], pointer: CGPoint? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.paragraphs = paragraphs
        self.pointer = pointer
    }
}

extension ScreenContext {
    /// The slice of on-screen text most likely to explain `query`: the paragraph it sits in,
    /// plus as many neighbouring paragraphs as fit in `budget`.
    public func excerpt(around query: String, budget: Int = 1200) -> String {
        guard let anchor = anchorIndex(for: query) else { return "" }
        var lower = anchor
        var upper = anchor
        var used = paragraphs[anchor].text.promptCost
        var preferEarlier = true
        while true {
            let earlier = lower > 0 ? paragraphs[lower - 1].text.promptCost : nil
            let later = upper < paragraphs.count - 1 ? paragraphs[upper + 1].text.promptCost : nil
            let earlierFits = earlier.map { used + $0 <= budget } ?? false
            let laterFits = later.map { used + $0 <= budget } ?? false
            if let earlier, earlierFits, preferEarlier || !laterFits {
                lower -= 1
                used += earlier
            } else if let later, laterFits {
                upper += 1
                used += later
            } else {
                break
            }
            preferEarlier.toggle()
        }
        let text = paragraphs[lower...upper].map(\.text).joined(separator: "\n")
        return used <= budget ? text : text.window(around: query, budget: budget)
    }

    /// The paragraph the user most likely means. A word often appears many times on a page, so
    /// among the paragraphs containing it we take the one nearest the pointer, which is normally
    /// resting on or next to what was just selected.
    func anchorIndex(for query: String) -> Int? {
        guard !paragraphs.isEmpty else { return nil }
        for needle in query.matchNeedles {
            var best: (index: Int, distance: CGFloat)?
            for (index, paragraph) in paragraphs.enumerated() where paragraph.text.matchKey.contains(needle) {
                let lineRects = paragraph.lines.filter { $0.text.matchKey.contains(needle) }.map(\.rect)
                let rects = lineRects.isEmpty ? [paragraph.rect] : lineRects
                let distance = rects.map { distanceFromPointer(to: $0) }.min() ?? 0
                if best.map({ distance < $0.distance }) ?? true {
                    best = (index, distance)
                }
            }
            if let best { return best.index }
        }
        // The query isn't on screen (typical for typed input): describe what the pointer is over.
        if pointer != nil {
            return paragraphs.indices.min { distanceFromPointer(to: paragraphs[$0].rect) < distanceFromPointer(to: paragraphs[$1].rect) }
        }
        return paragraphs.indices.max { paragraphs[$0].text.count < paragraphs[$1].text.count }
    }

    private func distanceFromPointer(to rect: CGRect) -> CGFloat {
        guard let pointer else { return 0 }
        let dx = max(rect.minX - pointer.x, 0, pointer.x - rect.maxX)
        let dy = max(rect.minY - pointer.y, 0, pointer.y - rect.maxY)
        return hypot(dx, dy)
    }
}

extension String {
    /// Rough prompt weight. CJK characters take about three times the tokens of Latin ones.
    var promptCost: Int {
        unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 3) }
    }

    /// Case-, accent- and whitespace-insensitive form used to find text in OCR output.
    var matchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// What to search for, most specific first. Long selections rarely survive OCR verbatim and
    /// may span paragraphs, so their two ends are tried as well.
    var matchNeedles: [String] {
        let key = matchKey
        guard key.count >= 2 else { return [] }
        guard key.count > 40 else { return [key] }
        return [key, String(key.suffix(24)), String(key.prefix(24))]
    }

    /// A stretch of this string worth about `budget`, centred on `query` when it occurs.
    func window(around query: String, budget: Int) -> String {
        let limit = max(1, count * budget / max(promptCost, 1))
        guard count > limit else { return self }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let centre = range(of: query, options: options).map { distance(from: startIndex, to: $0.lowerBound) } ?? 0
        let start = min(max(0, centre - limit / 2), count - limit)
        return String(dropFirst(start).prefix(limit))
    }
}
