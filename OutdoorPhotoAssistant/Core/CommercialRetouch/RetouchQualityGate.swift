import Foundation
import CoreGraphics
import CoreImage
import simd

/// Commercial QC gate. Port of `tools/retouch_lab/pipeline.py::quality_gate`.
///
/// All metrics are measured on a <= 1100 px proxy of both images, with the
/// original tone-aligned (white balance + exposure) so that a deliberate
/// exposure/WB fix is not scored as a colour error.
final class RetouchQualityGate {

    /// 品类口径。同一个引擎，不同题材的「合格」标准不一样：
    /// * `portrait` 人像：允许磨皮，所以纹理必须落在 0.50–1.15；肤色全套必须过；
    /// * `scene` 风景/户外：没有可靠肤色，只看纹理 0.60–1.20 + 全图裁切 + SSIM；
    /// * `product` 商品/建筑/汽车/静物：本来就要加锐化与清晰度，纹理上限放到 1.45；
    /// * `document` 文档/翻拍/截图：结构优先，SSIM 提到 0.92，纹理上限 1.50。
    enum ShootingMode: String {
        case portrait
        case scene
        case product
        case document

        /// 纹理保留的允许区间。
        var textureRange: ClosedRange<Double> {
            switch self {
            case .portrait: return 0.50...1.15
            case .scene: return 0.60...1.20
            case .product: return 0.60...1.45
            case .document: return 0.60...1.50
            }
        }

        /// 结构相似度下限。文档类最严（结构不允许被改）。
        var ssimMin: Double {
            self == .document ? 0.92 : 0.85
        }

        /// 是否判定肤色相关指标（只有人像有意义）。
        var checksSkin: Bool { self == .portrait }
    }

    struct Input {
        var original: CIImage          // already EXIF-normalised
        var candidate: CIImage
        var skinMask: CIImage?         // full-res luminance mask 0...1
        var blemishClearance: Double   // 0...1, computed by the pipeline
        var spotsBefore: Int
        var exposureEV: Double
        var whiteBalance: SIMD3<Double>
        var context: CIContext
        /// 品类口径。默认人像，由 pipeline 按预设类别 + 是否检出人脸决定。
        var mode: ShootingMode = .portrait
    }

    // MARK: - Thresholds (pipeline.py::quality_gate)

    /// Long edge of the metric proxy: `q = min(1.0, 1100.0 / max(h, w))`.
    private static let proxyLongEdge: CGFloat = 1100
    private static let skinToneMax = 3.0
    private static let skinLumaShiftMax = 18.0
    private static let clippingSkinMax = 0.002
    private static let clippingFullMax = 0.01
    private static let seamTolerance = 0.30
    private static let blemishClearanceMin = 0.6
    private static let blemishMinSpots = 3
    /// 皮肤区「逐像素 ΔE00 的 95 分位」上限。
    /// 中位数那条（`skinToneMax`）只看整体肤色，脸上一块阴影偏绿 / 高光偏黄照样能过；
    /// 这一条专门堵这种局部偏色：p95 超过 6.0 说明「95% 的皮肤像素都在 6 个 ΔE 以内」这个
    /// 商业交付承诺已经不成立。数值 6.0 与 pipeline.py 里 p95 的展示口径对齐。
    private static let skinPixelDEP95Max = 6.0

    // MARK: - Review

