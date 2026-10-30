import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Commercial retouch effect graph.
///
/// Every stage is a mask-limited, frequency-aware edit built from Core Image
/// built-ins only (no custom kernels), which keeps the pipeline GPU-backed and
/// avoids per-pixel CPU work at full resolution. The parameters and thresholds
/// are the ones validated by `tools/retouch_lab` against a commercial QC gate.
final class RetouchEngine {
    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// Normalised top-left rect -> pixel rect in Core Image (bottom-left) space.
    private func pixelRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width,
               y: (1.0 - rect.maxY) * size.height,
               width: rect.width * size.width,
               height: rect.height * size.height)
    }

    // MARK: - Blemish detection

    struct SpotDetection {
        let spots: [BlemishSpot]
        let proxy: RGBAImage?
    }

    /// Scale-normalised LoG (scale-space blob detection) gated by the skin mask.
    /// Each scale is normalised by its own robust MAD so a lighting gradient can
    /// never outvote a small pimple; the winning scale also gives the radius.
    func detectSpots(in image: CIImage, analysis: SkinAnalysis, parameters: RetouchParameters) -> SpotDetection {
        guard let proxy = PixelKit.renderRGBA8(image, maxEdge: RetouchAnalyzer.detectionEdge, context: context) else {
            return SpotDetection(spots: [], proxy: nil)
        }
        let w = proxy.width, h = proxy.height
        let luma = PixelKit.luma(proxy)
        let labA = PixelKit.lab(proxy).a
        let skin = maskPlane(analysis.skinMask, width: w, height: h)
        let feature = maskPlane(analysis.featureMask, width: w, height: h)
        let faceWidthPx = Double(analysis.geometry.width) * Double(w)
        guard faceWidthPx > 8 else { return SpotDetection(spots: [], proxy: proxy) }

        // gradient gate keeps features and edges out of the candidate set
        let smoothL = PixelKit.gaussianBlur(luma, sigma: 1.4)
        var grad = FloatPlane(width: w, height: h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let gx = smoothL[x + 1, y] - smoothL[x - 1, y]
                let gy = smoothL[x, y + 1] - smoothL[x, y - 1]
                grad[x, y] = sqrt(gx * gx + gy * gy)
            }
        }
        var allowed = FloatPlane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let l = luma[x, y]
                allowed[x, y] = (skin[x, y] > 0.50 && feature[x, y] < 0.15 && l > 0.06 && l < 0.93 && grad[x, y] < 0.09) ? 1 : 0
            }
        }
        var allowedCount = 0
        for v in allowed.values where v > 0.5 { allowedCount += 1 }
        guard allowedCount > 200 else { return SpotDetection(spots: [], proxy: proxy) }

        let sigmas = [0.004, 0.006, 0.009].map { max(1.2, faceWidthPx * $0) }
        var resp = FloatPlane(width: w, height: h)
        var rad = FloatPlane(width: w, height: h)
        for sigma in sigmas {
            let g1 = PixelKit.gaussianBlur(luma, sigma: sigma * 0.7)
            let g2 = PixelKit.gaussianBlur(luma, sigma: sigma * 1.6)
            let a1 = PixelKit.gaussianBlur(labA, sigma: sigma * 0.7)
            let a2 = PixelKit.gaussianBlur(labA, sigma: sigma * 1.6)
            var scale = FloatPlane(width: w, height: h)
            for i in 0..<scale.values.count {
                scale.values[i] = abs(g1.values[i] - g2.values[i]) + 0.7 * abs(a1.values[i] - a2.values[i])
            }
            let smoothed = PixelKit.gaussianBlur(scale, sigma: sigma * 0.45)
            var samples: [Float] = []
            samples.reserveCapacity(allowedCount)
            for i in 0..<smoothed.values.count where allowed.values[i] > 0.5 { samples.append(smoothed.values[i]) }
            let smoothPlane = FloatPlane(width: samples.count, height: 1, values: samples)
            let mad = Double(PixelKit.median(smoothPlane, mask: nil)) * 1.4826 + 0.04
            for i in 0..<smoothed.values.count {
                let z = Float(Double(smoothed.values[i]) / max(mad, 1e-4))
                if z > resp.values[i] {
                    resp.values[i] = z
                    rad.values[i] = Float((2.0 as Double).squareRoot() * sigma)
                }
            }
        }
        for i in 0..<resp.values.count where allowed.values[i] < 0.5 { resp.values[i] = 0 }

        // local maximum suppression
        let threshold = Float(3.4 + 3.2 * (1.0 - parameters.blemishSensitivity))
        let nms = max(3, Int((faceWidthPx * 0.012).rounded()))
        let localMax = PixelKit.maximumFilter(resp, radius: nms)
        var spots: [BlemishSpot] = []
        var taken = FloatPlane(width: w, height: h)
        var order: [(Int, Int, Float)] = []
        for y in 0..<h {
            for x in 0..<w {
                let v = resp[x, y]
                if v > threshold && v >= localMax[x, y] * 0.995 && allowed[x, y] > 0.5 {
                    order.append((x, y, v))
                }
            }
        }
        order.sort { $0.2 > $1.2 }
        let surroundL = PixelKit.gaussianBlur(luma, sigma: max(5.0, faceWidthPx * 0.05))
        for (x, y, v) in order.prefix(8000) {
            let r = max(2.0, Double(rad[x, y]))
            let ri = Int(min(max(1, r.rounded()), 40))
            var occupied = false
            for yy in max(0, y - ri)...min(h - 1, y + ri) {
                if occupied { break }
                for xx in max(0, x - ri)...min(w - 1, x + ri) where taken[xx, yy] > 0.5 {
                    occupied = true; break
                }
            }
            if occupied { continue }
            let rr = max(3, Int((r * 2.2).rounded()))
            let y0 = max(0, y - rr), y1 = min(h, y + rr + 1)
            let x0 = max(0, x - rr), x1 = min(w, x + rr + 1)
            guard y1 - y0 > 4, x1 - x0 > 4 else { continue }
            var innerL: Float = 0, outerL: Float = 0, innerA: Float = 0, outerA: Float = 0
            var innerN: Float = 0, outerN: Float = 0
            for yy in y0..<y1 {
                for xx in x0..<x1 {
                    let d = hypot(Double(xx - x), Double(yy - y))
                    if d <= max(1.5, r * 0.7) {
                        innerL += luma[xx, yy]; innerA += labA[xx, yy]; innerN += 1
                    } else if d > r * 1.6 && d <= Double(rr) {
                        outerL += luma[xx, yy]; outerA += labA[xx, yy]; outerN += 1
                    }
                }
            }
            guard innerN > 3, outerN > 7 else { continue }
            innerL /= innerN; innerA /= innerN; outerL /= outerN; outerA /= outerN
            let contrastL = outerL - innerL
            let contrastA = innerA - outerA
            if contrastL < 0.004 && contrastA < 1.0 { continue }
            let de = abs(contrastL) * 60 + abs(contrastA)
            let conf = min(1, Double(v) / (Double(threshold) * 2.0)) * 0.55 + min(1, Double(de) / 9.0) * 0.45
            guard conf >= 0.10 else { continue }
            let nx = CGFloat(x) / CGFloat(w)
            let ny = CGFloat(y) / CGFloat(h)
            spots.append(BlemishSpot(center: CGPoint(x: nx, y: ny),
                                     radius: CGFloat(r / Double(max(w, h))),
                                     score: conf,
                                     kind: contrastA >= 1.0 ? "acne" : "shadow"))
            for yy in max(0, y - ri)...min(h - 1, y + ri) {
                for xx in max(0, x - ri)...min(w - 1, x + ri) { taken[xx, yy] = 1 }
            }
            if spots.count >= RetouchAnalyzer.maxSpots { break }
        }
        _ = surroundL
        // Learned decision stage (V18): classical LoG proposes candidates, the
        // trained scorer decides which ones are real blemishes vs freckles,
        // pores, lashes or speculars. Falls back to the classical score when the
        // proxy/features are unavailable.
        let rescored = BlemishModelBridge.rescore(spots: spots, proxy: proxy, faceWidthPx: faceWidthPx)
        return SpotDetection(spots: rescored.isEmpty ? spots : rescored, proxy: proxy)
    }

    /// Renders a luminance mask into a FloatPlane at the detector resolution.
    private func maskPlane(_ mask: CIImage, width: Int, height: Int) -> FloatPlane {
        guard let rgba = PixelKit.renderRGBA8(mask, width: width, height: height, context: context) else {
            return FloatPlane(width: width, height: height)
        }
        var plane = FloatPlane(width: width, height: height)
        for i in 0..<(width * height) {
            plane.values[i] = Float(rgba.bytes[i * 4]) / 255.0
        }
        return plane
    }

    // MARK: - Healing

    /// Exemplar patch transplant. A clean source patch is searched in an annulus
    /// of 1.4-4x the spot radius (SSD on the blurred Lab proxy plus mean chroma
    /// match), colour matched in luminance and composited with a feathered mask.
    func heal(_ image: CIImage, spots: [BlemishSpot], proxy: RGBAImage?, parameters: RetouchParameters) -> CIImage {
        guard !spots.isEmpty, let proxy else { return image }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        let w = CGFloat(proxy.width), h = CGFloat(proxy.height)
        let lab = PixelKit.lab(proxy)
        let labBlur = PixelKit.gaussianBlur(lab.l, sigma: 1.6)
        let aBlur = PixelKit.gaussianBlur(lab.a, sigma: 1.6)
        var out = image
        for spot in spots.prefix(RetouchAnalyzer.maxSpots) {
            let px = Int((spot.center.x * w).rounded()), py = Int((spot.center.y * h).rounded())
            let radProxy = max(2, Int((Double(spot.radius) * Double(max(w, h))).rounded()))
            let R = max(3, Int((Double(radProxy) * 1.7).rounded()))
            guard px > R, py > R, px + R < proxy.width, py + R < proxy.height else { continue }
            let step = max(1, Int((Double(radProxy) * 0.55).rounded()))
            var bestCost = Float.greatestFiniteMagnitude
            var bestDX = radProxy * 3, bestDY = 0
            var bestToneDelta: Float = 0
            for ring in [1.4, 2.4, 3.6] {
                let radius = Double(radProxy) * ring
                let steps = max(12, Int(2 * Double.pi * radius / Double(step)))
                for k in 0..<steps {
                    let theta = 2 * Double.pi * Double(k) / Double(steps)
                    let dx = Int((cos(theta) * radius).rounded())
                    let dy = Int((sin(theta) * radius).rounded())
                    let sx = px + dx, sy = py + dy
                    guard sx - R >= 0, sy - R >= 0, sx + R < proxy.width, sy + R < proxy.height else { continue }
                    var cost: Float = 0
                    var tSum: Float = 0, sSum: Float = 0
                    var samples = 0
                    let grid = max(1, R / 4)
                    var gy = -R
                    while gy <= R {
                        var gx = -R
                        while gx <= R {
                            let t = labBlur[px + gx, py + gy]
                            let s = labBlur[sx + gx, sy + gy]
                            let d = t - s
                            cost += d * d
                            tSum += lab.l[px + gx, py + gy]
                            sSum += lab.l[sx + gx, sy + gy]
                            samples += 1
                            gx += grid
                        }
                        gy += grid
                    }
                    guard samples > 0 else { continue }
                    cost /= Float(samples)
                    let tone = abs(tSum - sSum) / Float(samples)
                    cost += tone * 12
                    if cost < bestCost { bestCost = cost; bestDX = dx; bestDY = dy; bestToneDelta = (tSum - sSum) / Float(samples) }
                }
            }
            let scale = longEdge / CGFloat(max(w, h))
            let pixelR = CGFloat(radProxy) * scale * 1.7
            // geometry is normalised top-left/y-down; Core Image is bottom-left/y-up
            let cx = spot.center.x * extent.width + extent.minX
            let cy = (1.0 - spot.center.y) * extent.height + extent.minY
            let dx = CGFloat(bestDX) * scale
            let dy = CGFloat(bestDY) * scale
            let target = CGRect(x: cx - pixelR, y: cy - pixelR, width: pixelR * 2, height: pixelR * 2)
            let source = target.offsetBy(dx: dx, dy: dy).intersection(extent)
            guard !source.isNull, source.width > 2, source.height > 2 else { continue }
            var patch = out.cropped(to: source).transformed(by: CGAffineTransform(translationX: target.minX - source.minX,
                                                                                 y: target.minY - source.minY))
            // luminance match keeps the patch inside the local exposure
            let controls = CIFilter.colorControls()
            controls.inputImage = patch
            controls.brightness = Float(bestToneDelta / 100.0 * 0.6)
            controls.contrast = 1.0
            controls.saturation = 1.0
            patch = (controls.outputImage ?? patch).cropped(to: target)
            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: target.midX, y: target.midY)
            gradient.radius0 = Float(pixelR * 0.45)
            gradient.radius1 = Float(pixelR)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let mask = gradient.outputImage?.cropped(to: target) else { continue }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = patch
            blend.backgroundImage = out
            blend.maskImage = mask
            if let composited = blend.outputImage?.cropped(to: extent) { out = composited }
        }
        return out
    }

    // MARK: - Skin

    /// Frequency separation: low frequencies are blended in under the skin mask
    /// while the high band is preserved, then chroma is evened out with a
    /// colour-only blend (luma taken from the original, so pores survive).
    func smoothSkin(_ image: CIImage, analysis: SkinAnalysis, parameters: RetouchParameters) -> CIImage {
        let extent = image.extent
        let low = PixelKit.gaussian(image, radius: parameters.smoothRadius)
        let soften = min(max(parameters.smoothAmount * (1.0 - parameters.textureGain) * 5.0, 0), 1)
        var out = image
        if soften > 0.001 {
            let mask = PixelKit.scaledMask(soften, of: analysis.skinMask, extent: extent)
            out = PixelKit.blend(low.cropped(to: extent), over: out, mask: mask)
        }
        // chroma evenness: colour of a large-radius blur, luma of the original
        let blurred = PixelKit.gaussian(out, radius: parameters.colorEvenRadius)
        let colorOnly = CIFilter.colorBlendMode()
        colorOnly.inputImage = blurred
        colorOnly.backgroundImage = out
        if let chroma = colorOnly.outputImage?.cropped(to: extent) {
            let mask = PixelKit.scaledMask(parameters.colorEvenAmount, of: analysis.skinMask, extent: extent)
            out = PixelKit.blend(chroma, over: out, mask: mask)
        }
        return out.cropped(to: extent)
    }

    /// Mid-frequency luminance shaping (dodge & burn), applied as a luminosity
    /// blend so skin chroma cannot drift.
    func dodgeAndBurn(_ image: CIImage, analysis: SkinAnalysis, parameters: RetouchParameters) -> CIImage {
        let extent = image.extent
        guard parameters.dodgeBurnAmount > 0.01 else { return image }
        let base = PixelKit.gaussian(image, radius: parameters.dodgeBurnRadius)
        let shaped = PixelKit.blend(base, over: image,
                                    mask: PixelKit.scaledMask(min(parameters.dodgeBurnAmount * 0.5, 0.5),
                                                              of: analysis.skinMask, extent: extent))
        let luminosity = CIFilter.luminosityBlendMode()
        luminosity.inputImage = shaped
        luminosity.backgroundImage = image
        return (luminosity.outputImage ?? image).cropped(to: extent)
    }

    // MARK: - Facial details

    func eyes(_ image: CIImage, analysis: SkinAnalysis, parameters: RetouchParameters) -> CIImage {
        guard parameters.eyeAmount > 0.01 else { return image }
        let extent = image.extent
        let (left, right) = analysis.geometry.derivedEyes()
        var out = image
        for eye in [left, right] {
            let rect = pixelRect(eye.insetBy(dx: -eye.width * 0.25, dy: -eye.height * 0.35), in: extent.size)
            guard rect.width > 4, rect.height > 4 else { continue }
            let cropped = out.cropped(to: rect)
            let controls = CIFilter.colorControls()
            controls.inputImage = cropped
            controls.brightness = Float(0.06 * parameters.eyeAmount)
            controls.contrast = 1.0 + Float(0.10 * parameters.eyeAmount)
            controls.saturation = 1.0 - Float(0.12 * parameters.eyeAmount)
            guard let adjusted = controls.outputImage else { continue }
            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: rect.midX, y: rect.midY)
            gradient.radius0 = Float(min(rect.width, rect.height) * 0.30)
            gradient.radius1 = Float(min(rect.width, rect.height) * 0.55)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let mask = gradient.outputImage?.cropped(to: rect) else { continue }
            out = PixelKit.blend(adjusted, over: out, mask: mask)
        }
        return out.cropped(to: extent)
    }

    func underEye(_ image: CIImage, analysis: SkinAnalysis, parameters: RetouchParameters) -> CIImage {
        guard parameters.underEyeAmount > 0.01 else { return image }
        let extent = image.extent
        let (left, right) = analysis.geometry.derivedEyes()
        var out = image
        for eye in [left, right] {
            let rect = pixelRect(
                CGRect(x: eye.midX - eye.width * 0.55, y: eye.maxY - eye.height * 0.15,
                       width: eye.width * 1.1, height: eye.height * 0.95), in: extent.size)
            guard rect.width > 4, rect.height > 4 else { continue }
            let cropped = out.cropped(to: rect)
            let controls = CIFilter.colorControls()
            controls.inputImage = cropped
            controls.brightness = Float(0.05 * parameters.underEyeAmount)
            controls.contrast = 1.0
            controls.saturation = 1.0 - Float(0.10 * parameters.underEyeAmount)
            guard let adjusted = controls.outputImage else { continue }
            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: rect.midX, y: rect.midY)
            gradient.radius0 = Float(min(rect.width, rect.height) * 0.35)
            gradient.radius1 = Float(min(rect.width, rect.height) * 0.62)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let mask = gradient.outputImage?.cropped(to: rect) else { continue }
            out = PixelKit.blend(adjusted, over: out, mask: mask)
        }
        return out.cropped(to: extent)
    }

    func teeth(_ image: CIImage, analysis: SkinAnalysis, parameters: RetouchParameters) -> CIImage {
        guard parameters.teethAmount > 0.01 else { return image }
        let lips = analysis.geometry.derivedLips()
        let rect = pixelRect(
            CGRect(x: lips.midX - lips.width * 0.42, y: lips.midY - lips.height * 0.30,
                   width: lips.width * 0.84, height: lips.height * 0.60), in: image.extent.size)
        guard rect.width > 6, rect.height > 4 else { return image }
        let cropped = image.cropped(to: rect)
        let controls = CIFilter.colorControls()
        controls.inputImage = cropped
        controls.brightness = Float(0.04 * parameters.teethAmount)
        controls.contrast = 1.0
        controls.saturation = 1.0 - Float(0.22 * parameters.teethAmount)
        guard let adjusted = controls.outputImage else { return image }
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: rect.midX, y: rect.midY)
        gradient.radius0 = Float(min(rect.width, rect.height) * 0.25)
        gradient.radius1 = Float(min(rect.width, rect.height) * 0.55)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let mask = gradient.outputImage?.cropped(to: rect) else { return image }
        return PixelKit.blend(adjusted, over: image, mask: mask).cropped(to: image.extent)
    }

    func lips(_ image: CIImage, analysis: SkinAnalysis, parameters: RetouchParameters) -> CIImage {
        guard parameters.lipAmount > 0.01 else { return image }
        let lips = analysis.geometry.derivedLips()
        let rect = pixelRect(lips.insetBy(dx: -lips.width * 0.06, dy: -lips.height * 0.10), in: image.extent.size)
        guard rect.width > 6, rect.height > 4 else { return image }
        let cropped = image.cropped(to: rect)
        let controls = CIFilter.colorControls()
        controls.inputImage = cropped
        controls.brightness = 0
        controls.contrast = 1.0
        controls.saturation = 1.0 + Float(0.16 * parameters.lipAmount)
        guard let adjusted = controls.outputImage else { return image }
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: rect.midX, y: rect.midY)
        gradient.radius0 = Float(min(rect.width, rect.height) * 0.30)
        gradient.radius1 = Float(min(rect.width, rect.height) * 0.60)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let mask = gradient.outputImage?.cropped(to: rect) else { return image }
        return PixelKit.blend(adjusted, over: image, mask: mask).cropped(to: image.extent)
    }

    // MARK: - Tone

    /// White balance + exposure + highlight shoulder. Returns the EV that was applied
    /// so the QC gate can tone-align the reference frame.
    func tone(_ image: CIImage, analysis: SkinAnalysis?, parameters: RetouchParameters,
              applyWhiteBalance: Bool = true, skipExposure: Bool = false) -> (CIImage, Double) {
        let extent = image.extent
        var out = image
        if applyWhiteBalance, let wb = analysis?.whiteBalance {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = out
            matrix.rVector = CIVector(x: CGFloat(wb.x), y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(wb.y), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(wb.z), w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            if let adjusted = matrix.outputImage { out = adjusted }
        }
        var ev = 0.0
        if !skipExposure, let exposure = analysis?.exposure, exposure > 0.01 {
            ev = min(parameters.maxExposureEV, max(-parameters.maxExposureEV,
                                                    log2(parameters.exposureTarget / exposure)))
            let adjust = CIFilter.exposureAdjust()
            adjust.inputImage = out
            adjust.ev = Float(ev)
            if let adjusted = adjust.outputImage { out = adjusted }
        }
        let shadow = CIFilter.highlightShadowAdjust()
        shadow.inputImage = out
        shadow.highlightAmount = Float(parameters.highlightRolloff)
        shadow.shadowAmount = Float(min(1.0, parameters.shadowLift * 2.4))
        if let adjusted = shadow.outputImage { out = adjusted }
        // gentle S-curve: contrast > 1 raises the shoulder, < 1 flattens it
        let c = min(max(parameters.contrast, 0.94), 1.14)
        let curve = CIFilter.toneCurve()
        curve.inputImage = out
        curve.point0 = CGPoint(x: 0.0, y: 0.0)
        curve.point1 = CGPoint(x: 0.25, y: max(0.0, 0.25 - (c - 1.0) * 0.22))
        curve.point2 = CGPoint(x: 0.5, y: 0.5)
        curve.point3 = CGPoint(x: 0.75, y: min(1.0, 0.75 + (c - 1.0) * 0.22))
        curve.point4 = CGPoint(x: 1.0, y: 1.0)
        if let adjusted = curve.outputImage { out = adjusted }
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = out
        vibrance.amount = Float(parameters.vibrance)
        if let adjusted = vibrance.outputImage { out = adjusted }
        return (out.cropped(to: extent), ev)
    }

    /// Normalises a frame onto the shoot anchor (white balance + exposure).
    /// Used by the batch runner so a delivered set shares one colour reference.
    func applyCorrection(_ image: CIImage, gains: SIMD3<Double>, ev: Double) -> CIImage {
        var out = image
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = out
        matrix.rVector = CIVector(x: CGFloat(gains.x), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(gains.y), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(gains.z), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        if let adjusted = matrix.outputImage { out = adjusted }
        if abs(ev) > 0.001 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = out
            exposure.ev = Float(ev)
            if let adjusted = exposure.outputImage { out = adjusted }
        }
        return out.cropped(to: image.extent)
    }

    // MARK: - Colour grade (3D LUT)

    func grade(_ image: CIImage, look: RetouchLook, parameters: RetouchParameters) -> CIImage {
        let size = 33
        guard let data = RetouchLUT.cubeData(look: look, size: size, strength: parameters.lutStrength) else { return image }
        let cube = CIFilter.colorCube()
        cube.inputImage = image
        cube.cubeDimension = Float(size)
        cube.cubeData = data
        return (cube.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: - Finishing

    func finish(_ image: CIImage, analysis: SkinAnalysis?, parameters: RetouchParameters) -> CIImage {
        let extent = image.extent
        var out = image
        // clarity: local contrast everywhere except skin
        if parameters.clarityAmount > 0.01 {
            let sharpened = CIFilter.unsharpMask()
            sharpened.inputImage = out
            sharpened.radius = Float(parameters.clarityRadius)
            sharpened.intensity = Float(parameters.clarityAmount)
            if let result = sharpened.outputImage, let skin = analysis?.skinMask {
                let invert = CIFilter.colorInvert()
                invert.inputImage = skin
                if let nonSkin = invert.outputImage {
                    out = PixelKit.blend(result.cropped(to: extent), over: out, mask: nonSkin.cropped(to: extent))
                }
            } else if let result = sharpened.outputImage { out = result }
        }
        // output sharpening: small radius, thresholded, kept off skin
        if parameters.sharpenAmount > 0.01 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = out
            sharpen.sharpness = Float(parameters.sharpenAmount)
            if let result = sharpen.outputImage, let skin = analysis?.skinMask {
                let invert = CIFilter.colorInvert()
                invert.inputImage = PixelKit.scaledMask(0.85, of: skin, extent: extent)
                if let nonSkin = invert.outputImage {
                    out = PixelKit.blend(result.cropped(to: extent), over: out, mask: nonSkin.cropped(to: extent))
                }
            } else if let result = sharpen.outputImage { out = result }
        }
        if parameters.vignette > 0.01 {
            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: extent.midX, y: extent.midY)
            gradient.radius0 = Float(min(extent.width, extent.height) * 0.55)
            gradient.radius1 = Float(max(extent.width, extent.height) * 0.78)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 1 - CGFloat(parameters.vignette), green: 1 - CGFloat(parameters.vignette),
                                      blue: 1 - CGFloat(parameters.vignette), alpha: 1)
            if let mask = gradient.outputImage?.cropped(to: extent) {
                out = out.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: out,
                                                                            kCIInputImageKey: mask])
            }
        }
        return out.cropped(to: extent)
    }
}

