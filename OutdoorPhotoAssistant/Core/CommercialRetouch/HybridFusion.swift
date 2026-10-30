import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Errors

enum HybridFusionError: LocalizedError {
    case sizeMismatch
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .sizeMismatch:
            return "本地版与云端版尺寸不兼容，拒绝自动融合"
        case .renderFailed:
            return "融合渲染失败"
        }
    }
}

// MARK: - Result types

/// Which render the delivered pixels came from.
enum HybridFusionSource: String {
    case local
    case cloud
    case hybrid

    var displayName: String {
        switch self {
        case .local: return "本地精修"
        case .cloud: return "云端版"
        case .hybrid: return "分区融合"
        }
    }
}

/// One delivery decision.
///
/// `image` is always aligned to the local extent: the studio's crop, orientation
/// and DPI are computed by the local pipeline and stay authoritative, so a cloud
/// render (or a fused render) never changes the delivered geometry.
struct HybridFusionResult {
    var image: CIImage
    var source: HybridFusionSource
    /// Chinese one-liner for the review UI.
    var reason: String
    /// Always contains `local_score` and `cloud_score` (3 decimals). A real fusion
    /// adds `subject_coverage`, `skin_coverage`, `mask_mean`, `edge_weight` and
    /// `feather_px`; `select` adds `quality_delta` when the two passes tie.
    var metrics: [String: Double]
}

// MARK: - Engine

/// Two-engine fusion: the local retouch keeps skin and facial detail (pores must
/// survive), the Seedream cloud render supplies hair and background where a local
/// matte tends to overflow, and the subject edge is feathered between the two.
///
/// Nothing here is generative on top of the two inputs: the fused image is a
/// masked blend of two already rendered candidates, and every failure path falls
/// back to the local render with a Chinese explanation instead of inventing pixels.
final class HybridFusionEngine {

    // MARK: - Tuning

    /// Score distance under which the two candidates are considered equivalent.
    static let hybridWindow: Double = 0.10
    /// Local weight on the subject body: hair and background lean on the cloud
    /// render, the subject keeps a minority of local pixels.
    static let subjectEdgeWeight: Double = 0.35
    /// Seam and subject-edge feather, in full-resolution pixels.
    static let seamFeatherPx: CGFloat = 2.0
    /// Skin probability at or above this value is promoted to a fully local pixel
    /// (alpha = 1), because that is where the pores live.
    static let skinHardLimit: Double = 0.6
    /// Long edge handed to Vision; the matte is scaled back up in Core Image.
    static let segmentationEdge: CGFloat = 1600
    /// Long edge of the mask proxy used for the reported coverage numbers.
    static let coverageEdge: CGFloat = 192

    // MARK: - Weights (they sum to 1)

    static let textureWeight: Double = 0.35
    static let skinToneWeight: Double = 0.25
    static let seamWeight: Double = 0.15
    static let clippingWeight: Double = 0.15
    static let ssimWeight: Double = 0.10

    /// Ideal texture-retention band, from the commercial QC gate (0.50-1.15 fails
    /// outside this narrower window only when it drifts far enough to be visible).
    static let textureIdealLow: Double = 0.60
    static let textureIdealHigh: Double = 0.95
    /// ΔE00 at or below this is a perfect skin-tone match.
    static let skinToneIdeal: Double = 3.0
    /// Seam slope ratio tolerance, identical to `RetouchQualityGate.seamTolerance`.
    static let seamTolerance: Double = 0.30
    /// QC gate limits: clipping is normalised by them, worst channel wins.
    static let clippingSkinLimit: Double = 0.002
    static let clippingFullLimit: Double = 0.010
    /// SSIM at or above this is a perfect structural match.
    static let ssimIdeal: Double = 0.85

    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    // MARK: - Scoring

