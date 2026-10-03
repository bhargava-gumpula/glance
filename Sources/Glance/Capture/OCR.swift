import CoreGraphics
import Vision

/// On-device text recognition (Apple Vision). Nothing leaves the Mac here.
enum OCR {
    struct Line: Sendable {
        let text: String
        /// In image pixels, top-left origin.
        let box: CGRect
    }

    static func lines(in image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox // normalized, bottom-left origin
            return Line(text: text, box: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }
}