    /// Runs every metric and applies the commercial thresholds.
    func review(_ input: Input) -> RetouchQualityReport {
        guard let renderedOriginal = PixelKit.renderRGBA8(input.original,
                                                          maxEdge: Self.proxyLongEdge,
                                                          context: input.context),
              let renderedCandidate = PixelKit.renderRGBA8(input.candidate,
                                                           maxEdge: Self.proxyLongEdge,
                                                           context: input.context) else {
            return RetouchQualityReport.failure
        }
        let width = renderedOriginal.width
        let height = renderedOriginal.height
        guard width > 0, height > 0,
              renderedOriginal.bytes.count >= width * height * 4 else {
            return RetouchQualityReport.failure
        }

        // A candidate with a different aspect ratio yields a different proxy size;
        // re-render it at the reference proxy so every metric compares like with like.
        let candidate: RGBAImage
        if renderedCandidate.width == width, renderedCandidate.height == height {
            candidate = renderedCandidate
        } else if let fitted = PixelKit.renderRGBA8(input.candidate, width: width, height: height,
                                                    context: input.context) {
            candidate = fitted
        } else {
            return RetouchQualityReport.failure
        }
        guard candidate.width == width, candidate.height == height,
              candidate.bytes.count >= width * height * 4 else {
            return RetouchQualityReport.failure
        }

        let reference = toneAligned(renderedOriginal,
                                    whiteBalance: input.whiteBalance,
                                    exposureEV: input.exposureEV)
        let skin = skinPlane(input.skinMask, width: width, height: height, context: input.context)

        let texture = textureRetention(original: reference, candidate: candidate, skin: skin)
        let tone = skinToneDeltaE(original: reference, candidate: candidate, skin: skin)
        let clippingSkin = clippedFraction(candidate, mask: skin)
        let clippingFull = clippedFraction(candidate, mask: nil)
        let seam = seamRatio(original: reference, candidate: candidate, mask: skin)
        let similarity = ssim(original: reference, candidate: candidate)
        let clearance = input.blemishClearance.isFinite ? input.blemishClearance : 0.0
        let spots = max(0, input.spotsBefore)

        var metrics: [String: Double] = [:]
        metrics["texture_retention"] = finite(texture, fallback: 1.0)
        metrics["skin_tone_de"] = finite(tone.medianDE, fallback: 0.0)
        metrics["skin_luma_shift"] = finite(tone.meanDeltaL, fallback: 0.0)
        metrics["skin_pixel_de_p95_info"] = finite(tone.pixelP95, fallback: 0.0)
        metrics["clipping_skin"] = finite(clippingSkin, fallback: 0.0)
        metrics["clipping_full"] = finite(clippingFull, fallback: 0.0)
        metrics["seam_ratio"] = finite(seam, fallback: 1.0)
        metrics["ssim"] = finite(similarity, fallback: 0.0)
        metrics["blemish_clearance"] = finite(clearance, fallback: 0.0)
        metrics["spots_before"] = Double(spots)

        var notes: [String] = []
        var passed = true
        let mode = input.mode

        // 四套口径（mode 见 ShootingMode 注释）：人像判全套肤色；风景/商品/文档只看
        // 结构 + 裁切，纹理区间按品类放宽（商品本来就要加锐化，文档更不能被调色改结构）。
        let range = mode.textureRange
        let textureValue = metrics["texture_retention"] ?? 1.0
        if !range.contains(textureValue) {
            passed = false
            let label = mode == .portrait ? "皮肤纹理保留率" : "纹理保留率"
            notes.append(String(format: "未通过：\(label) %.2f（要求 %.2f–%.2f，\(mode.rawValue) 口径）",
                                textureValue, range.lowerBound, range.upperBound))
        }

        if mode.checksSkin {
            let toneValue = metrics["skin_tone_de"] ?? 0.0
            if toneValue > Self.skinToneMax {
                passed = false
                notes.append(String(format: "未通过：肤色 ΔE00 %.2f（上限 %.2f）",
                                    toneValue, Self.skinToneMax))
            }
            // 局部偏色判定：中位数达标、但皮肤区 95 分位超限的图不算通过。
            // metrics["skin_pixel_de_p95_info"] 这个键必须保留（UI 按它显示「肤色ΔE P95」），
            // 这里只是把它从「展示信息」升级成「门禁项」，键名与语义都不改。
            let pixelP95 = metrics["skin_pixel_de_p95_info"] ?? 0.0
            if pixelP95 > Self.skinPixelDEP95Max {
                passed = false
                notes.append(String(format: "未通过：肤色 ΔE P95 %.2f（上限 %.2f）",
                                    pixelP95, Self.skinPixelDEP95Max))
            }
            let lumaShift = metrics["skin_luma_shift"] ?? 0.0
            if lumaShift > Self.skinLumaShiftMax {
                passed = false
                notes.append(String(format: "未通过：肤色明度偏移 %.2f（上限 %.2f）",
                                    lumaShift, Self.skinLumaShiftMax))
            }
            let clippingSkinValue = metrics["clipping_skin"] ?? 0.0
            if clippingSkinValue > Self.clippingSkinMax {
                passed = false
                notes.append(String(format: "未通过：皮肤高光/死黑裁切 %.4f（上限 %.4f）",
                                    clippingSkinValue, Self.clippingSkinMax))
            }
            let seamValue = metrics["seam_ratio"] ?? 1.0
            if abs(seamValue - 1.0) > Self.seamTolerance {
                passed = false
                notes.append(String(format: "未通过：蒙版接缝梯度比 %.2f（要求 1.00±%.2f）",
                                    seamValue, Self.seamTolerance))
            }
            let clearanceValue = metrics["blemish_clearance"] ?? 0.0
            if spots >= Self.blemishMinSpots {
                if clearanceValue < Self.blemishClearanceMin {
                    passed = false
                    notes.append(String(format: "未通过：瑕疵清除率 %.2f（要求 ≥ %.2f）",
                                        clearanceValue, Self.blemishClearanceMin))
                }
            } else {
                notes.append(String(format: "提示：可检瑕疵 %d 处（少于 %d 处），瑕疵清除率不参与判定（当前 %.2f）",
                                    spots, Self.blemishMinSpots, clearanceValue))
            }
        } else {
            // 风景/商品/文档：没有可靠皮肤遮罩，肤色彩指标只作为参考信息，不参与判定。
            notes.append(String(format: "提示：\(mode.rawValue) 口径——肤色 ΔE %.2f / p95 %.2f 仅作参考，不参与判定",
                                metrics["skin_tone_de"] ?? 0.0,
                                metrics["skin_pixel_de_p95_info"] ?? 0.0))
        }

        let clippingFullValue = metrics["clipping_full"] ?? 0.0
        if clippingFullValue > Self.clippingFullMax {
            passed = false
            notes.append(String(format: "未通过：全图高光/死黑裁切 %.4f（上限 %.4f）",
                                clippingFullValue, Self.clippingFullMax))
        }
        let ssimValue = metrics["ssim"] ?? 0.0
        if ssimValue < mode.ssimMin {
            passed = false
            notes.append(String(format: "未通过：结构相似度 %.3f（下限 %.2f，\(mode.rawValue) 口径）",
                                ssimValue, mode.ssimMin))
        }

        return RetouchQualityReport(passed: passed, metrics: metrics, notes: notes)
    }

