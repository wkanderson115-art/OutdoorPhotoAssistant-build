import Foundation
import CoreGraphics
import CoreImage
import simd

// MARK: - Geometry

/// Face geometry in normalised coordinates (origin top-left, y down), exactly
/// the convention the Python reference lab uses, so mask parameters tuned in
/// `tools/retouch_lab/portrait.py` transfer 1:1.
struct FaceGeometry {
    var box: CGRect
    var leftEye: CGRect?
    var rightEye: CGRect?
    var lips: CGRect?
    var nose: CGPoint?

    var width: CGFloat { box.width }
    var height: CGFloat { box.height }

    func derivedEyes() -> (CGRect, CGRect) {
        if let l = leftEye, let r = rightEye { return (l, r) }
        let w = width, h = height
        let eyeW = w * 0.26, eyeH = h * 0.115
        let cy = box.minY + h * 0.42
        return (CGRect(x: box.minX + w * 0.30 - eyeW / 2, y: cy - eyeH / 2, width: eyeW, height: eyeH),
                CGRect(x: box.minX + w * 0.70 - eyeW / 2, y: cy - eyeH / 2, width: eyeW, height: eyeH))
    }

    func derivedLips() -> CGRect {
        if let l = lips { return l }
        let w = width, h = height
        return CGRect(x: box.minX + w * 0.5 - w * 0.17,
                      y: box.minY + h * 0.73 - h * 0.065,
                      width: w * 0.34, height: h * 0.13)
    }

    /// Normalised rect -> pixel rect for an image of `size`.
    func pixelRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }
}

// MARK: - Analysis output

struct SkinAnalysis {
    /// Soft skin probability, full-resolution extent, luminance coded 0...1.
    var skinMask: CIImage
    /// Eyes / brows / lips / nostrils, luminance coded 0...1 (1 = protected).
    var featureMask: CIImage
    var noiseSigma: Double
    var geometry: FaceGeometry
    var skinLabMedian: SIMD3<Double>
    var exposure: Double
    var whiteBalance: SIMD3<Double>
    var longEdge: CGFloat
    /// Proxy resolution used for all CPU analysis (long edge).
    var analysisEdge: CGFloat
}

struct BlemishSpot {
    var center: CGPoint      // normalised, y down
    var radius: CGFloat      // normalised by the long edge
    var score: Double
    var kind: String         // "acne" | "shadow"
}

/// Commercial QC result for one retouch pass. Thresholds are the same numbers
/// used by `tools/retouch_lab/pipeline.py::quality_gate`.
struct RetouchQualityReport {
    var passed: Bool
    var metrics: [String: Double]
    var notes: [String]

    static let failure = RetouchQualityReport(passed: false, metrics: [:], notes: ["像素质量检测不可用"])

    var summary: String {
        if metrics.isEmpty { return notes.joined(separator: "；") }
        let retention = metrics["texture_retention"] ?? 0
        let tone = metrics["skin_tone_de"] ?? 0
        let seam = metrics["seam_ratio"] ?? 1
        let ssimValue = metrics["ssim"] ?? 0
        let head = String(format: "纹保留 %.2f · 肤色ΔE %.2f · 接缝 %.2f · SSIM %.3f",
                          retention, tone, seam, ssimValue)
        return passed ? "质检通过：\(head)" : "质检未通过：\(head)；" + notes.joined(separator: "；")
    }
}

// MARK: - Looks

enum RetouchLook: String, CaseIterable, Identifiable {
    case commercialNatural
    case refinedPortrait
    case cinematic
    case freshJapanese
    case landscapeNatural
    case nightClear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commercialNatural: return "商业自然"
        case .refinedPortrait: return "精致写真"
        case .cinematic: return "电影人像"
        case .freshJapanese: return "清新日系"
        case .landscapeNatural: return "自然风光"
        case .nightClear: return "夜景通透"
        }
    }

    var lift: SIMD3<Double> {
        switch self {
        case .commercialNatural: return SIMD3(0.004, 0.004, 0.006)
        case .refinedPortrait: return SIMD3(0.006, 0.005, 0.008)
        case .cinematic: return SIMD3(0.010, 0.008, 0.014)
        case .freshJapanese: return SIMD3(0.012, 0.014, 0.016)
        case .landscapeNatural: return SIMD3(0, 0, 0)
        case .nightClear: return SIMD3(0.004, 0.005, 0.010)
        }
    }

    var gamma: SIMD3<Double> {
        switch self {
        case .commercialNatural: return SIMD3(1.0, 1.0, 1.01)
        case .refinedPortrait: return SIMD3(1.02, 1.0, 0.99)
        case .cinematic: return SIMD3(1.05, 1.0, 0.96)
        case .freshJapanese: return SIMD3(0.97, 0.99, 1.03)
        case .landscapeNatural: return SIMD3(1.0, 1.0, 1.0)
        case .nightClear: return SIMD3(0.98, 1.0, 1.06)
        }
    }

    var gain: SIMD3<Double> {
        switch self {
        case .commercialNatural: return SIMD3(1.02, 1.01, 0.99)
        case .refinedPortrait: return SIMD3(1.04, 1.01, 0.97)
        case .cinematic: return SIMD3(1.03, 1.0, 0.95)
        case .freshJapanese: return SIMD3(1.0, 1.02, 1.04)
        case .landscapeNatural: return SIMD3(1.02, 1.01, 0.99)
        case .nightClear: return SIMD3(1.04, 1.0, 0.96)
        }
    }

    var shadowTint: SIMD3<Double> {
        switch self {
        case .refinedPortrait: return SIMD3(0, 0, 0.01)
        case .cinematic: return SIMD3(0, 0.005, 0.02)
        default: return SIMD3(0, 0, 0)
        }
    }

    var highlightTint: SIMD3<Double> {
        switch self {
        case .refinedPortrait: return SIMD3(0.012, 0.006, 0)
        case .cinematic: return SIMD3(0.03, 0.015, -0.01)
        default: return SIMD3(0, 0, 0)
        }
    }
}

