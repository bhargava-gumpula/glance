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
    /// first real question doesn't wait. Returns the recognized text and how long it took.
    @discardableResult
    static func warmUp() -> (text: String, seconds: Double) {
        let start = Date()
        let w = 160, h = 48
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return ("", 0) }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Glance", attributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 12, y: 8))
        NSGraphicsContext.current = nil
        let text = ctx.makeImage().flatMap { try? lines(in: $0).map(\.text).joined(separator: " ") } ?? ""
        return (text, Date().timeIntervalSince(start))
    }
}