    // MARK: - Texture

    /// Band-pass energy ratio inside the skin area (pipeline.py::band_energy_ratio).
    ///
    /// low = gaussian(luma, 4.0); high = luma - low; band = high - gaussian(high, 0.6).
    /// RMS of the band over `skin > 0.5` for both images, ratio = candidate / original.
    func textureRetention(original: RGBAImage, candidate: RGBAImage, skin: FloatPlane) -> Double {
        let width = original.width
        let height = original.height
        guard width > 0, height > 0,
              candidate.width == width, candidate.height == height,
              original.bytes.count >= width * height * 4,
              candidate.bytes.count >= width * height * 4,
              let mask = nearestResample(skin, width: width, height: height) else { return 1.0 }
        let selected = binarize(mask, threshold: 0.5)
        guard selectedCount(selected) > 0 else { return 1.0 }

        let referenceEnergy = bandEnergy(lumaPlane(original), mask: selected)
        let resultEnergy = bandEnergy(lumaPlane(candidate), mask: selected)
        return resultEnergy / max(referenceEnergy, 1e-5)
    }

    /// RMS of the double high-pass band over the selected pixels.
    private func bandEnergy(_ luma: FloatPlane, mask: FloatPlane) -> Double {
        let low = PixelKit.gaussianBlur(luma, sigma: 4.0)
        let high = zipMap(luma, low, { $0 - $1 })
        let highLow = PixelKit.gaussianBlur(high, sigma: 0.6)
        let band = zipMap(high, highLow, { $0 - $1 })
        let squared = zipMap(band, band, { $0 * $1 })
        let energy = PixelKit.mean(squared, mask: mask)
        guard energy.isFinite, energy > 0 else { return 0.0 }
        return Double(energy.squareRoot())
    }

    // MARK: - Skin tone identity

