import Foundation
import CoreGraphics

struct RetouchPixelMetrics {
    let meanAbsoluteDifference: Double
    let changedFraction: Double
    let clippedFraction: Double
    let newlyClippedFraction: Double
    let detailRetention: Double
}

/// Conservative image-wide diagnostic, never a substitute for a learned identity/texture detector.
enum RetouchPixelAudit {
    static func measure(original: CGImage, candidate: CGImage) -> RetouchPixelMetrics? {
        guard original.width == candidate.width, original.height == candidate.height else { return nil }
        let w = 96, h = 96
        func sample(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let address = buffer.baseAddress,
                      let context = CGContext(data: address, width: w, height: h,
                                              bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? bytes : nil
        }
        guard let a = sample(original), let b = sample(candidate) else { return nil }
        var total = 0.0, changed = 0, clipped = 0, newlyClipped = 0
        var sourceGradient = 0.0, resultGradient = 0.0
        for i in 0..<(w * h) {
            let start = i * 4
            let diff = (0..<3).reduce(0.0) { $0 + Double(abs(Int(a[start + $1]) - Int(b[start + $1]))) / 3.0 / 255.0 }
            total += diff
            if diff > 0.12 { changed += 1 }
            let luminance = (Double(b[start]) + Double(b[start+1]) + Double(b[start+2])) / 3.0
            if luminance < 3 || luminance > 252 { clipped += 1 }
            let originalLuma = (Double(a[start]) + Double(a[start+1]) + Double(a[start+2])) / 3.0
            if (luminance < 3 || luminance > 252) && originalLuma >= 3 && originalLuma <= 252 { newlyClipped += 1 }
            // Compare image gradients rather than raw sharpness; an aggressive denoiser
            // should not erase a large share of edges present in the original.
            if i % w != 0 {
                let previous = start - 4
                let sourcePrev = (Double(a[previous]) + Double(a[previous+1]) + Double(a[previous+2])) / 3.0
                let resultPrev = (Double(b[previous]) + Double(b[previous+1]) + Double(b[previous+2])) / 3.0
                sourceGradient += abs(originalLuma - sourcePrev)
                resultGradient += abs(luminance - resultPrev)
            }
        }
        let count = Double(w * h)
        return .init(meanAbsoluteDifference: total/count, changedFraction: Double(changed)/count,
                     clippedFraction: Double(clipped)/count,
                     newlyClippedFraction: Double(newlyClipped)/count,
                     detailRetention: sourceGradient > 1 ? resultGradient/sourceGradient : 1)
    }
}
