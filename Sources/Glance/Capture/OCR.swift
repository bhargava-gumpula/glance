import AppKit
import CoreGraphics
import Vision

/// On-device text recognition (Apple Vision). Nothing leaves the Mac here.
enum OCR {
    struct Line: Sendable {
        let text: String
        /// In image pixels, top-left origin.
        let box: CGRect
    }

    /// `languageCorrection: false` is faster; the memory recorder uses it (search text, not quotes).
    static func lines(in image: CGImage, languageCorrection: Bool = true) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        try VNImageRequestHandler(cgImage: image).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox // normalized, bottom-left origin
            return Line(text: text, box: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }

    /// The first Vision call after launch loads its models (~28 s once). Run one tiny OCR at launch so the
    /// first real question doesn't wait. Sometimes that first load fails and Vision returns nothing; it is retried
    /// once after 1 s. `first` describes the first attempt (its text or error) for the selftest and log.
    @discardableResult
    static func warmUp() -> (text: String, seconds: Double, first: String) {
        let start = Date()
        let w = 160, h = 48
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return ("", 0, "no context") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Glance", attributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 12, y: 8))
        NSGraphicsContext.current = nil
        guard let image = ctx.makeImage() else { return ("", 0, "no image") }
        func attempt() -> (text: String, note: String) {
            do {
                let text = try lines(in: image).map(\.text).joined(separator: " ")
                return (text, text.isEmpty ? "no text found" : "\"\(text)\"")
            } catch {
                log.error("OCR warm-up failed: \(error.localizedDescription, privacy: .public)")
                return ("", "error: \(error.localizedDescription)")
            }
        }
        let first = attempt()
        var text = first.text
        if text.isEmpty {
            log.error("OCR warm-up returned nothing (\(first.note, privacy: .public)); retrying once")
            Thread.sleep(forTimeInterval: 1)
            text = attempt().text
        }
        return (text, Date().timeIntervalSince(start), first.note)
    }
}