    /// Median skin colour drift (ΔE00 of the robust medians), mean |ΔL*| shift and
    /// the per-pixel ΔE00 95th percentile (informational only).
    func skinToneDeltaE(original: RGBAImage, candidate: RGBAImage,
                        skin: FloatPlane) -> (medianDE: Double, meanDeltaL: Double, pixelP95: Double) {
        let width = original.width
        let height = original.height
        guard width > 0, height > 0,
              candidate.width == width, candidate.height == height,
              original.bytes.count >= width * height * 4,
              candidate.bytes.count >= width * height * 4,
              let mask = nearestResample(skin, width: width, height: height),
              countAbove(mask, threshold: 0.6) > 100 else { return (0.0, 0.0, 0.0) }

        let selected = binarize(mask, threshold: 0.6)
        let labOriginal = PixelKit.lab(original)
        let labCandidate = PixelKit.lab(candidate)
        let needed = width * height
        guard labOriginal.l.values.count >= needed, labOriginal.a.values.count >= needed,
              labOriginal.b.values.count >= needed, labCandidate.l.values.count >= needed,
              labCandidate.a.values.count >= needed, labCandidate.b.values.count >= needed else {
            return (0.0, 0.0, 0.0)
        }

        let medianReference = SIMD3<Float>(PixelKit.median(labOriginal.l, mask: selected),
                                           PixelKit.median(labOriginal.a, mask: selected),
                                           PixelKit.median(labOriginal.b, mask: selected))
        let medianResult = SIMD3<Float>(PixelKit.median(labCandidate.l, mask: selected),
                                        PixelKit.median(labCandidate.a, mask: selected),
                                        PixelKit.median(labCandidate.b, mask: selected))
        let medianDE = Double(PixelKit.deltaE2000(medianReference, medianResult))

        // Per-pixel information terms, evaluated only inside the mask.
        var deltaE = FloatPlane(width: width, height: height, value: 0)
        var deltaL = FloatPlane(width: width, height: height, value: 0)
        for i in 0..<needed where mask.values[i] > 0.6 {
            let referenceLab = SIMD3<Float>(labOriginal.l.values[i],
                                            labOriginal.a.values[i],
                                            labOriginal.b.values[i])
            let resultLab = SIMD3<Float>(labCandidate.l.values[i],
                                         labCandidate.a.values[i],
                                         labCandidate.b.values[i])
            deltaE.values[i] = PixelKit.deltaE2000(referenceLab, resultLab)
            deltaL.values[i] = abs(resultLab.x - referenceLab.x)
        }
        let meanShift = Double(PixelKit.mean(deltaL, mask: selected))
        let pixelP95 = Double(PixelKit.percentile(deltaE, mask: selected, 95))
        return (medianDE,
                meanShift.isFinite ? meanShift : 0.0,
                pixelP95.isFinite ? pixelP95 : 0.0)
    }

    // MARK: - Clipping

    /// Fraction of pixels whose luma*255 is < 3 or > 252 (pipeline.py::clipped_fraction).
    func clippedFraction(_ image: RGBAImage, mask: FloatPlane?) -> Double {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, image.bytes.count >= width * height * 4 else { return 0.0 }
        let aligned = mask.flatMap { nearestResample($0, width: width, height: height) }

        var hits = 0
        var maskedHits = 0
        var maskedTotal = 0
        for i in 0..<(width * height) {
            let offset = i * 4
            let luma = PixelKit.luma(r: Float(image.bytes[offset]) / 255.0,
                                     g: Float(image.bytes[offset + 1]) / 255.0,
                                     b: Float(image.bytes[offset + 2]) / 255.0) * 255.0
            let clipped = luma < 3.0 || luma > 252.0
            if clipped { hits += 1 }
            if let aligned = aligned, aligned.values[i] > 0.5 {
                maskedTotal += 1
                if clipped { maskedHits += 1 }
            }
        }
        if maskedTotal > 0 { return Double(maskedHits) / Double(maskedTotal) }
        return Double(hits) / Double(width * height)
    }

    // MARK: - Seam

