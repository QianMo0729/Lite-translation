import AppKit
import Carbon.HIToolbox
import LiteTranslationCore

/// Runs a translation from trigger to answer: read the selection or typed text, read the
/// screen and the open document for context, ask the model, and keep the panel up to date.
@MainActor
final class TranslationCoordinator {
    private let translator: any Translator = OnDeviceTranslator()
    private let model = PanelModel()
    private let panel: TranslationPanelController
    private let library = DocumentLibrary()
    // Both start the moment a shortcut is pressed, so they overlap with reading the selection
    // or with typing.
    private var contextTask: Task<CapturedContext, Never>?
    private var documentTask: Task<LoadedDocument?, Never>?
    private var work: Task<Void, Never>?
    private var recognizerWarmUp: Task<Void, Never>?

    init() {
        panel = TranslationPanelController(model: model)
        model.onSubmit = { [weak self] text in
            guard let self else { return }
            work?.cancel()
            work = Task { await self.translate(text, started: Date()) }
        }
        model.onClose = { [weak self] in
            self?.panel.hide()
            self?.work?.cancel()
        }
        panel.onDismiss = { [weak self] in self?.work?.cancel() }
    }

    func warmUp() {
        translator.prewarm()
        recognizerWarmUp = Task.detached { await ScreenTextRecognizer.warmUp() }
    }

    /// The macOS build on which a real window has been read all the way through. Until that
    /// has happened once, the system is still compiling its recognition models for this app
    /// and reading the screen takes the better part of a minute instead of a fraction of a second.
    private var recognitionPreparedBuild: String? {
        get { UserDefaults.standard.string(forKey: "recognitionPreparedBuild") }
        set { UserDefaults.standard.set(newValue, forKey: "recognitionPreparedBuild") }
    }

    /// Translates whatever is selected in the front app, in a panel next to the pointer.
    func translateSelection() {
        let started = Date()
        let pointer = NSEvent.mouseLocation
        // If the panel is still up from last time it holds keyboard focus; hand it back to the
        // app whose selection is about to be read.
        panel.hide()
        work?.cancel()
        translator.prewarm()
        beginReadingContext(pointer: pointer)

        work = Task {
            guard Permissions.accessibility else {
                model.reset(query: "")
                model.fail("需要“辅助功能”权限才能读取选中的文字。", action: .init(title: "打开系统设置") {
                    Permissions.openAccessibilitySettings()
                })
                panel.show(.nearPointer(pointer), focusQuery: false)
                return
            }
            let selection = await SelectionReader.read()
            guard !Task.isCancelled else { return }
            model.reset(query: selection ?? "")
            panel.show(.nearPointer(pointer), focusQuery: selection == nil)
            guard let selection else {
                model.fail("没有读到选中的文字。先选中要翻译的内容，或者直接在上面输入。")
                model.focusRequests += 1
                return
            }
            await translate(selection, started: started)
        }
    }

    /// Opens the panel empty, ready for a word to be typed.
    func openInput() {
        work?.cancel()
        translator.prewarm()
        beginReadingContext(pointer: NSEvent.mouseLocation)
        model.reset(query: "")
        panel.show(.upperMiddle, focusQuery: true)
        model.focusRequests += 1
    }

