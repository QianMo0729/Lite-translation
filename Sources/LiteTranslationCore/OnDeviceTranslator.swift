import Foundation
import FoundationModels

/// Translates with the language model that ships with macOS as part of Apple Intelligence.
/// Nothing leaves the machine.
public final class OnDeviceTranslator: Translator, @unchecked Sendable {
    private let lock = NSLock()
    // Kept alive so the load that prewarm() starts isn't abandoned with the session.
    private var warmSession: LanguageModelSession?

    public init() {}

    /// Why the model can't be used right now, or nil when it can.
    public static var unavailableMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "这台 Mac 不支持 Apple 智能，无法使用本机模型。"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple 智能没有开启，请在系统设置里打开后再试。"
        case .unavailable(.modelNotReady):
            return "本机模型还没准备好（可能正在下载），请稍后再试。"
        case .unavailable:
            return "本机模型暂时不可用。"
        }
    }

    public func prewarm() {
        guard Self.unavailableMessage == nil else { return }
        let session = LanguageModelSession()
        session.prewarm()
        lock.withLock { warmSession = session }
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // A fresh session per request: translations shouldn't see each other.
                    let session = LanguageModelSession(instructions: TranslationPrompt.instructions(for: request))
                    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maximumResponseTokens)
                    for try await snapshot in session.streamResponse(to: TranslationPrompt.message(for: request), options: options) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.failure(for: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func failure(for error: Error) -> Error {
        guard let error = error as? LanguageModelSession.GenerationError else { return error }
        switch error {
        case .exceededContextWindowSize:
            return TranslationFailure("内容太长，本机模型一次处理不了，请少选一些。")
        case .guardrailViolation, .refusal:
            return TranslationFailure("本机模型拒绝处理这段内容。")
        case .unsupportedLanguageOrLocale:
            return TranslationFailure("本机模型不支持这种语言。")
        case .assetsUnavailable:
            return TranslationFailure("本机模型还没准备好（可能正在下载），请稍后再试。")
        case .rateLimited, .concurrentRequests:
            return TranslationFailure("本机模型正忙，请稍后再试。")
        default:
            return TranslationFailure(error.localizedDescription)
        }
    }
}
