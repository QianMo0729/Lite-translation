import AppKit
import LiteTranslationCore
import ScreenCaptureKit

/// The result of trying to read the window the user is looking at.
struct CapturedContext: Sendable {
    enum Outcome: Sendable {
        case captured
        case noPermission
        case noWindow
        case noText
    }

    var outcome: Outcome
    var context: ScreenContext?
    var captureMilliseconds = 0
    var recognitionMilliseconds = 0
}

enum ContextCapture {
    /// Screenshots the front window of the app with this pid and recognises its text.
    /// `pointer` is in global display coordinates with a top-left origin.
    static func capture(pid: pid_t, appName: String?, pointer: CGPoint) async -> CapturedContext {
        guard Permissions.screenRecording else { return CapturedContext(outcome: .noPermission) }

        let captureStart = Date()
        guard let shot = await frontWindowShot(of: pid) else {
            return CapturedContext(outcome: .noWindow)
        }
        let captureMilliseconds = milliseconds(since: captureStart)

        return await recognise(
            shot.image, appName: appName, windowTitle: shot.title,
            pointer: CGPoint(
                x: (pointer.x - shot.frame.minX) * CGFloat(shot.image.width) / shot.frame.width,
                y: (pointer.y - shot.frame.minY) * CGFloat(shot.image.height) / shot.frame.height
            ),
            captureMilliseconds: captureMilliseconds
        )
    }

    static func recognise(
        _ image: CGImage, appName: String?, windowTitle: String?, pointer: CGPoint?, captureMilliseconds: Int = 0
    ) async -> CapturedContext {
        let start = Date()
        let paragraphs = (try? await ScreenTextRecognizer.paragraphs(in: image)) ?? []
        return CapturedContext(
            outcome: paragraphs.isEmpty ? .noText : .captured,
            context: ScreenContext(appName: appName, windowTitle: windowTitle, paragraphs: paragraphs, pointer: pointer),
            captureMilliseconds: captureMilliseconds,
            recognitionMilliseconds: milliseconds(since: start)
        )
    }

    private struct WindowShot {
        var image: CGImage
        var title: String?
        /// Global display coordinates, top-left origin, in points.
        var frame: CGRect
    }

    private static func frontWindowShot(of pid: pid_t) async -> WindowShot? {
        // CGWindowList is ordered front to back, which SCShareableContent doesn't promise.
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frontToBack = windowList
            .filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.frame.width > 120 && $0.frame.height > 80
        }
        let frontmost = frontToBack.lazy.compactMap { id in candidates.first { $0.windowID == id } }.first
        guard let window = frontmost ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        // Retina detail helps small text; beyond that, more pixels only slow recognition down.
        var scale = min(CGFloat(filter.pointPixelScale), 2)
        let longSide = max(filter.contentRect.width, filter.contentRect.height) * scale
        if longSide > 3200 { scale *= 3200 / longSide }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return WindowShot(image: image, title: window.title, frame: window.frame)
    }
}

func milliseconds(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}