    /// Gradient-magnitude ratio along the skin-mask boundary (1.0 = seamless).
    ///
    /// Only the interior boundary is measured (an inset of 2 % of the short edge is
    /// ignored) and the median of the per-pixel ratio is used, so a handful of
    /// high-contrast boundary pixels (lash line, lip edge) cannot dominate.
    func seamRatio(original: RGBAImage, candidate: RGBAImage, mask: FloatPlane) -> Double {
        let width = mask.width
        let height = mask.height
        guard width > 1, height > 1,
              original.width == width, original.height == height,
              candidate.width == width, candidate.height == height,
              mask.values.count >= width * height,
              original.bytes.count >= width * height * 4,
              candidate.bytes.count >= width * height * 4 else { return 1.0 }

        let inset = max(2, Int((Double(min(width, height)) * 0.02).rounded()))
        guard width - 2 * inset > 0, height - 2 * inset > 0 else { return 1.0 }

        var interior = FloatPlane(width: width, height: height, value: 0)
        for y in inset..<(height - inset) {
            let row = y * width
            for x in inset..<(width - inset) { interior.values[row + x] = 1 }
        }

        let softMask = PixelKit.gaussianBlur(mask, sigma: 2.0)
        let maskGradientX = gradientX(softMask)
        let maskGradientY = gradientY(softMask)
        var edge = FloatPlane(width: width, height: height, value: 0)
        for i in 0..<(width * height) {
            let magnitude = abs(maskGradientX.values[i]) + abs(maskGradientY.values[i])
            edge.values[i] = magnitude * interior.values[i]
        }

        let cutoff = PixelKit.percentile(edge, mask: interior, 99.3)
        let threshold = max(Float(1e-3), cutoff.isFinite ? cutoff : Float(1e-3))
        var band = FloatPlane(width: width, height: height, value: 0)
        var bandCount = 0
        for i in 0..<(width * height) where edge.values[i] > threshold {
            band.values[i] = 1
            bandCount += 1
        }
        guard bandCount >= 20 else { return 1.0 }

        let referenceLuma = PixelKit.gaussianBlur(lumaPlane(original), sigma: 1.0)
        let resultLuma = PixelKit.gaussianBlur(lumaPlane(candidate), sigma: 1.0)
        let referenceX = gradientX(referenceLuma)
        let referenceY = gradientY(referenceLuma)
        let resultX = gradientX(resultLuma)
        let resultY = gradientY(resultLuma)

        var ratios = FloatPlane(width: width, height: height, value: 0)
        for i in 0..<(width * height) where band.values[i] > 0.5 {
            let referenceDX = referenceX.values[i]
            let referenceDY = referenceY.values[i]
            let resultDX = resultX.values[i]
            let resultDY = resultY.values[i]
            let referenceMagnitude = (referenceDX * referenceDX + referenceDY * referenceDY).squareRoot()
            let resultMagnitude = (resultDX * resultDX + resultDY * resultDY).squareRoot()
            ratios.values[i] = resultMagnitude / max(referenceMagnitude, 1e-4)
        }
        let medianRate = PixelKit.median(ratios, mask: band)
        return medianRate.isFinite ? Double(medianRate) : 1.0
    }

    // MARK: - SSIM

