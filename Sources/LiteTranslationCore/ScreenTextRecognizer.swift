import CoreGraphics
import CoreText
import Foundation
import Vision

/// On-device OCR that keeps document structure, so multi-column pages come back as paragraphs
/// in reading order rather than as lines interleaved across columns.
public enum ScreenTextRecognizer {
    public static func paragraphs(in image: CGImage) async throws -> [ScreenParagraph] {
        let request = RecognizeDocumentsRequest()
        let size = CGSize(width: image.width, height: image.height)
        return try await request.perform(on: image).flatMap { observation in
            observation.document.paragraphs.map { paragraph in
                ScreenParagraph(
                    text: paragraph.transcript.rejoiningHyphenatedWords,
                    rect: paragraph.boundingRegion.boundingBox.toImageCoordinates(size, origin: .upperLeft),
                    lines: paragraph.lines.map {
                        ScreenLine(text: $0.transcript, rect: $0.boundingRegion.boundingBox.toImageCoordinates(size, origin: .upperLeft))
                    }
                )
            }
        }
    }

    /// Loads the recognition models, so the first real request isn't the one that waits for them.
    ///
    /// After a macOS update the system also has to compile these models once per app, which
    /// takes most of a minute in total. This gets a little over half of that done; the rest
    /// only happens on a real page, whatever is drawn here.
    public static func warmUp() async {
        guard let image = sampleImage() else { return }
        _ = try? await paragraphs(in: image)
    }

    private static func sampleImage() -> CGImage? {
        let width = 1200
        let height = 400
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let sentence = "Warming up the text recognition models so that the first real request is fast. "
        let text = NSAttributedString(string: String(repeating: sentence, count: 6), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 26, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        let page = CGPath(rect: CGRect(x: 60, y: 40, width: width - 120, height: height - 80), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(), page, nil), context)
        return context.makeImage()
    }
}

extension String {
    /// "solu- tion" -> "solution". A hyphen followed by a space and a lowercase letter is a
    /// line-break hyphenation; real compounds like "well-known" have no space after the hyphen.
    var rejoiningHyphenatedWords: String {
        replacing(#/(\p{L})- (\p{Ll})/#) { "\($0.output.1)\($0.output.2)" }
    }
}