// MARK: - Parameters

/// Every number here is the one that was measured/tuned in the Python reference
/// lab (`tools/retouch_lab`), where it was checked against a commercial QC gate.
struct RetouchParameters {
    var smoothRadius: Double = 5.0
    var smoothAmount: Double = 0.55
    var textureGain: Double = 0.82
    var colorEvenAmount: Double = 0.5
    var colorEvenRadius: Double = 16.0
    var dodgeBurnAmount: Double = 0.30
    var dodgeBurnRadius: Double = 24.0
    var dodgeBurnClip: Double = 4.0
    var skinToneAmount: Double = 0.35
    var blemishStrength: Double = 0.9
    var blemishSensitivity: Double = 0.6
    var eyeAmount: Double = 0.55
    var teethAmount: Double = 0.55
    var underEyeAmount: Double = 0.45
    var lipAmount: Double = 0.2
    var clarityAmount: Double = 0.09
    var clarityRadius: Double = 18.0
    var sharpenRadius: Double = 0.8
    var sharpenAmount: Double = 0.18
    var sharpenThreshold: Double = 0.008
    var exposureTarget: Double = 0.545
    var maxExposureEV: Double = 0.9
    var highlightRolloff: Double = 0.86
    var shadowLift: Double = 0.10
    var contrast: Double = 1.04
    var vibrance: Double = 0.05
    var saturation: Double = 1.0
    var lutStrength: Double = 0.40
    var grain: Double = 0.0
    var vignette: Double = 0.0
    var skinProtectDE: Double = 3.0
    /// Lightroom 核心阶段的强度倍率（0 = 关闭，1 = 标准，>1 = 风格化）。
    /// 它只缩 Look 的“调整量”，不缩半径/颗粒尺寸这类结构参数。
    var lightroomAmount: Double = 1.0
    /// 是否套用风格 Look（LUT + Lightroom 核心阶段）。
    /// 文档 / 翻拍 / 手机截图类必须为 false：它们要的是结构稳定，不是风格化。
    var applyLook: Bool = true
    var maxPasses: Int = 2

    /// Resolution scaling: the reference numbers are calibrated at 6000 px long edge.
    func scaled(longEdge: CGFloat) -> RetouchParameters {
        let s = Double(longEdge) / 6000.0
        var p = self
        p.smoothRadius = max(2.0, smoothRadius * max(0.35, s * 1.6))
        p.colorEvenRadius = max(4.0, colorEvenRadius * max(0.35, s * 1.6))
        p.dodgeBurnRadius = max(6.0, dodgeBurnRadius * max(0.35, s * 1.6))
        p.clarityRadius = max(6.0, clarityRadius * max(0.35, s * 1.6))
        p.sharpenRadius = max(0.5, sharpenRadius)
        return p
    }

    static func preset(look: RetouchLook, category: String) -> RetouchParameters {
        var p = RetouchParameters()
        switch look {
        case .commercialNatural:
            p.smoothAmount = 0.52; p.textureGain = 0.84; p.lutStrength = 0.38
        case .refinedPortrait:
            p.smoothAmount = 0.58; p.textureGain = 0.80; p.dodgeBurnAmount = 0.36
            p.lutStrength = 0.42; p.vibrance = 0.06
        case .cinematic:
            p.smoothAmount = 0.50; p.textureGain = 0.86; p.contrast = 1.10
            p.shadowLift = 0.16; p.lutStrength = 0.55; p.vibrance = 0.03
        case .freshJapanese:
            p.smoothAmount = 0.62; p.textureGain = 0.78; p.exposureTarget = 0.60
            p.shadowLift = 0.18; p.contrast = 0.98; p.lutStrength = 0.46
        case .landscapeNatural:
            p.clarityAmount = 0.16; p.sharpenAmount = 0.30; p.vibrance = 0.10
            p.lutStrength = 0.30
        case .nightClear:
            p.smoothAmount = 0.40; p.exposureTarget = 0.47; p.shadowLift = 0.26
            p.clarityAmount = 0.12; p.sharpenAmount = 0.12; p.grain = 0.012
        }
        if category == "商品摄影" || category == "建筑与室内" || category == "文档与翻拍" {
            p.smoothAmount = 0
            p.dodgeBurnAmount = 0
            p.eyeAmount = 0
            p.underEyeAmount = 0
            p.teethAmount = 0
            p.lipAmount = 0
            p.clarityAmount = 0.18
            p.sharpenAmount = 0.34
        }
        if category == "星空与天文" {
            p.smoothAmount = 0
            p.sharpenAmount = 0.10
            p.grain = 0.0
        }
        if category == "文档与翻拍" {
            // 文档 / 翻拍 / 手机截图：结构优先。不调色、不加清晰度、不做暗角与颗粒，
            // 只留一点锐化和极轻对比。实测踩过的坑：调色与"抬黑位"会把 UI 白底和
            // 黑边一起改掉，SSIM 从 0.999 掉到 0.91，和"结构不许动"的交付承诺冲突。
            p.applyLook = false
            p.clarityAmount = 0
            p.sharpenAmount = 0.12
            p.contrast = 1.02
            p.vignette = 0
            p.grain = 0
            p.lutStrength = 0
        }
        return p
    }
}