    /// Weighted quality score in 0...1 for one retouch pass.
    ///
    /// 0.35 texture retention (ideal 0.60-0.95), 0.25 skin-tone ΔE00 (≤ 3 is
    /// perfect), 0.15 seam ratio (1.0 is perfect), 0.15 clipping (0 is perfect,
    /// normalised by the QC gate limits), 0.10 SSIM (≥ 0.85 is perfect).
    ///
    /// A missing report, and a report without any metric (the
    /// `RetouchQualityReport.failure` sentinel), score 0: there is no evidence to
    /// rank the pass with. A metric missing from an otherwise populated report
    /// counts as ideal, so a partial report is not punished twice.
    func score(_ report: RetouchQualityReport?) -> Double {
        guard let report, !report.metrics.isEmpty else { return 0 }
        let metrics = report.metrics
        var total = 0.0
        total += Self.textureWeight * Self.textureScore(metrics["texture_retention"])
        total += Self.skinToneWeight * Self.skinToneScore(metrics["skin_tone_de"])
        total += Self.seamWeight * Self.seamScore(metrics["seam_ratio"])
        total += Self.clippingWeight * Self.clippingScore(metrics["clipping_skin"],
                                                          metrics["clipping_full"])
        total += Self.ssimWeight * Self.ssimScore(metrics["ssim"])
        return Self.clamp(total)
    }

    /// Full credit inside the ideal band, linear decay outside it (0 at 0.30 below
    /// and 1.30 above, which is where the band-pass energy is visibly destroyed).
    static func textureScore(_ value: Double?) -> Double {
        guard let raw = value, raw.isFinite else { return 1.0 }
        if raw >= textureIdealLow && raw <= textureIdealHigh { return 1.0 }
        if raw < textureIdealLow {
            return clamp(1.0 - (textureIdealLow - raw) / 0.30)
        }
        return clamp(1.0 - (raw - textureIdealHigh) / 0.35)
    }

    /// ΔE00 ≤ 3 is a perfect match, linear decay to 0 at ΔE00 9 (visible cast).
    static func skinToneScore(_ value: Double?) -> Double {
        guard let raw = value, raw.isFinite else { return 1.0 }
        if raw <= skinToneIdeal { return 1.0 }
        return clamp(1.0 - (raw - skinToneIdeal) / 6.0)
    }

    /// A seam ratio of 1.0 is perfect; the tolerance is the QC gate's ±0.30.
    static func seamScore(_ value: Double?) -> Double {
        guard let raw = value, raw.isFinite else { return 1.0 }
        return clamp(1.0 - abs(raw - 1.0) / seamTolerance)
    }

    /// Clipping is 0 in a perfect render. Each channel is normalised by its QC gate
    /// limit and the worst one wins, so a passing report can still lose a little.
    static func clippingScore(_ skin: Double?, _ full: Double?) -> Double {
        var worst = 0.0
        if let value = skin, value.isFinite {
            worst = max(worst, max(0.0, value) / clippingSkinLimit)
        }
        if let value = full, value.isFinite {
            worst = max(worst, max(0.0, value) / clippingFullLimit)
        }
        return clamp(1.0 - worst)
    }

    /// SSIM ≥ 0.85 is perfect, linear decay to 0 at 0.50.
    static func ssimScore(_ value: Double?) -> Double {
        guard let raw = value, raw.isFinite else { return 1.0 }
        if raw >= ssimIdeal { return 1.0 }
        return clamp((raw - 0.50) / (ssimIdeal - 0.50))
    }

    // MARK: - Decision

    /// Pure decision table, split out so it is unit testable without Vision.
    ///
    /// 1. no usable cloud render -> local
    /// 2. cloud more than `hybridWindow` worse -> local
    /// 3. local failed the gate, cloud passed -> cloud
    /// 4. both passed and within `hybridWindow` -> hybrid
    /// 5. anything else -> local
    static func decision(localScore: Double, cloudScore: Double,
                         localPassed: Bool, cloudPassed: Bool,
                         cloudAvailable: Bool) -> HybridFusionSource {
        guard cloudAvailable else { return .local }
        guard localScore.isFinite, cloudScore.isFinite else { return .local }
        if cloudScore < localScore - hybridWindow { return .local }
        if !localPassed && cloudPassed { return .cloud }
        if localPassed && cloudPassed && abs(localScore - cloudScore) <= hybridWindow {
            return .hybrid
        }
        return .local
    }

