import Foundation
import Vision
import CoreImage
import UIKit

/// Conservative measurements, not identity recognition or an aesthetic oracle.
struct DirectorVisionEvidence {
    var faceCount = 0
    var openFaceCount = 0
    var eyes = "unknown" // open / closed / unknown（主脸判定）
    var expression = "表情未确认"
    var poseHint = ""
    var focusPoint: CGPoint?
}

enum DirectorVision {
    static func inspect(_ image: CIImage) -> DirectorVisionEvidence {
        var value = DirectorVisionEvidence()
        let faces = VNDetectFaceLandmarksRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([faces])
            let observations = (faces.results ?? []).filter { $0.confidence >= 0.6 }
            value.faceCount = observations.count
            // 用主脸（最大脸）判定 eyes 状态，统计睁眼人数
            for face in observations {
                guard let landmarks = face.landmarks,
                      let left = eyeRatio(landmarks.leftEye), let right = eyeRatio(landmarks.rightEye) else { continue }
                let ratio = min(left, right)
                if ratio > 0.20 { value.openFaceCount += 1 }
                if let lips = landmarks.outerLips {
                    let points = lips.normalizedPoints
                    if let minY = points.map({ $0.y }).min(), let maxY = points.map({ $0.y }).max(),
                       let minX = points.map({ $0.x }).min(), let maxX = points.map({ $0.x }).max(), maxX > minX {
                        value.expression = (maxY - minY) / (maxX - minX) > 0.45 ? "嘴部张开；由用户决定是否保留该表情" : "嘴部姿态可见；不评价表情好坏"
                    }
                }
            }
            // 主脸判定：取最大脸的开合状态
            if let mainFace = observations.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
               let landmarks = mainFace.landmarks,
               let left = eyeRatio(landmarks.leftEye), let right = eyeRatio(landmarks.rightEye) {
                let mainRatio = min(left, right)
                value.eyes = mainRatio < 0.12 ? "closed" : mainRatio > 0.20 ? "open" : "unknown"
            }
            // 合影判定：睁眼比例 >= 0.7 视为 "open"
            if !observations.isEmpty {
                let openRatio = Double(value.openFaceCount) / Double(observations.count)
                if value.eyes == "unknown" && openRatio >= 0.7 { value.eyes = "open" }
            }
            if let face = observations.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                let b = face.boundingBox
                value.focusPoint = CGPoint(x: b.midX, y: b.midY)
            }
        } catch { /* Unknown must not become "eyes open". */ }
        do {
            try handler.perform([pose])
            if let body = pose.results?.first,
               let points = try? body.recognizedPoints(.all) {
                if let left = points[.leftShoulder], let right = points[.rightShoulder], left.confidence > 0.5, right.confidence > 0.5 {
                    let span = abs(left.location.x - right.location.x)
                    if span > 0.06 && abs(left.location.y - right.location.y) / span > 0.25 {
                        value.poseHint = "双肩明显倾斜：如非刻意姿态，可放松并调整肩线"
                    }
                }
                let wrists = [points[.leftWrist], points[.rightWrist]].compactMap { $0 }.filter { $0.confidence > 0.5 }
                if wrists.contains(where: { $0.location.x < 0.025 || $0.location.x > 0.975 || $0.location.y < 0.025 }) {
                    value.poseHint = "手腕接近边缘，请稍拉远或移动机位，保留完整手部"
                }
            }
        } catch { }
        return value
    }
    private static func eyeRatio(_ eye: VNFaceLandmarkRegion2D?) -> Double? {
        guard let points = eye?.normalizedPoints, points.count >= 4,
              let minX = points.map({ $0.x }).min(), let maxX = points.map({ $0.x }).max(),
              let minY = points.map({ $0.y }).min(), let maxY = points.map({ $0.y }).max(), maxX - minX > 0.001 else { return nil }
        return Double((maxY - minY) / (maxX - minX))
    }

    /// Fresh segmentation for each processed frame; no stale mask attached to a moving person.
    /// Uncertain masks and excessive thermal load fall back to the original image.
    static func backgroundBlur(_ image: CIImage, strength: Double) -> CIImage {
        guard strength > 0, ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return image }
        guard let mask = makeSegmentationMask(for: image) else { return image }
        return applyBackgroundBlur(mask: mask, image: image, strength: strength)
    }

    /// Run segmentation and reject near-empty or whole-frame masks. Shared by
    /// the per-still `backgroundBlur` and the throttled `BackgroundBlurProcessor`.
    static func makeSegmentationMask(for image: CIImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do { try VNImageRequestHandler(ciImage: image, orientation: .up, options: [:]).perform([request]) }
        catch { return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let raw = CIImage(cvPixelBuffer: buffer)
        let mask = raw.transformed(by: CGAffineTransform(scaleX: image.extent.width / raw.extent.width,
                                                        y: image.extent.height / raw.extent.height)).cropped(to: image.extent)
        let avg = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mask.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        ImagePipeline.context.render(avg, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        guard pixel[0] > 8, pixel[0] < 240 else { return nil }
        return mask
    }

    fileprivate static func applyBackgroundBlur(mask: CIImage, image: CIImage, strength: Double) -> CIImage {
        let protected = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": max(1, image.extent.width * 0.002)])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.2]).cropped(to: image.extent)
        let blur = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": min(10, image.extent.width * 0.005) * min(1, strength)]).cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: blur, kCIInputMaskImageKey: protected]).cropped(to: image.extent)
    }
}
/// Stateful background blur for the live preview: segments at most ~12Hz and
/// reuses the previous mask in between, so a 15fps preview no longer runs
/// full segmentation on every frame. Hot states halve the rate or abort.
final class BackgroundBlurProcessor {
    private var cachedMask: CIImage?
    private var lastSegmentAt = -Double.infinity
    private var lastImageExtent = CGRect.zero

    private func segmentationInterval() -> Double {
        let state = ProcessInfo.processInfo.thermalState
        if state == .serious || state == .critical { return 0.4 }   // ~2.5Hz
        if state == .fair { return 0.16 }                             // ~6Hz
        return 1.0 / 12.0
    }

    func process(_ image: CIImage, strength: Double) -> CIImage {
        guard strength > 0, ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return image }
        let now = ProcessInfo.processInfo.systemUptime
        let needsResegment = now - lastSegmentAt >= segmentationInterval() ||
            image.extent != lastImageExtent ||
            cachedMask == nil
        if needsResegment {
            if let refreshed = DirectorVision.makeSegmentationMask(for: image) {
                cachedMask = refreshed
                lastSegmentAt = now
                lastImageExtent = image.extent
            } else {
                cachedMask = nil
                lastImageExtent = .zero
                lastSegmentAt = now
            }
        }
        guard let mask = cachedMask, image.extent == lastImageExtent else { return image }
        return DirectorVision.applyBackgroundBlur(mask: mask, image: image, strength: strength)
    }
}

