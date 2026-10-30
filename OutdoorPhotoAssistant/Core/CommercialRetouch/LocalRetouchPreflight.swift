import Foundation
import UIKit
import CoreImage
import Vision

/// A deterministic safety preflight. This does not claim to measure available RAM.
/// It estimates the cost of several simultaneous RGBA working buffers.
struct LocalRetouchPreflight {
    enum ProcessingTier: String { case standard, memoryConstrained, highResolution }
    struct Result {
        let tier: ProcessingTier
        let pixelCount: Int
        let estimatedPeakBytes: UInt64
        let maxVisionEdge: CGFloat
        let recommendedPreviewEdge: CGFloat
        let notes: [String]
    }
    static func inspect(width: Int, height: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Result? {
        guard width > 0, height > 0, width <= 30000, height <= 30000 else { return nil }
        let pixels = UInt64(width) * UInt64(height)
        // Conservative approximation: 7 RGBA8-sized intermediate buffers.
        let estimate = pixels * 4 * 7
        let constrained = physicalMemory < 4 * 1024 * 1024 * 1024
        let large = pixels >= 24_000_000
        let tier: ProcessingTier = constrained ? .memoryConstrained : (large ? .highResolution : .standard)
        let proxy: CGFloat = constrained ? 1024 : (large ? 1280 : 1600)
        let preview: CGFloat = constrained ? 1280 : 2048
        var notes = ["峰值内存为保守估算，必须在目标 iPhone 上用 Instruments 测量"]
        if large { notes.append("高像素照片应串行处理，并避免缓存多份完整位图") }
        if constrained { notes.append("低内存设备使用更小的 Vision 分析代理图") }
        if estimate > physicalMemory / 3 { notes.append("预计中间缓冲开销较高：应在低内存情况下拒绝批处理并提示用户") }
        return Result(tier: tier, pixelCount: Int(pixels), estimatedPeakBytes: estimate,
                      maxVisionEdge: proxy, recommendedPreviewEdge: preview, notes: notes)
    }
}

/// Detect face rectangles for a review workflow. This is NOT an acne classifier.
/// Do not automatically clone or blur pixels based solely on these observations.
struct LocalPortraitReview {
    struct FaceRegion { let bounds: CGRect; let confidence: Float }
    static func detectFaces(in image: CGImage) -> [FaceRegion] {
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).filter { $0.confidence >= 0.65 }
                .map { FaceRegion(bounds: $0.boundingBox, confidence: $0.confidence) }
        } catch { return [] }
    }
}


/// Tile-based output materialization. Core Image evaluates the same global filter
/// graph for each region, retaining a single RGBA8 destination bitmap. This is
/// not an out-of-core renderer: UIImage/CGImage still requires a full final buffer.
enum LocalTiledRenderer {
    static func render(_ image: CIImage, extent: CGRect, context: CIContext,
                       tileEdge: Int = 1024) -> CGImage? {
        let bounds = extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0, width <= 30000, height <= 30000,
              tileEdge >= 128, tileEdge <= 4096 else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let destination = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        destination.interpolationQuality = .none
        for y in stride(from: 0, to: height, by: tileEdge) {
            for x in stride(from: 0, to: width, by: tileEdge) {
                let tw = min(tileEdge, width - x), th = min(tileEdge, height - y)
                let roi = CGRect(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y),
                                 width: CGFloat(tw), height: CGFloat(th))
                // 设备内存吃紧时 createCGImage 会返回 nil；清缓存重试一次，仍失败再缩小 ROI 重试。
                var tile = context.createCGImage(image, from: roi,
                                                 format: .RGBA8, colorSpace: colorSpace)
                if tile == nil {
                    context.clearCaches()
                    tile = context.createCGImage(image, from: roi,
                                                 format: .RGBA8, colorSpace: colorSpace)
                }
                guard let tileImage = tile else { return nil }
                destination.draw(tileImage, in: CGRect(x: x, y: y, width: tw, height: th))
            }
        }
        return destination.makeImage()
    }
}
