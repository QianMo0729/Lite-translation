import Foundation

/// One thing to translate, with whatever is known about where the user saw it.
public struct TranslationRequest: Sendable {
    public enum Kind: Sendable {
        /// A word or short phrase: answer with a translation plus a one-line gloss.
        case term
        /// A sentence or more: answer with the translation only.
        case passage
    }

    public enum Target: Sendable {
        case simplifiedChinese
        case english

        var name: String {
            switch self {
            case .simplifiedChinese: "简体中文"
            case .english: "英文"
            }
        }
    }

    public var text: String
    public var appName: String?
    public var windowTitle: String?
    /// On-screen text near `text`. Empty when the screen couldn't be read.
    public var screenText: String
    /// The opening of the document being read. Empty when there is no readable document.
    public var documentOverview = ""
    /// Sentences elsewhere in the document that use `text`.
    public var documentMentions: [String] = []
    public let kind: Kind
    public let target: Target

    public init(text: String, appName: String? = nil, windowTitle: String? = nil, screenText: String = "") {
        self.text = text
        self.appName = appName
        self.windowTitle = windowTitle
        self.screenText = screenText

        let hanCount = text.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let mostlyChinese = hanCount * 10 > text.count * 3
        target = mostlyChinese ? .english : .simplifiedChinese
        if mostlyChinese {
            kind = text.count <= 8 ? .term : .passage
        } else {
            kind = text.count <= 48 && text.split(whereSeparator: \.isWhitespace).count <= 4 ? .term : .passage
        }
    }

    /// How much on-screen text to send along. A long passage carries most of its own context.
    public var contextBudget: Int {
        max(400, 1200 - text.promptCost)
    }

    var hasContext: Bool {
        !screenText.isEmpty || !documentOverview.isEmpty
    }

    var maximumResponseTokens: Int {
        switch kind {
        case .term: 160
        case .passage: min(2000, max(200, text.count * 2))
        }
    }
}

/// A translation backend. The app talks only to this, so the on-device model can be swapped
/// for a local server or a cloud model without touching the rest.
public protocol Translator: Sendable {
    /// Yields the whole answer generated so far each time more of it arrives.
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
    /// Gets the model into memory ahead of a request that is about to come.
    func prewarm()
}

/// A failure worth showing to the user as-is.
public struct TranslationFailure: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// The wording sent to the model, shared by every backend.
public enum TranslationPrompt {
    public static func instructions(for request: TranslationRequest) -> String {
        let hasContext = request.hasContext
        let target = request.target.name
        switch request.kind {
        case .term where hasContext:
            // The worked example does more than the rules to keep a small model on format.
            return """
            你是翻译助手。用户正在电脑上阅读，遇到一个不懂的词或短语。你会收到这个词，以及它周围的屏幕文字，有时还有所在文档的开头和这个词在文档别处的用法。这些材料只用来判断语境，不要翻译这些材料。

            输出恰好两行，不要输出其他内容：
            第一行：这个词在此处语境下的\(target)译法。如果它在这里是比喻、引申或专业用法，给出符合此处意思的说法，不要照搬字典里的第一个意思。只翻译这个词本身，不要连同它前后的词一起翻译，不超过十个字。
            第二行：用一句简体中文（不超过四十个字）说明它在这里指什么。

            示例
            词：bank
            屏幕文字：We walked along the bank of the river until sunset.
            输出：
            河岸
            这里指河流边上的陆地，不是银行。
            """
        case .term:
            return """
            你是翻译助手。用户会给你一个词或短语。

            输出恰好两行，不要输出其他内容：
            第一行：最常用的\(target)译法，只写译法本身，不超过十个字。
            第二行：用一句简体中文（不超过四十个字）说明它的意思。
            """
        case .passage where hasContext:
            return """
            你是翻译助手。用户正在电脑上阅读，会给你一段要翻译的话，以及它周围的屏幕文字，有时还有所在文档的开头。这些材料只用来判断领域和语境，不要翻译这些材料。
            把要翻译的那段话译成\(target)，术语的译法要符合所在领域。只输出译文，不要解释，不要重复原文。
            """
        case .passage:
            return "你是翻译助手。把用户给你的话译成\(target)。只输出译文，不要解释，不要重复原文。"
        }
    }

    public static func message(for request: TranslationRequest) -> String {
        let label = request.kind == .term ? "词" : "要翻译的话"
        guard request.hasContext else { return "\(label)：\(request.text)" }

        var parts = ["\(label)：\(request.text)"]
        if let appName = request.appName { parts.append("所在应用：\(appName)") }
        if let title = request.windowTitle, !title.isEmpty { parts.append("窗口标题：\(title)") }
        if !request.documentOverview.isEmpty { parts.append("文档开头：\n\(request.documentOverview)") }
        if !request.documentMentions.isEmpty {
            parts.append("这个词在文档别处的用法：\n" + request.documentMentions.map { "· \($0)" }.joined(separator: "\n"))
        }
        if !request.screenText.isEmpty { parts.append("屏幕文字：\n\(request.screenText)") }
        // Repeated after the context: with the request only at the top, the model tends to
        // start translating the context instead.
        parts.append(request.kind == .term
            ? "输出「\(request.text)」在上面语境中的译法和说明："
            : "只翻译这段话：\(request.text)")
        return parts.joined(separator: "\n")
    }
}
