import CoreGraphics
import Foundation
import Vision

/// Reads text on the screen with the iPhone's built-in text recognition (no network, no AI tokens).
enum TextReader {
    /// Text boxes in the agent's 0...1000 space. Empty when nothing is readable.
    static func read(_ image: CGImage) async -> [TextBox] {
        await Task.detached(priority: .userInitiated) { readNow(image) }.value
    }

    private static func readNow(_ image: CGImage) -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox // normalized, origin at bottom-left
            return TextBox(text: best.string,
                           x: Double(box.midX) * 1000,
                           y: Double(1 - box.midY) * 1000,
                           width: Double(box.width) * 1000,
                           height: Double(box.height) * 1000)
        }
    }

    /// 16x16 grayscale thumbnail, used only to tell whether the screen changed.
    static func thumbnail(_ image: CGImage) -> [UInt8] {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : []
    }
}
