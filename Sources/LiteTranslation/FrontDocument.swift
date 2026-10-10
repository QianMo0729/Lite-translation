import ApplicationServices
import Foundation
import LiteTranslationCore

/// The file shown in an app's front window.
enum FrontDocument {
    /// Where the file is, as the app reports it to Accessibility. Document-based apps such as
    /// Preview do report it; browsers and most other apps don't.
    static func url(pid: pid_t) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &document) == .success,
              let location = document as? String else { return nil }
        if location.hasPrefix("/") { return URL(fileURLWithPath: location) }
        guard let url = URL(string: location), url.isFileURL else { return nil }
        return url
    }
}

/// A document's text along with how long it took to get.
struct LoadedDocument: Sendable {
    var text: DocumentText
    var milliseconds: Int
}

/// Remembers the text of recently read documents, so only the first lookup in a file pays for
/// extracting it.
actor DocumentLibrary {
    private struct Entry {
        var modified: Date?
        var text: DocumentText?
    }

    private var entries: [URL: Entry] = [:]

    func text(for url: URL) -> DocumentText? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let entry = entries[url], entry.modified == modified { return entry.text }
        let text = url.pathExtension.lowercased() == "pdf" ? DocumentText(pdfAt: url) : nil
        if entries.count >= 8 { entries.removeAll() }
        entries[url] = Entry(modified: modified, text: text)
        return text
    }
}
