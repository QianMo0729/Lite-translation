import CoreGraphics
import Foundation
import ImageIO
import LiteTranslationCore

// Runs the screenshot -> context -> translation pipeline on an image file and prints what
// each stage produced and how long it took.
//
//   swift run -c release PipelineProbe <image> <text to translate> [--pdf <document>] [--mentions <n>] [--warm-up]
//
// --pdf adds the document's full text, as the app does when the window shows a PDF file.
// --warm-up runs and times the app's launch-time warm-up before anything else.

func milliseconds(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
let pdfPath = option("--pdf")
if let index = arguments.firstIndex(of: "--warm-up") {
    // Times the app's launch-time warm-up on its own, before any real image is recognised.
    arguments.remove(at: index)
    let start = Date()
    await ScreenTextRecognizer.warmUp()
    print("warm-up: \(milliseconds(since: start)) ms")
}
let mentionLimit = option("--mentions").flatMap(Int.init) ?? 2

guard arguments.count >= 2 else {
    print("usage: PipelineProbe <image> <text to translate> [--pdf <document>] [--mentions <n>] [--warm-up]")
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[0]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("could not read image at \(arguments[0])")
    exit(1)
}
let query = arguments[1]

var paragraphs: [ScreenParagraph] = []
for pass in ["first", "second"] {
    let start = Date()
    paragraphs = try await ScreenTextRecognizer.paragraphs(in: image)
    print("recognition (\(pass) pass): \(milliseconds(since: start)) ms, \(paragraphs.count) paragraphs")
}

var request = TranslationRequest(text: query)
request.screenText = ScreenContext(paragraphs: paragraphs).excerpt(around: query, budget: request.contextBudget)

if let pdfPath {
    let start = Date()
    guard let document = DocumentText(pdfAt: URL(fileURLWithPath: pdfPath)) else {
        print("no readable text in \(pdfPath)")
        exit(1)
    }
    request.documentOverview = document.overview()
    if request.kind == .term, mentionLimit > 0 {
        request.documentMentions = document.mentions(of: query, notIn: request.screenText, limit: mentionLimit)
    }
    print("document: \(document.pages.count) pages read in \(milliseconds(since: start)) ms")
}

print("\n--- message sent to the model (\(TranslationPrompt.message(for: request).count) chars) ---")
print(TranslationPrompt.message(for: request))

if let reason = OnDeviceTranslator.unavailableMessage {
    print("\nmodel unavailable: \(reason)")
    exit(1)
}

let translator = OnDeviceTranslator()
for pass in ["cold", "warm"] {
    let start = Date()
    var firstToken: Int?
    var answer = ""
    for try await partial in translator.translate(request) {
        if firstToken == nil { firstToken = milliseconds(since: start) }
        answer = partial
    }
    print("\n--- translation (\(pass)): first token \(firstToken ?? -1) ms, done \(milliseconds(since: start)) ms ---")
    print(answer)
}