    /// Automatic pick between the local render, the cloud render and a fusion of
    /// the two. Without a `SkinAnalysis` the fusion treats the subject matte as the
    /// skin matte; callers that have the analysis should call `fuse` directly.
    func select(local: CIImage, cloud: CIImage?, localReport: RetouchQualityReport,
                cloudReport: RetouchQualityReport?) -> HybridFusionResult {
        let localScore = Self.rounded3(score(localReport))
        let cloudScore = Self.rounded3(score(cloudReport))
        let metrics: [String: Double] = [
            "local_score": localScore,
            "cloud_score": cloudScore,
            "local_passed": localReport.passed ? 1.0 : 0.0,
            "cloud_passed": (cloudReport?.passed ?? false) ? 1.0 : 0.0,
        ]
        guard let cloud else {
            return HybridFusionResult(image: local, source: .local,
                                      reason: "没有云端版本，保留本地精修",
                                      metrics: metrics)
        }
        // No local evidence at all (the QC sentinel): never let an unmeasured local
        // render be replaced by the cloud one just because its report was empty.
        guard !localReport.metrics.isEmpty else {
            return HybridFusionResult(image: local, source: .local,
                                      reason: "本地质检数据缺失，保留本地精修",
                                      metrics: metrics)
        }
        let cloudPassed = cloudReport?.passed ?? false
        let outcome = Self.decision(localScore: localScore, cloudScore: cloudScore,
                                    localPassed: localReport.passed,
                                    cloudPassed: cloudPassed, cloudAvailable: true)
        switch outcome {
        case .cloud:
            // The delivered geometry always follows the local extent.
            guard let fitted = Self.fitting(cloud, into: local.extent) else {
                return HybridFusionResult(image: local, source: .local,
                                          reason: "云端版尺寸不可用，保留本地精修",
                                          metrics: metrics)
            }
            return HybridFusionResult(image: fitted, source: .cloud,
                                      reason: "本地精修未过质检、云端版通过，交付云端版",
                                      metrics: metrics)
        case .hybrid:
            do {
                var fused = try fuse(local: local, cloud: cloud, analysis: nil,
                                     context: context,
                                     localReport: localReport, cloudReport: cloudReport)
                if fused.source == .hybrid {
                    let delta = abs(localScore - cloudScore)
                    fused.metrics["quality_delta"] = Self.rounded3(delta)
                    fused.reason = String(format: "质检分接近（Δ %.3f），交付本地+云端分区融合版", delta)
                }
                return fused
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "融合失败"
                return HybridFusionResult(image: local, source: .local,
                                          reason: message + "，保留本地精修",
                                          metrics: metrics)
            }
        case .local:
            return HybridFusionResult(image: local, source: .local,
                                      reason: Self.localReason(localScore: localScore,
                                                               cloudScore: cloudScore,
                                                               localPassed: localReport.passed,
                                                               cloudPassed: cloudPassed),
                                      metrics: metrics)
        }
    }

    private static func localReason(localScore: Double, cloudScore: Double,
                                    localPassed: Bool, cloudPassed: Bool) -> String {
        if cloudScore < localScore - hybridWindow {
            return String(format: "云端版质检分更低（%.3f < %.3f），保留本地精修",
                          cloudScore, localScore)
        }
        if localPassed && !cloudPassed {
            return "云端版未过质检，保留本地精修"
        }
        return "质检结论无法判定优劣，保留本地精修"
    }

    // MARK: - Fusion

