import Foundation
import LiteTranslationCore
import Observation

/// Everything the translation panel shows.
@MainActor
@Observable
final class PanelModel {
    enum Phase: Equatable {
        case idle
        case working(String)
        case answering
        case done
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    struct Action {
        var title: String
        var run: () -> Void
    }

    var query = ""
    var phase: Phase = .idle
    /// The translation of a word or phrase, shown large.
    var headline = ""
    /// The gloss under a headline, or the whole translation of a passage.
    var detail = ""
    /// What on-screen context the answer drew on.
    var contextNote = ""
    var contextUsed = false
    var contextAction: Action?
    var failureAction: Action?
    var timingNote = ""
    var timingDetail = ""
    /// Bumped to move keyboard focus into the query field.
    var focusRequests = 0

    @ObservationIgnored var onSubmit: (String) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onHeightChange: (CGFloat) -> Void = { _ in }

    func reset(query: String) {
        self.query = query
        phase = .idle
        clearAnswer()
    }

    func begin(_ status: String) {
        clearAnswer()
        phase = .working(status)
    }

    func show(partial text: String, kind: TranslationRequest.Kind) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch kind {
        case .term:
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            headline = lines.first.map(Self.tidy) ?? ""
            detail = lines.count > 1 ? Self.tidy(lines[1]) : ""
        case .passage:
            headline = ""
            detail = text
        }
        phase = .answering
    }

    func fail(_ message: String, action: Action? = nil) {
        clearAnswer()
        failureAction = action
        phase = .failed(message)
    }

    private func clearAnswer() {
        headline = ""
        detail = ""
        contextNote = ""
        contextUsed = false
        contextAction = nil
        failureAction = nil
        timingNote = ""
        timingDetail = ""
    }

    /// The model is asked for bare lines but sometimes labels them anyway.
    private static func tidy(_ line: Substring) -> String {
        line.replacing(#/^第[一二]行[:：]\s*/#, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