// MARK: - LUT generation

enum RetouchLUT {
    /// Builds CIColorCube data (RGBA float32, red fastest) for a look.
    /// Mirrors `pipeline.build_lut` in the Python reference lab.
    static func cubeData(look: RetouchLook, size: Int, strength: Double) -> Data? {
        guard size > 1 else { return nil }
        var values = [Float](repeating: 0, count: size * size * size * 4)
        let lift = look.lift, gamma = look.gamma, gain = look.gain
        let shadowTint = look.shadowTint, highlightTint = look.highlightTint
        var index = 0
        for bi in 0..<size {
            let b = Double(bi) / Double(size - 1)
            for gi in 0..<size {
                let g = Double(gi) / Double(size - 1)
                for ri in 0..<size {
                    let r = Double(ri) / Double(size - 1)
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let sh = min(max(1.0 - l / 0.5, 0), 1)
                    let hi = min(max((l - 0.5) / 0.5, 0), 1)
                    var rgb = SIMD3<Double>(r, g, b)
                    rgb += lift
                    rgb = SIMD3(pow(min(max(rgb.x, 0), 1), 1.0 / gamma.x),
                                pow(min(max(rgb.y, 0), 1), 1.0 / gamma.y),
                                pow(min(max(rgb.z, 0), 1), 1.0 / gamma.z))
                    rgb *= gain
                    rgb += shadowTint * sh + highlightTint * hi
                    rgb = SIMD3(min(max(rgb.x, 0), 1), min(max(rgb.y, 0), 1), min(max(rgb.z, 0), 1))
                    let mixed = SIMD3(r, g, b) * (1 - strength) + rgb * strength
                    values[index] = Float(mixed.x)
                    values[index + 1] = Float(mixed.y)
                    values[index + 2] = Float(mixed.z)
                    values[index + 3] = 1.0
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