    /// Region-aware fusion: cloud as the base, local on top through
    /// `max(subject edge x 0.35, skin)`, so pores keep full local pixels while hair
    /// and background come from the cloud render and the seam is feathered.
    ///
    /// Only degenerate input sizes throw; a failed segmentation returns the local
    /// render untouched with a Chinese reason.
    func fuse(local: CIImage, cloud: CIImage, analysis: SkinAnalysis?,
              context: CIContext,
              localReport: RetouchQualityReport? = nil,
              cloudReport: RetouchQualityReport? = nil) throws -> HybridFusionResult {
        let extent = local.extent
        guard Self.isUsable(extent) else { throw HybridFusionError.sizeMismatch }
        var metrics: [String: Double] = [
            "local_score": Self.rounded3(score(localReport)),
            "cloud_score": Self.rounded3(score(cloudReport)),
            "edge_weight": Self.rounded3(Self.subjectEdgeWeight),
            "feather_px": Double(Self.seamFeatherPx),
        ]
        // The cloud render is fitted into the local frame; the local extent is never
        // resized.
        guard let fitted = Self.fitting(cloud, into: extent) else {
            throw HybridFusionError.sizeMismatch
        }
        guard let subject = subjectMask(for: local, context: context) else {
            return HybridFusionResult(image: local, source: .local,
                                      reason: "主体分割不可用，保留本地精修，未做分区融合",
                                      metrics: metrics)
        }
        if let coverage = Self.coverage(subject, context: context) {
            metrics["subject_coverage"] = Self.rounded3(coverage)
        }
        let skinSource: CIImage
        if let analysis, Self.isUsable(analysis.skinMask.extent) {
            skinSource = analysis.skinMask
        } else {
            // No skin analysis: the subject matte is the best skin proxy we have.
            skinSource = subject
        }
        guard let skin = Self.aligned(skinSource, to: extent) else {
            return HybridFusionResult(image: local, source: .local,
                                      reason: "皮肤蒙版与本地版尺寸不匹配，保留本地精修",
                                      metrics: metrics)
        }
        guard let mask = Self.fusionMask(subject: subject, skin: skin, extent: extent) else {
            return HybridFusionResult(image: local, source: .local,
                                      reason: "融合蒙版构建失败，保留本地精修",
                                      metrics: metrics)
        }
        if let coverage = Self.coverage(skin, context: context) {
            metrics["skin_coverage"] = Self.rounded3(coverage)
        }
        if let mean = Self.coverage(mask, context: context) {
            metrics["mask_mean"] = Self.rounded3(mean)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = local
        blend.backgroundImage = fitted
        blend.maskImage = mask
        guard let fused = blend.outputImage?.cropped(to: extent) else {
            return HybridFusionResult(image: local, source: .local,
                                      reason: "分区融合合成失败，保留本地精修",
                                      metrics: metrics)
        }
        return HybridFusionResult(image: fused, source: .hybrid,
                                  reason: "皮肤与面部细节取本地精修（保毛孔），头发与背景取云端版，边缘羽化过渡",
                                  metrics: metrics)
    }

    /// `max(subject edge x subjectEdgeWeight, skin hardened to alpha 1)`, then a
    /// 2 px Gaussian so the transition line disappears. Every input is an opaque
    /// luminance mask, which is what `CIBlendWithMask` reads.
    static func fusionMask(subject: CIImage, skin: CIImage, extent: CGRect) -> CIImage? {
        guard isUsable(extent) else { return nil }
        let featheredSubject = blurred(subject, radius: seamFeatherPx, extent: extent)
        let edge = gained(featheredSubject, gain: CGFloat(subjectEdgeWeight), extent: extent)
        // Skin probability at or above `skinHardLimit` becomes a fully local pixel.
        let skinAlpha = gained(skin, gain: CGFloat(1.0 / skinHardLimit), extent: extent)
        let maximum = CIFilter.maximumCompositing()
        maximum.inputImage = skinAlpha
        maximum.backgroundImage = edge
        guard let combined = maximum.outputImage?.cropped(to: extent) else { return nil }
        return blurred(combined, radius: seamFeatherPx, extent: extent).cropped(to: extent)
    }

    // MARK: - Subject matte

    /// Vision person segmentation at a proxy size; the matte is scaled back to the
    /// full extent in Core Image, never on the CPU.
    private func subjectMask(for image: CIImage, context: CIContext) -> CIImage? {
        let extent = image.extent
        guard Self.isUsable(extent), max(extent.width, extent.height) >= 8 else { return nil }
        guard let proxy = Self.visionProxy(image, maximumEdge: Self.segmentationEdge,
                                           context: context) else { return nil }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: proxy, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        let buffer = observation.pixelBuffer
        guard CVPixelBufferGetWidth(buffer) >= 1, CVPixelBufferGetHeight(buffer) >= 1 else {
            return nil
        }
        let raw = CIImage(cvPixelBuffer: buffer)
        return Self.aligned(raw, to: extent)
    }

    // MARK: - Geometry

    /// Fits an arbitrary render into `extent`: aspect-fill scale, centred, then
    /// cropped. The target extent is never modified, so the local geometry wins.
    static func fitting(_ cloud: CIImage, into extent: CGRect) -> CIImage? {
        let source = cloud.extent
        guard isUsable(source), isUsable(extent) else { return nil }
        guard source.width >= 2, source.height >= 2 else { return nil }
        let sameSize = abs(source.width - extent.width) < 0.5
            && abs(source.height - extent.height) < 0.5
        if sameSize {
            let moved = cloud.transformed(by: CGAffineTransform(translationX: extent.minX - source.minX,
                                                                y: extent.minY - source.minY))
            return moved.cropped(to: extent)
        }
        let scale = max(extent.width / source.width, extent.height / source.height)
        guard scale.isFinite, scale > 0 else { return nil }
        let transform = CGAffineTransform(translationX: -source.minX, y: -source.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaled = cloud.transformed(by: transform)
        let scaledExtent = scaled.extent
        guard isUsable(scaledExtent),
              scaledExtent.width >= extent.width - 0.5,
              scaledExtent.height >= extent.height - 0.5 else { return nil }
        let crop = CGRect(x: scaledExtent.midX - extent.width / 2,
                          y: scaledExtent.midY - extent.height / 2,
                          width: extent.width, height: extent.height)
        let centred = scaled.cropped(to: crop)
        let moved = centred.transformed(by: CGAffineTransform(translationX: extent.minX - crop.minX,
                                                              y: extent.minY - crop.minY))
        return moved.cropped(to: extent)
    }

    /// Aligns a mask of any size/origin onto `extent` with one affine transform.
    static func aligned(_ mask: CIImage, to extent: CGRect) -> CIImage? {
        let maskExtent = mask.extent
        guard isUsable(maskExtent), isUsable(extent) else { return nil }
        let scaleX = extent.width / maskExtent.width
        let scaleY = extent.height / maskExtent.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        let transform = CGAffineTransform(translationX: -maskExtent.minX, y: -maskExtent.minY)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return mask.transformed(by: transform).cropped(to: extent)
    }

    // MARK: - Rendering helpers

    static func visionProxy(_ image: CIImage, maximumEdge: CGFloat, context: CIContext) -> CGImage? {
        let extent = image.extent
        guard isUsable(extent), maximumEdge > 1 else { return nil }
        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > maximumEdge ? maximumEdge / longEdge : 1
        let proxy = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return PixelKit.cgImage(proxy, context: context)
    }

    /// Mean luminance of a mask, measured on a small proxy (same pattern as the QC
    /// gate) for the coverage numbers shown after a fusion.
    static func coverage(_ mask: CIImage, context: CIContext) -> Double? {
        guard let rendered = PixelKit.renderRGBA8(mask, maxEdge: coverageEdge, context: context),
              !rendered.isEmpty else { return nil }
        let total = rendered.width * rendered.height
        guard total > 0, rendered.bytes.count >= total * 4 else { return nil }
        var sum = 0.0
        var index = 0
        while index < total {
            sum += Double(rendered.bytes[index * 4]) / 255.0
            index += 1
        }
        let mean = sum / Double(total)
        return mean.isFinite ? mean : nil
    }

    static func isUsable(_ extent: CGRect) -> Bool {
        guard !extent.isInfinite, !extent.isNull else { return false }
        guard extent.width.isFinite, extent.height.isFinite else { return false }
        return extent.width >= 1 && extent.height >= 1
    }

    /// Gaussian blur over edge-clamped pixels, cropped back to `extent`.
    static func blurred(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let fallback = image.cropped(to: extent)
        guard radius.isFinite, radius > 0.3 else { return fallback }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage else { return fallback }
        return output.cropped(to: extent)
    }

    /// Scales a mask's luminance by `gain` (gain may exceed 1, the result is
    /// clamped to 0...1) while keeping it opaque.
    static func gained(_ image: CIImage, gain: CGFloat, extent: CGRect) -> CIImage {
        let validGain = gain.isFinite ? gain : 1.0
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: validGain, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: validGain, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: validGain, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let boosted = (matrix.outputImage ?? image).cropped(to: extent)
        let clampFilter = CIFilter.colorClamp()
        clampFilter.inputImage = boosted
        clampFilter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampFilter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return (clampFilter.outputImage ?? boosted).cropped(to: extent)
    }

    // MARK: - Numbers

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0.0), 1.0)
    }

    static func rounded3(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1000.0).rounded() / 1000.0
    }
}