    private func beginReadingContext(pointer: NSPoint) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            contextTask = nil
            documentTask = nil
            return
        }
        let pid = app.processIdentifier
        let appName = app.localizedName
        // AppKit measures from the bottom left of the primary display; window frames from its top left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: pointer.x, y: primaryHeight - pointer.y)
        let capture = Task.detached {
            await ContextCapture.capture(pid: pid, appName: appName, pointer: flipped)
        }
        contextTask = capture
        Task {
            // Runs to the end even when the translation gave up waiting for it.
            if await capture.value.context != nil {
                recognitionPreparedBuild = ProcessInfo.processInfo.operatingSystemVersionString
            }
        }
        documentTask = Task.detached { [library] in
            let start = Date()
            guard let url = FrontDocument.url(pid: pid), let text = await library.text(for: url) else { return nil }
            return LoadedDocument(text: text, milliseconds: milliseconds(since: start))
        }
    }

    private func translate(_ text: String, started: Date) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let reason = OnDeviceTranslator.unavailableMessage {
            model.fail(reason)
            return
        }

        model.begin("正在读取屏幕…")
        // Context makes the answer better but isn't worth a long wait.
        let deadline = ContinuousClock.now + .milliseconds(1500)
        let captured = if let contextTask {
            await value(of: contextTask, by: deadline)
        } else {
            CapturedContext(outcome: .noWindow)
        }
        let document = if let documentTask { await value(of: documentTask, by: deadline) ?? nil } else { LoadedDocument?.none }
        guard !Task.isCancelled else { return }

        var request = TranslationRequest(text: query)
        if let context = captured?.context {
            request.appName = context.appName
            request.windowTitle = context.windowTitle
            request.screenText = context.excerpt(around: query, budget: request.contextBudget)
        }
        if let document {
            let screenText = request.screenText
            let isTerm = request.kind == .term
            // Searching a long document shouldn't hold up the interface.
            (request.documentOverview, request.documentMentions) = await Task.detached {
                (document.text.overview(notIn: screenText), isTerm ? document.text.mentions(of: query, notIn: screenText) : [])
            }.value
        }
        model.begin("正在翻译…")
        describeContext(captured, screenUsed: !request.screenText.isEmpty, documentUsed: document != nil)

        let modelStart = Date()
        var firstToken: Int?
        do {
            for try await partial in translator.translate(request) {
                if firstToken == nil { firstToken = milliseconds(since: modelStart) }
                model.show(partial: partial, kind: request.kind)
            }
        } catch {
            if !Task.isCancelled { model.fail(error.localizedDescription) }
            return
        }
        guard !Task.isCancelled else { return }

        model.phase = .done
        model.timingNote = String(format: "%.1f 秒", Date().timeIntervalSince(started))
        var stages: [String] = []
        if let captured, captured.context != nil {
            stages.append("截图 \(captured.captureMilliseconds) ms")
            stages.append("识别文字 \(captured.recognitionMilliseconds) ms")
        }
        if let document { stages.append("读取文档 \(document.milliseconds) ms") }
        stages.append("模型首字 \(firstToken ?? 0) ms")
        stages.append("模型完成 \(milliseconds(since: modelStart)) ms")
        model.timingDetail = stages.joined(separator: " · ")
    }

    /// The task's value if it arrives before `deadline`, nil if it doesn't.
    private func value<Value: Sendable>(of task: Task<Value, Never>, by deadline: ContinuousClock.Instant) async -> Value? {
        await withCheckedContinuation { continuation in
            var resumed = false
            Task { @MainActor in
                let value = await task.value
                if !resumed { resumed = true; continuation.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(until: deadline)
                // Let a value that is already there win over a deadline that has already passed.
                await Task.yield()
                if !resumed { resumed = true; continuation.resume(returning: nil) }
            }
        }
    }

    private func describeContext(_ captured: CapturedContext?, screenUsed: Bool, documentUsed: Bool) {
        model.contextUsed = screenUsed || documentUsed
        var note: String
        switch captured?.outcome {
        case .captured where screenUsed:
            let window = "「\(captured?.context?.appName ?? "当前窗口")」窗口里的文字"
            model.contextNote = documentUsed ? "已参考\(window)和文档全文" : "已参考\(window)"
            return
        case .captured, .noText:
            note = "窗口里没有识别到文字"
        case .noPermission:
            note = "未授权屏幕录制，没有参考屏幕内容"
            model.contextAction = .init(title: "去设置") { Permissions.openScreenRecordingSettings() }
        case .noWindow:
            note = "没有找到可以读取的窗口"
        case nil:
            note = recognitionPreparedBuild == ProcessInfo.processInfo.operatingSystemVersionString
                ? "读取屏幕超时，没有参考屏幕内容"
                : "文字识别在系统更新后需要准备约一分钟，这次没有参考屏幕内容"
        }
        if documentUsed { note = "已参考文档全文；" + note }
        model.contextNote = note
    }

    /// Development hook: opens the input panel, fills in `query`, presses Return and then
    /// Escape as a user would, prints what happened, optionally saves a picture of the panel,
    /// and quits. Files can stand in for the live window capture and for the open document.
    func runDebugQuery(_ query: String, screenshotPath: String?, documentPath: String?, snapshotPath: String?) {
        openInput()
        if let screenshotPath,
           let image = NSImage(contentsOfFile: screenshotPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            contextTask = Task.detached {
                await ContextCapture.recognise(image, appName: "Preview", windowTitle: nil, pointer: nil)
            }
        }
        if let documentPath {
            documentTask = Task.detached { [library] in
                let start = Date()
                guard let text = await library.text(for: URL(fileURLWithPath: documentPath)) else { return nil }
                return LoadedDocument(text: text, milliseconds: milliseconds(since: start))
            }
        }
        Task {
            if let preview = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview").first {
                print("document in Preview's front window: \(FrontDocument.url(pid: preview.processIdentifier)?.path ?? "not readable")")
            }
            await recognizerWarmUp?.value
            model.query = query
            try? await Task.sleep(for: .milliseconds(300))
            panel.sendKey(code: kVK_Return, characters: "\r")

            var waited = 0
            while model.phase != .done, !model.phase.isFailure, waited < 300 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            try? await Task.sleep(for: .milliseconds(400))
            if let snapshotPath { panel.writeSnapshot(to: snapshotPath) }
            print("phase: \(model.phase)")
            print("headline: \(model.headline)")
            print("detail: \(model.detail)")
            print("context: \(model.contextNote)")
            print("timing: \(model.timingNote) (\(model.timingDetail))")
            if let captured = await contextTask?.value {
                print("screen reading finished as \(captured.outcome) after \(captured.captureMilliseconds + captured.recognitionMilliseconds) ms")
            }

            panel.sendKey(code: kVK_Escape, characters: "\u{1B}")
            try? await Task.sleep(for: .milliseconds(200))
            print("closed by Escape: \(!panel.isVisible)")
            NSApp.terminate(nil)
        }
    }
}