    /// Standard SSIM on luma with a Gaussian window (sigma 1.5), C1 = 0.01^2, C2 = 0.03^2.
    func ssim(original: RGBAImage, candidate: RGBAImage) -> Double {
        let width = original.width
        let height = original.height
        guard width > 0, height > 0,
              candidate.width == width, candidate.height == height,
              original.bytes.count >= width * height * 4,
              candidate.bytes.count >= width * height * 4 else { return 0.0 }

        let reference = lumaPlane(original)
        let result = lumaPlane(candidate)
        let c1: Float = 0.01 * 0.01
        let c2: Float = 0.03 * 0.03

        let meanReference = PixelKit.gaussianBlur(reference, sigma: 1.5)
        let meanResult = PixelKit.gaussianBlur(result, sigma: 1.5)
        let referenceSquare = zipMap(reference, reference, { $0 * $1 })
        let resultSquare = zipMap(result, result, { $0 * $1 })
        let product = zipMap(reference, result, { $0 * $1 })
        let blurredReferenceSquare = PixelKit.gaussianBlur(referenceSquare, sigma: 1.5)
        let blurredResultSquare = PixelKit.gaussianBlur(resultSquare, sigma: 1.5)
        let blurredProduct = PixelKit.gaussianBlur(product, sigma: 1.5)
        let meanReferenceSquare = zipMap(meanReference, meanReference, { $0 * $1 })
        let meanResultSquare = zipMap(meanResult, meanResult, { $0 * $1 })
        let meanProduct = zipMap(meanReference, meanResult, { $0 * $1 })
        let varianceReference = zipMap(blurredReferenceSquare, meanReferenceSquare, { $0 - $1 })
        let varianceResult = zipMap(blurredResultSquare, meanResultSquare, { $0 - $1 })
        let covariance = zipMap(blurredProduct, meanProduct, { $0 - $1 })

        let count = min(min(meanReference.values.count, meanResult.values.count),
                        min(varianceReference.values.count,
                            min(varianceResult.values.count, covariance.values.count)))
        guard count > 0 else { return 0.0 }
        var total = 0.0
        for i in 0..<count {
            let muA = meanReference.values[i]
            let muB = meanResult.values[i]
            let numerator = (2 * muA * muB + c1) * (2 * covariance.values[i] + c2)
            let varianceSum = varianceReference.values[i] + varianceResult.values[i] + c2
            let denominator = (muA * muA + muB * muB + c1) * varianceSum
            total += Double(numerator / max(denominator, 1e-9))
        }
        return total / Double(count)
    }

    // MARK: - Proxy preparation

    /// Tone-aligns the reference: per-channel white balance, then exposure (both clamped).
    private func toneAligned(_ image: RGBAImage, whiteBalance: SIMD3<Double>,
                             exposureEV: Double) -> RGBAImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, image.bytes.count >= width * height * 4 else { return image }
        let gainR = Float(min(max(whiteBalance.x.isFinite ? whiteBalance.x : 1.0, 0.0), 4.0))
        let gainG = Float(min(max(whiteBalance.y.isFinite ? whiteBalance.y : 1.0, 0.0), 4.0))
        let gainB = Float(min(max(whiteBalance.z.isFinite ? whiteBalance.z : 1.0, 0.0), 4.0))
        let ev = min(max(exposureEV.isFinite ? exposureEV : 0.0, -8.0), 8.0)
        let exposure = Float(exp2(ev))