struct DirectorInspection {
    var notes: [String] = []
    var suggestsRetake = false
}
extension DirectorVision {
    static func inspectPhoto(_ image: CIImage) -> DirectorInspection {
        let evidence = inspect(image)
        var result = DirectorInspection()
        if evidence.eyes == "closed" { result.notes.append("疑似闭眼，建议确认并重拍"); result.suggestsRetake = true }
        else { result.notes.append(evidence.eyes == "open" ? "可见眼部张开" : "眼部状态未知，请人工检查") }
        if !evidence.poseHint.isEmpty { result.notes.append(evidence.poseHint) }
        let w = 128, h = 128
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let fitted = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
        ImagePipeline.context.render(fitted, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var clipped = 0, dark = 0
        var gradient = 0.0
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
        }
        for y in 0..<h { for x in 0..<w {
            let l = luma(x, y)
            if l > 250 { clipped += 1 }; if l < 8 { dark += 1 }
            if x > 0 { gradient += abs(l - luma(x - 1, y)) }
        } }
        if Double(clipped) / Double(w * h) > 0.12 { result.notes.append("大面积亮部接近溢出，请检查主体高光，必要时降低曝光重拍"); result.suggestsRetake = true }
        if Double(dark) / Double(w * h) > 0.50 { result.notes.append("大面积暗部，请检查人物细节；不自动把夜景提成白天") }
        if gradient / Double(w * h) < 2 { result.notes.append("细节变化偏低：可能是失焦、拖影，也可能是平整场景，请放大确认"); result.suggestsRetake = true }
        result.notes.append("模糊与闭眼均为估计；原片始终保留，不自动删除")
        return result
    }
}