        var aligned = image
        for i in 0..<(width * height) {
            let offset = i * 4
            aligned.bytes[offset] = clampByte(Float(image.bytes[offset]) / 255.0 * gainR * exposure)
            aligned.bytes[offset + 1] = clampByte(Float(image.bytes[offset + 1]) / 255.0 * gainG * exposure)
            aligned.bytes[offset + 2] = clampByte(Float(image.bytes[offset + 2]) / 255.0 * gainB * exposure)
        }
        return aligned
    }

    /// Renders the skin mask at proxy resolution; a missing mask means "whole frame is skin".
    private func skinPlane(_ maskImage: CIImage?, width: Int, height: Int,
                           context: CIContext) -> FloatPlane {
        guard let maskImage = maskImage else { return FloatPlane(width: width, height: height, value: 1) }
        guard let rendered = PixelKit.renderRGBA8(maskImage, width: width, height: height,
                                                  context: context) else {
            return FloatPlane(width: width, height: height, value: 1)
        }
        let plane = lumaPlane(rendered)
        if plane.width == width, plane.height == height { return plane }
        if let resampled = nearestResample(plane, width: width, height: height) { return resampled }
        return FloatPlane(width: width, height: height, value: 1)
    }

    // MARK: - Plane helpers

    private func lumaPlane(_ image: RGBAImage) -> FloatPlane {
        let width = max(0, image.width)
        let height = max(0, image.height)
        var plane = FloatPlane(width: width, height: height, value: 0)
        guard width > 0, height > 0, image.bytes.count >= width * height * 4 else { return plane }
        for i in 0..<(width * height) {
            let offset = i * 4
            plane.values[i] = PixelKit.luma(r: Float(image.bytes[offset]) / 255.0,
                                            g: Float(image.bytes[offset + 1]) / 255.0,
                                            b: Float(image.bytes[offset + 2]) / 255.0)
        }
        return plane
    }

    /// Nearest-neighbour resample, used for masks whose resolution differs from the proxy.
    private func nearestResample(_ plane: FloatPlane, width: Int, height: Int) -> FloatPlane? {
        guard width > 0, height > 0, plane.width > 0, plane.height > 0,
              plane.values.count >= plane.width * plane.height else { return nil }
        if plane.width == width, plane.height == height { return plane }
        var out = FloatPlane(width: width, height: height, value: 0)
        guard out.values.count >= width * height else { return nil }
        for y in 0..<height {
            let sourceY = min(plane.height - 1,
                              max(0, Int((Double(y) + 0.5) * Double(plane.height) / Double(height))))
            let sourceRow = sourceY * plane.width
            let targetRow = y * width
            for x in 0..<width {
                let sourceX = min(plane.width - 1,
                                  max(0, Int((Double(x) + 0.5) * Double(plane.width) / Double(width))))
                out.values[targetRow + x] = plane.values[sourceRow + sourceX]
            }
        }
        return out
    }

    private func binarize(_ plane: FloatPlane, threshold: Float) -> FloatPlane {
        var out = FloatPlane(width: plane.width, height: plane.height, value: 0)
        let count = min(plane.values.count, out.values.count)
        guard count > 0 else { return out }
        for i in 0..<count { out.values[i] = plane.values[i] > threshold ? 1 : 0 }
        return out
    }

    private func countAbove(_ plane: FloatPlane, threshold: Float) -> Int {
        var count = 0
        for value in plane.values where value > threshold { count += 1 }
        return count
    }

    private func selectedCount(_ mask: FloatPlane) -> Int {
        countAbove(mask, threshold: 0.5)
    }

    /// Element-wise combination; the result is sized like `a`.
    private func zipMap(_ a: FloatPlane, _ b: FloatPlane,
                        _ transform: (Float, Float) -> Float) -> FloatPlane {
        var out = FloatPlane(width: a.width, height: a.height, value: 0)
        let count = min(min(a.values.count, b.values.count), out.values.count)
        guard count > 0 else { return out }
        for i in 0..<count { out.values[i] = transform(a.values[i], b.values[i]) }
        return out
    }

    /// Central difference along x, first-order differences on the borders (numpy.gradient).
    private func gradientX(_ plane: FloatPlane) -> FloatPlane {
        let width = plane.width
        let height = plane.height
        var out = FloatPlane(width: width, height: height, value: 0)
        guard width > 1, height > 0,
              plane.values.count >= width * height, out.values.count >= width * height else { return out }
        for y in 0..<height {
            let row = y * width
            out.values[row] = plane.values[row + 1] - plane.values[row]
            out.values[row + width - 1] = plane.values[row + width - 1] - plane.values[row + width - 2]
            if width > 2 {
                for x in 1..<(width - 1) {
                    out.values[row + x] = (plane.values[row + x + 1] - plane.values[row + x - 1]) * 0.5
                }
            }
        }
        return out
    }

    /// Central difference along y, first-order differences on the borders (numpy.gradient).
    private func gradientY(_ plane: FloatPlane) -> FloatPlane {
        let width = plane.width
        let height = plane.height
        var out = FloatPlane(width: width, height: height, value: 0)
        guard width > 0, height > 1,
              plane.values.count >= width * height, out.values.count >= width * height else { return out }
        let lastRowStart = (height - 1) * width
        let previousRowStart = (height - 2) * width
        for x in 0..<width {
            out.values[x] = plane.values[x + width] - plane.values[x]
            out.values[lastRowStart + x] = plane.values[lastRowStart + x] - plane.values[previousRowStart + x]
        }
        if height > 2 {
            for y in 1..<(height - 1) {
                let row = y * width
                let previousRow = row - width
                let nextRow = row + width
                for x in 0..<width {
                    out.values[row + x] = (plane.values[nextRow + x] - plane.values[previousRow + x]) * 0.5
                }
            }
        }
        return out
    }

    // MARK: - Numeric helpers

    private func clampByte(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, 0.0), 1.0) * 255.0 + 0.5
        return UInt8(clamped)
    }

    private func finite(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }
}
