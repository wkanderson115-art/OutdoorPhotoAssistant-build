import Foundation
import UIKit
import CoreImage
import CoreGraphics

// MARK: - FloatPlane

/// A single-channel float plane, row-major, index = y * width + x, values 0...1.
/// Mirrors the float32 mask / channel arrays the numpy reference lab works with
/// (`tools/retouch_lab/ops.py`), so tuning numbers transfer 1:1.
struct FloatPlane {
    var width: Int
    var height: Int
    var values: [Float]

    init(width: Int, height: Int, value: Float = 0) {
        let w = max(0, width)
        let h = max(0, height)
        self.width = w
        self.height = h
        self.values = [Float](repeating: value, count: w * h)
    }

    /// Adopts an existing row-major buffer, padding or truncating it to width * height.
    init(width: Int, height: Int, values: [Float]) {
        let w = max(0, width)
        let h = max(0, height)
        let total = w * h
        self.width = w
        self.height = h
        if values.count == total {
            self.values = values
        } else if values.count > total {
            self.values = Array(values[0..<total])
        } else {
            var padded = values
            padded += [Float](repeating: 0, count: total - values.count)
            self.values = padded
        }
    }

    var count: Int { width * height }
    var isEmpty: Bool { width <= 0 || height <= 0 || values.isEmpty }

    /// Bounds-safe element access: reads outside the plane yield 0, writes are ignored.
    subscript(x: Int, y: Int) -> Float {
        get {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            let index = y * width + x
            guard index >= 0, index < values.count else { return 0 }
            return values[index]
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let index = y * width + x
            guard index >= 0, index < values.count else { return }
            values[index] = newValue
        }
    }
}

// MARK: - RGBAImage

/// Interleaved sRGB8 planes of a proxy image.
struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]     // RGBA, 4 bytes per pixel, sRGB gamma encoded

    init(width: Int, height: Int, bytes: [UInt8]) {
        let w = max(0, width)
        let h = max(0, height)
        let total = w * h * 4
        self.width = w
        self.height = h
        if bytes.count == total {
            self.bytes = bytes
        } else if bytes.count > total {
            self.bytes = Array(bytes[0..<total])
        } else {
            var padded = bytes
            padded += [UInt8](repeating: 0, count: total - bytes.count)
            self.bytes = padded
        }
    }

    var count: Int { width * height }
    var isEmpty: Bool { width <= 0 || height <= 0 || bytes.isEmpty }

    /// One pixel as gamma-encoded sRGB, 0...1. Out-of-range reads yield black.
    func rgb(x: Int, y: Int) -> SIMD3<Float> {
        let black = SIMD3<Float>(0, 0, 0)
        guard x >= 0, y >= 0, x < width, y < height else { return black }
        let index = (y * width + x) * 4
        guard index + 2 < bytes.count else { return black }
        let scale: Float = 1.0 / 255.0
        return SIMD3<Float>(Float(bytes[index]) * scale,
                            Float(bytes[index + 1]) * scale,
                            Float(bytes[index + 2]) * scale)
    }
}

// MARK: - PixelKit

/// CPU reference implementations of the low-level operations used by the retouch
/// engine. Everything is a faithful port of `tools/retouch_lab/ops.py`; the code
/// runs on proxies (long edge <= 2048 px) so plain `[Float]` loops are sufficient.
enum PixelKit {

    // MARK: - Constants (identical to ops.py)

    /// Rec.709 luma weights, applied to gamma-encoded sRGB (matches Core Image).
    private static let lumaR: Float = 0.2126
    private static let lumaG: Float = 0.7152
    private static let lumaB: Float = 0.0722

    /// sRGB transfer-function break points.
    private static let srgbLinearCut = 0.04045
    private static let srgbGammaCut = 0.0031308

    /// D65 reference white (ops.py `_WHITE`).
    private static let whiteX = 0.95047
    private static let whiteY = 1.00000
    private static let whiteZ = 1.08883

    /// CIE Lab constants (ops.py `eps` / `kappa` inside rgb_to_lab).
    private static let labEps = 216.0 / 24389.0
    private static let labKappa = 24389.0 / 27.0

    /// 25^7, the CIEDE2000 chroma constant.
    private static let pow25To7 = 6103515625.0

    /// sRGB (linear) -> XYZ, D65: ops.py `_M_RGB2XYZ`.
    private static let m00 = 0.4124564, m01 = 0.3575761, m02 = 0.1804375
    private static let m10 = 0.2126729, m11 = 0.7151522, m12 = 0.0721750
    private static let m20 = 0.0193339, m21 = 0.1191920, m22 = 0.9503041

    /// XYZ -> sRGB (linear): ops.py `_M_XYZ2RGB` = numpy inverse of the above.
    private static let n00 = 3.2404548360214087, n01 = -1.5371388501025751, n02 = -0.4985315468684810
    private static let n10 = -0.9692663898756538, n11 = 1.8760109288424911, n12 = 0.0415560823466735
    private static let n20 = 0.0556434196042136, n21 = -0.2040258542676981, n22 = 1.0572251624579293

    /// The reference uses 4096-entry, linearly interpolated LUTs for the transfer
    /// functions (`_LUT_N`); bulk conversions here use the same table so plane
    /// values agree with numpy to well below 1e-6.
    private static let lutSize = 4096

    private static let srgbToLinearLUT: [Float] = {
        let last = Double(PixelKit.lutSize - 1)
        var table = [Float](repeating: 0, count: PixelKit.lutSize)
        var i = 0
        while i < PixelKit.lutSize {
            let x = Double(i) / last
            let value = x <= PixelKit.srgbLinearCut ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            table[i] = Float(value)
            i += 1
        }
        return table
    }()

    // MARK: - Rendering

    /// Renders a proxy of `image` whose long edge is at most `maxEdge`, as sRGB8 RGBA.
    /// The caller passes an already orientation-normalised image; no EXIF handling here.
    static func renderRGBA8(_ image: CIImage, maxEdge: CGFloat, context: CIContext) -> RGBAImage? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull else { return nil }
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return nil }
        guard maxEdge.isFinite, maxEdge > 0 else { return nil }
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, maxEdge / longEdge)
        let target = pixelSize(of: extent, scale: scale)
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return renderRGBA8(scaled, width: target.width, height: target.height, context: context)
    }

    /// Renders `image` into exactly width x height sRGB8 RGBA bytes (premultiplied last,
    /// device RGB, high interpolation). Returns nil when the render cannot be performed.
    static func renderRGBA8(_ image: CIImage, width: Int, height: Int, context: CIContext) -> RGBAImage? {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        guard let cg = cgImage(image, context: context) else { return nil }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let ok = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let address = buffer.baseAddress,
                  let context2D = CGContext(data: address, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context2D.interpolationQuality = .high
            context2D.setBlendMode(.copy)
            context2D.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard ok else { return nil }
        return RGBAImage(width: width, height: height, bytes: bytes)
    }

    /// Snapshots the whole extent of a CIImage. Returns nil for empty / infinite images.
    static func cgImage(_ image: CIImage, context: CIContext) -> CGImage? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull else { return nil }
        guard extent.width.isFinite, extent.height.isFinite else { return nil }
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        return context.createCGImage(image, from: extent)
    }

    /// Luminance image of the plane mapped onto `extent` (8-bit grey, stretched).
    static func image(from plane: FloatPlane, extent: CGRect) -> CIImage {
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else {
            return emptyImage()
        }
        guard let cg = grayCGImage(from: plane) else { return constantMask(luma: 0, extent: extent) }
        let base = CIImage(cgImage: cg)
        let size = base.extent.size
        guard size.width > 0, size.height > 0 else { return constantMask(luma: 0, extent: extent) }
        let scaleX = extent.width / size.width
        let scaleY = extent.height / size.height
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return base.transformed(by: transform).cropped(to: extent)
    }

    /// Grey CIImage of the plane, extent (0, 0, width, height), no rescaling.
    static func colorImage(from plane: FloatPlane) -> CIImage {
        guard let cg = grayCGImage(from: plane) else { return emptyImage() }
        return CIImage(cgImage: cg)
    }

    /// Luminance mask of the plane scaled to `targetSize`, with a 2 px feather.
    static func maskImage(from plane: FloatPlane, targetSize: CGSize) -> CIImage {
        guard targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width >= 1, targetSize.height >= 1 else { return emptyImage() }
        let target = CGRect(origin: .zero, size: targetSize)
        guard let cg = grayCGImage(from: plane) else { return constantMask(luma: 0, extent: target) }
        let base = CIImage(cgImage: cg)
        let size = base.extent.size
        guard size.width > 0, size.height > 0 else { return constantMask(luma: 0, extent: target) }
        let scaleX = targetSize.width / size.width
        let scaleY = targetSize.height / size.height
        let scaled = base.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: target)
        return gaussian(scaled.clampedToExtent(), radius: 2).cropped(to: target)
    }

    // MARK: - Colour maths (inputs are gamma-encoded sRGB, 0...1)

    /// Rec.709 luma on gamma-encoded sRGB (ops.py `luma`).
    static func luma(r: Float, g: Float, b: Float) -> Float {
        return lumaR * r + lumaG * g + lumaB * b
    }

    /// sRGB electro-optical transfer function (exact piecewise form).
    static func srgbToLinear(_ v: Float) -> Float {
        let x = v.isFinite ? min(max(v, 0), 1) : 0
        let d = Double(x)
        if d <= srgbLinearCut { return Float(d / 12.92) }
        return Float(pow((d + 0.055) / 1.055, 2.4))
    }

    /// Inverse sRGB transfer function; input is clamped to 0...1 like the LUT does.
    static func linearToSrgb(_ v: Float) -> Float {
        let x = v.isFinite ? max(v, 0) : 0
        let d = Double(min(x, 1))
        if d <= srgbGammaCut { return Float(d * 12.92) }
        return Float(1.055 * pow(d, 1.0 / 2.4) - 0.055)
    }

    /// sRGB -> D65 CIELab (ops.py `rgb_to_lab`), same matrices and constants.
    static func rgbToLab(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        let lr = Double(srgbToLinear(r))
        let lg = Double(srgbToLinear(g))
        let lb = Double(srgbToLinear(b))
        let x = (m00 * lr + m01 * lg + m02 * lb) / whiteX
        let y = (m10 * lr + m11 * lg + m12 * lb) / whiteY
        let z = (m20 * lr + m21 * lg + m22 * lb) / whiteZ
        let fx = labForward(x)
        let fy = labForward(y)
        let fz = labForward(z)
        return SIMD3<Float>(Float(116.0 * fy - 16.0),
                            Float(500.0 * (fx - fy)),
                            Float(200.0 * (fy - fz)))
    }

    /// CIELab -> sRGB (ops.py `lab_to_rgb`); the result is clamped to 0...1.
    static func labToRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let L = Double(lab.x)
        let A = Double(lab.y)
        let B = Double(lab.z)
        let fy = (L + 16.0) / 116.0
        let fx = fy + A / 500.0
        let fz = fy - B / 200.0
        let fx3 = fx * fx * fx
        let fz3 = fz * fz * fz
        let xr = fx3 > labEps ? fx3 : (116.0 * fx - 16.0) / labKappa
        let yr = L > labKappa * labEps ? (fy * fy * fy) : L / labKappa
        let zr = fz3 > labEps ? fz3 : (116.0 * fz - 16.0) / labKappa
        let x = xr * whiteX
        let y = yr * whiteY
        let z = zr * whiteZ
        let lr = n00 * x + n01 * y + n02 * z
        let lg = n10 * x + n11 * y + n12 * z
        let lb = n20 * x + n21 * y + n22 * z
        return SIMD3<Float>(linearToSrgb(Float(lr)),
                            linearToSrgb(Float(lg)),
                            linearToSrgb(Float(lb)))
    }

    /// CIEDE2000 with kL = kC = kH = 1 (ops.py `delta_e_2000`), evaluated in Double.
    static func deltaE2000(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let l1 = Double(a.x), a1 = Double(a.y), b1 = Double(a.z)
        let l2 = Double(b.x), a2 = Double(b.y), b2 = Double(b.z)

        // Guard against a zero chroma vector so the hue angle stays well defined.
        let epsilon = 1e-6
        let c1 = (a1 * a1 + b1 * b1).squareRoot() + epsilon
        let c2 = (a2 * a2 + b2 * b2).squareRoot() + epsilon
        let cBar = (c1 + c2) / 2.0
        let cBar7 = pow(cBar, 7.0)
        let g = 0.5 * (1.0 - (cBar7 / (cBar7 + pow25To7)).squareRoot())
        let a1p = (1.0 + g) * a1
        let a2p = (1.0 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot() + epsilon
        let c2p = (a2p * a2p + b2 * b2).squareRoot() + epsilon

        var h1p = atan2Degrees(b1, a1p)
        var h2p = atan2Degrees(b2, a2p)
        if h1p < 0 { h1p += 360.0 }
        if h2p < 0 { h2p += 360.0 }

        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = h2p - h1p
        if dhp > 180.0 {
            dhp -= 360.0
        } else if dhp < -180.0 {
            dhp += 360.0
        }
        let dHp = 2.0 * (c1p * c2p).squareRoot() * sinDegrees(dhp / 2.0)

        let lBarP = (l1 + l2) / 2.0
        let cBarP = (c1p + c2p) / 2.0
        let hSum = h1p + h2p
        let hBarP: Double
        if abs(h1p - h2p) <= 180.0 {
            hBarP = hSum / 2.0
        } else if hSum < 360.0 {
            hBarP = (hSum + 360.0) / 2.0
        } else {
            hBarP = (hSum - 360.0) / 2.0
        }

        let t = 1.0 - 0.17 * cosDegrees(hBarP - 30.0)
            + 0.24 * cosDegrees(2.0 * hBarP)
            + 0.32 * cosDegrees(3.0 * hBarP + 6.0)
            - 0.20 * cosDegrees(4.0 * hBarP - 63.0)
        let dTheta = 30.0 * exp(-pow((hBarP - 275.0) / 25.0, 2.0))
        let cBarP7 = pow(cBarP, 7.0)
        let rc = 2.0 * (cBarP7 / (cBarP7 + pow25To7)).squareRoot()
        let deltaL = lBarP - 50.0
        let sL = 1.0 + (0.015 * deltaL * deltaL) / (20.0 + deltaL * deltaL).squareRoot()
        let sC = 1.0 + 0.045 * cBarP
        let sH = 1.0 + 0.015 * cBarP * t
        let rT = -sinDegrees(2.0 * dTheta) * rc

        let termL = dLp / sL
        let termC = dCp / sC
        let termH = dHp / sH
        let sum = termL * termL + termC * termC + termH * termH + rT * termC * termH
        return Float(sum > 0 ? sum.squareRoot() : 0)
    }

    // MARK: - Array filters (edge-clamped, separable)

    /// Separable box blur with edge-clamped borders and a (2r+1) normaliser.
    static func boxBlur(_ plane: FloatPlane, radius: Int) -> FloatPlane {
        guard radius > 0, plane.width > 0, plane.height > 0,
              plane.values.count >= plane.count else { return plane }
        let horizontal = boxPass(plane, radius: radius, horizontal: true)
        return boxPass(horizontal, radius: radius, horizontal: false)
    }

    /// Gaussian approximation by repeated box filters (central limit theorem),
    /// radius derived from sigma exactly as ops.py `gaussian_blur`.
    static func gaussianBlur(_ plane: FloatPlane, sigma: Double, passes: Int = 2) -> FloatPlane {
        guard sigma.isFinite, sigma > 0.3, plane.width > 0, plane.height > 0,
              plane.values.count >= plane.count else { return plane }
        let passCount = max(1, passes)
        // sigma^2 = passes * ((2r + 1)^2 - 1) / 12
        let target = sigma * sigma * 12.0 / Double(passCount) + 1.0
        // .toNearestOrEven matches Python's round() used by ops.py.
        let radiusValue = ((target.squareRoot() - 1.0) / 2.0).rounded(.toNearestOrEven)
        let radius = max(1, Int(min(radiusValue, 4096)))
        var output = plane
        var pass = 0
        while pass < passCount {
            output = boxBlur(output, radius: radius)
            pass += 1
        }
        return output
    }

    /// Grey-guide guided filter (He et al. 2010), identical to ops.py `guided_filter`:
    /// a = cov(guide, src) / (var(guide) + eps), b = mean(src) - a * mean(guide),
    /// output = mean(a) * guide + mean(b).
    static func guidedFilter(guide: FloatPlane, src: FloatPlane, radius: Int, eps: Double) -> FloatPlane {
        guard guide.width == src.width, guide.height == src.height,
              guide.width > 0, guide.height > 0, radius > 0,
              guide.values.count >= guide.count, src.values.count >= src.count else { return src }
        let w = guide.width
        let h = guide.height
        let total = w * h

        var guideSrc = [Float](repeating: 0, count: total)
        var guideGuide = [Float](repeating: 0, count: total)
        guide.values.withUnsafeBufferPointer { guideBuffer in
            src.values.withUnsafeBufferPointer { srcBuffer in
                guideSrc.withUnsafeMutableBufferPointer { gsBuffer in
                    guideGuide.withUnsafeMutableBufferPointer { ggBuffer in
                        var i = 0
                        while i < total {
                            let gv = guideBuffer[i]
                            let pv = srcBuffer[i]
                            gsBuffer[i] = gv * pv
                            ggBuffer[i] = gv * gv
                            i += 1
                        }
                    }
                }
            }
        }

        let meanGuide = boxBlur(guide, radius: radius)
        let meanSrc = boxBlur(src, radius: radius)
        let corrGuideSrc = boxBlur(FloatPlane(width: w, height: h, values: guideSrc), radius: radius)
        let corrGuideGuide = boxBlur(FloatPlane(width: w, height: h, values: guideGuide), radius: radius)

        // A zero/negative eps would divide by a vanishing variance; clamp to the
        // reference EPS so float cancellation in var/cov cannot flip the sign.
        let epsilon = Float(max(eps.isFinite ? eps : 1e-6, 1e-6))
        var aValues = [Float](repeating: 0, count: total)
        var bValues = [Float](repeating: 0, count: total)

        meanGuide.values.withUnsafeBufferPointer { meanG in
            meanSrc.values.withUnsafeBufferPointer { meanP in
                corrGuideSrc.values.withUnsafeBufferPointer { corrGP in
                    corrGuideGuide.values.withUnsafeBufferPointer { corrGG in
                        aValues.withUnsafeMutableBufferPointer { aBuffer in
                            bValues.withUnsafeMutableBufferPointer { bBuffer in
                                var i = 0
                                while i < total {
                                    let mg = meanG[i]
                                    let mp = meanP[i]
                                    let varG = corrGG[i] - mg * mg
                                    let covGP = corrGP[i] - mg * mp
                                    let denominator = varG + epsilon
                                    let safe = denominator > 1e-6 ? denominator : 1e-6
                                    let av = covGP / safe
                                    aBuffer[i] = av
                                    bBuffer[i] = mp - av * mg
                                    i += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        let meanA = boxBlur(FloatPlane(width: w, height: h, values: aValues), radius: radius)
        let meanB = boxBlur(FloatPlane(width: w, height: h, values: bValues), radius: radius)
        var output = FloatPlane(width: w, height: h)
        meanA.values.withUnsafeBufferPointer { aBuffer in
            meanB.values.withUnsafeBufferPointer { bBuffer in
                guide.values.withUnsafeBufferPointer { guideBuffer in
                    output.values.withUnsafeMutableBufferPointer { dst in
                        var i = 0
                        while i < total {
                            dst[i] = aBuffer[i] * guideBuffer[i] + bBuffer[i]
                            i += 1
                        }
                    }
                }
            }
        }
        return output
    }

    /// Exact 1-D erosion by min over a (2r+1) window with edge padding, applied per axis.
    static func minimumFilter(_ plane: FloatPlane, radius: Int) -> FloatPlane {
        guard radius > 0, plane.width > 0, plane.height > 0,
              plane.values.count >= plane.count else { return plane }
        let horizontal = extremePass(plane, radius: radius, horizontal: true, minimum: true)
        return extremePass(horizontal, radius: radius, horizontal: false, minimum: true)
    }

    /// Dilate by max over a (2r+1) window (ops.py `maximum_filter`).
    static func maximumFilter(_ plane: FloatPlane, radius: Int) -> FloatPlane {
        guard radius > 0, plane.width > 0, plane.height > 0,
              plane.values.count >= plane.count else { return plane }
        let horizontal = extremePass(plane, radius: radius, horizontal: true, minimum: false)
        return extremePass(horizontal, radius: radius, horizontal: false, minimum: false)
    }

    /// Morphological close: dilate then erode (ops.py `morph_close`).
    static func morphologicalClose(_ plane: FloatPlane, radius: Int) -> FloatPlane {
        guard radius > 0 else { return plane }
        return minimumFilter(maximumFilter(plane, radius: radius), radius: radius)
    }

    // MARK: - Statistics

    /// Linear-interpolated percentile (numpy's default method). With a mask, only
    /// samples where mask > 0.5 take part; an empty selection falls back to the
    /// whole plane, and an empty plane yields 0.
    static func percentile(_ plane: FloatPlane, mask: FloatPlane?, _ p: Double) -> Float {
        guard plane.width > 0, plane.height > 0, plane.values.count >= plane.count else { return 0 }
        let probability = p.isFinite ? min(max(p, 0), 100) : 50
        var collected = [Float]()
        collected.reserveCapacity(min(plane.count, 1 << 20))
        gatherSamples(plane, mask: mask, into: &collected)
        if collected.isEmpty {
            gatherSamples(plane, mask: nil, into: &collected)
        }
        guard !collected.isEmpty else { return 0 }
        collected.sort()
        return quantile(collected, probability)
    }

    static func median(_ plane: FloatPlane, mask: FloatPlane?) -> Float {
        return percentile(plane, mask: mask, 50)
    }

    /// Mean over the masked samples (mask > 0.5); falls back to the whole plane.
    static func mean(_ plane: FloatPlane, mask: FloatPlane?) -> Float {
        guard plane.width > 0, plane.height > 0, plane.values.count >= plane.count else { return 0 }
        var sum = 0.0
        var count = 0
        if let mask = mask,
           mask.width == plane.width, mask.height == plane.height, mask.values.count >= plane.count {
            plane.values.withUnsafeBufferPointer { src in
                mask.values.withUnsafeBufferPointer { maskBuffer in
                    var i = 0
                    while i < plane.count {
                        if maskBuffer[i] > 0.5 {
                            let v = src[i]
                            if v.isFinite {
                                sum += Double(v)
                                count += 1
                            }
                        }
                        i += 1
                    }
                }
            }
        }
        if count == 0 {
            plane.values.withUnsafeBufferPointer { src in
                var i = 0
                while i < plane.count {
                    let v = src[i]
                    if v.isFinite {
                        sum += Double(v)
                        count += 1
                    }
                    i += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        return Float(sum / Double(count))
    }

    /// Per-channel median colour of the pixels where mask > 0.5, gamma sRGB 0...1.
    static func medianRGB(_ image: RGBAImage, mask: FloatPlane) -> SIMD3<Float> {
        let total = image.width * image.height
        let black = SIMD3<Float>(0, 0, 0)
        guard total > 0, image.bytes.count >= total * 4 else { return black }
        let useMask = mask.width == image.width && mask.height == image.height && mask.values.count >= total
        var red = [Float]()
        var green = [Float]()
        var blue = [Float]()
        red.reserveCapacity(min(total, 1 << 20))
        green.reserveCapacity(min(total, 1 << 20))
        blue.reserveCapacity(min(total, 1 << 20))
        if useMask {
            gatherRGB(image, mask: mask, useMask: true, red: &red, green: &green, blue: &blue)
        }
        if red.isEmpty {
            red.removeAll(keepingCapacity: true)
            green.removeAll(keepingCapacity: true)
            blue.removeAll(keepingCapacity: true)
            gatherRGB(image, mask: mask, useMask: false, red: &red, green: &green, blue: &blue)
        }
        guard !red.isEmpty else { return black }
        red.sort()
        green.sort()
        blue.sort()
        return SIMD3<Float>(quantile(red, 50), quantile(green, 50), quantile(blue, 50))
    }

    // MARK: - Colour spaces

    /// Rec.709 luma plane of an sRGB8 image (ops.py `luma` applied to the RGB proxy).
    /// This is the plane-returning counterpart of `luma(r:g:b:)`.
    static func luma(_ image: RGBAImage) -> FloatPlane {
        let w = image.width
        let h = image.height
        let total = w * h
        var plane = FloatPlane(width: w, height: h)
        guard total > 0, image.bytes.count >= total * 4 else { return plane }
        let scale: Float = 1.0 / 255.0
        image.bytes.withUnsafeBufferPointer { src in
            plane.values.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < total {
                    let offset = i * 4
                    let r = Float(src[offset]) * scale
                    let g = Float(src[offset + 1]) * scale
                    let b = Float(src[offset + 2]) * scale
                    dst[i] = lumaR * r + lumaG * g + lumaB * b
                    i += 1
                }
            }
        }
        return plane
    }

    /// BT.601 YCbCr on gamma-encoded sRGB (ops.py `rgb_to_ycbcr`); Cb/Cr centred at 0.5.
    static func ycbcr(_ image: RGBAImage) -> (y: FloatPlane, cb: FloatPlane, cr: FloatPlane) {
        let w = image.width
        let h = image.height
        let total = w * h
        var yPlane = FloatPlane(width: w, height: h)
        var cbPlane = FloatPlane(width: w, height: h)
        var crPlane = FloatPlane(width: w, height: h)
        guard total > 0, image.bytes.count >= total * 4 else { return (yPlane, cbPlane, crPlane) }
        let scale: Float = 1.0 / 255.0
        image.bytes.withUnsafeBufferPointer { src in
            yPlane.values.withUnsafeMutableBufferPointer { yBuffer in
                cbPlane.values.withUnsafeMutableBufferPointer { cbBuffer in
                    crPlane.values.withUnsafeMutableBufferPointer { crBuffer in
                        var i = 0
                        while i < total {
                            let offset = i * 4
                            let r = Float(src[offset]) * scale
                            let g = Float(src[offset + 1]) * scale
                            let b = Float(src[offset + 2]) * scale
                            yBuffer[i] = 0.299 * r + 0.587 * g + 0.114 * b
                            cbBuffer[i] = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
                            crBuffer[i] = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
                            i += 1
                        }
                    }
                }
            }
        }
        return (yPlane, cbPlane, crPlane)
    }

    /// CIELab planes of an sRGB8 image (bulk path uses the reference LUTs for speed).
    static func lab(_ image: RGBAImage) -> (l: FloatPlane, a: FloatPlane, b: FloatPlane) {
        let w = image.width
        let h = image.height
        let total = w * h
        var lPlane = FloatPlane(width: w, height: h)
        var aPlane = FloatPlane(width: w, height: h)
        var bPlane = FloatPlane(width: w, height: h)
        guard total > 0, image.bytes.count >= total * 4 else { return (lPlane, aPlane, bPlane) }
        let scale: Float = 1.0 / 255.0
        image.bytes.withUnsafeBufferPointer { src in
            srgbToLinearLUT.withUnsafeBufferPointer { lut in
                lPlane.values.withUnsafeMutableBufferPointer { lBuffer in
                    aPlane.values.withUnsafeMutableBufferPointer { aBuffer in
                        bPlane.values.withUnsafeMutableBufferPointer { bBuffer in
                            var i = 0
                            while i < total {
                                let offset = i * 4
                                let lr = Double(lookup(Float(src[offset]) * scale, lut))
                                let lg = Double(lookup(Float(src[offset + 1]) * scale, lut))
                                let lb = Double(lookup(Float(src[offset + 2]) * scale, lut))
                                let x = (m00 * lr + m01 * lg + m02 * lb) / whiteX
                                let y = (m10 * lr + m11 * lg + m12 * lb) / whiteY
                                let z = (m20 * lr + m21 * lg + m22 * lb) / whiteZ
                                let fx = labForward(x)
                                let fy = labForward(y)
                                let fz = labForward(z)
                                lBuffer[i] = Float(116.0 * fy - 16.0)
                                aBuffer[i] = Float(500.0 * (fx - fy))
                                bBuffer[i] = Float(200.0 * (fy - fz))
                                i += 1
                            }
                        }
                    }
                }
            }
        }
        return (lPlane, aPlane, bPlane)
    }

    // MARK: - Core Image helpers (each returns its input when a filter is unavailable)

    /// Feathered Gaussian blur; the caller is responsible for clamping/cropping.
    static func gaussian(_ image: CIImage, radius: Double) -> CIImage {
        guard radius.isFinite, radius > 0.3 else { return image }
        // The typed `CIFilter` factory is not exposed by every SDK that this
        // lightweight mask test supports.  The named filter is the same
        // system filter and keeps the helper available on iOS 17+.
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return image }
        let extent = image.extent
        if extent.isInfinite || extent.isNull { return output }
        return output.cropped(to: extent)
    }

    /// `foreground` composited over `background` through the luminance of `mask`.
    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return background }
        filter.setValue(foreground, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage else { return background }
        let extent = background.extent
        if extent.isInfinite || extent.isNull {
            let fallback = foreground.extent
            if fallback.isInfinite || fallback.isNull { return output }
            return output.cropped(to: fallback)
        }
        return output.cropped(to: extent)
    }

    /// Flat grey mask image covering `extent`.
    static func constantMask(luma: CGFloat, extent: CGRect) -> CIImage {
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else {
            return emptyImage()
        }
        let value = min(max(luma, 0), 1)
        let colour = CIColor(red: value, green: value, blue: value, alpha: 1)
        return CIImage(color: colour).cropped(to: extent)
    }

    /// `mask * luma`, feathered by a 2 px Gaussian, cropped to `extent`.
    static func scaledMask(_ luma: CGFloat, of mask: CIImage, extent: CGRect) -> CIImage {
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return mask }
        let value = min(max(luma, 0), 1)
        let clipped = mask.cropped(to: extent)
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return clipped }
        matrix.setValue(clipped, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: value, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: value, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: value, w: 0), forKey: "inputBVector")
        // Keep the mask opaque: blendWithMask reads luminance, not alpha.
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        let product = matrix.outputImage ?? clipped
        return gaussian(product.clampedToExtent(), radius: 2).cropped(to: extent)
    }

    /// Affine downsample so the long edge is at most `maxEdge`; upscaling is a no-op.
    /// `context` is accepted for call-site symmetry and future Lanczos rendering.
    static func downscale(_ image: CIImage, maxEdge: CGFloat, context: CIContext) -> CIImage {
        _ = context
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull else { return image }
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return image }
        guard maxEdge.isFinite, maxEdge > 0 else { return image }
        let longEdge = max(extent.width, extent.height)
        guard longEdge > maxEdge else { return image }
        let scale = maxEdge / longEdge
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Private helpers

    /// Target pixel size for a scaled extent, clamped to a sane range.
    private static func pixelSize(of extent: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        let rawWidth = (extent.width * scale).rounded()
        let rawHeight = (extent.height * scale).rounded()
        let clampedWidth = min(max(rawWidth.isFinite ? rawWidth : 1, 1), 16384)
        let clampedHeight = min(max(rawHeight.isFinite ? rawHeight : 1, 1), 16384)
        return (Int(clampedWidth), Int(clampedHeight))
    }

    /// 8-bit grey CGImage of a plane (values clamped to 0...1, rounded).
    private static func grayCGImage(from plane: FloatPlane) -> CGImage? {
        let total = plane.width * plane.height
        guard plane.width > 0, plane.height > 0, total > 0, plane.values.count >= total else { return nil }
        var bytes = [UInt8](repeating: 0, count: total)
        plane.values.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < total {
                    var v = src[i]
                    if !v.isFinite { v = 0 }
                    let clamped = min(max(v, 0), 1) * 255.0 + 0.5
                    let rounded = Int(clamped)
                    dst[i] = UInt8(min(255, max(0, rounded)))
                    i += 1
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: plane.width, height: plane.height,
                       bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: plane.width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Zero-extent black image used for degenerate inputs.
    private static func emptyImage() -> CIImage {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
        return black.cropped(to: CGRect.zero)
    }

    /// 1-D separable box blur pass using cumulative sums (ops.py `_box_blur_1d`),
    /// but with true edge clamping: the window is folded back inside the line and
    /// the divisor stays (2r+1).
    private static func boxPass(_ plane: FloatPlane, radius: Int, horizontal: Bool) -> FloatPlane {
        let w = plane.width
        let h = plane.height
        let n = horizontal ? w : h
        let lines = horizontal ? h : w
        let step = horizontal ? 1 : w
        let r = radius
        guard n > 0, lines > 0 else { return plane }
        let denominator = Float(2 * r + 1)
        var output = FloatPlane(width: w, height: h)
        var prefix = [Float](repeating: 0, count: n + 1)
        let source = plane.values
        prefix.withUnsafeMutableBufferPointer { prefixBuffer in
            source.withUnsafeBufferPointer { src in
                output.values.withUnsafeMutableBufferPointer { dst in
                    var line = 0
                    while line < lines {
                        let base = horizontal ? line * w : line
                        prefixBuffer[0] = 0
                        var i = 0
                        while i < n {
                            prefixBuffer[i + 1] = prefixBuffer[i] + src[base + i * step]
                            i += 1
                        }
                        let first = src[base]
                        let last = src[base + (n - 1) * step]
                        var x = 0
                        while x < n {
                            let lowIndex = x - r > 0 ? x - r : 0
                            let highIndex = x + r < n - 1 ? x + r : n - 1
                            var sum = prefixBuffer[highIndex + 1] - prefixBuffer[lowIndex]
                            let leftWrap = x < r ? r - x : 0
                            let rightWrap = x + r > n - 1 ? x + r - (n - 1) : 0
                            if leftWrap > 0 { sum += Float(leftWrap) * first }
                            if rightWrap > 0 { sum += Float(rightWrap) * last }
                            dst[base + x * step] = sum / denominator
                            x += 1
                        }
                        line += 1
                    }
                }
            }
        }
        return output
    }

    /// 1-D separable min/max pass with edge padding (ops.py `_min_filter_1d`).
    private static func extremePass(_ plane: FloatPlane, radius: Int, horizontal: Bool,
                                    minimum: Bool) -> FloatPlane {
        let w = plane.width
        let h = plane.height
        let n = horizontal ? w : h
        let lines = horizontal ? h : w
        let step = horizontal ? 1 : w
        let r = radius
        guard n > 0, lines > 0 else { return plane }
        let window = 2 * r + 1
        var output = FloatPlane(width: w, height: h)
        var padded = [Float](repeating: 0, count: n + 2 * r)
        let source = plane.values
        padded.withUnsafeMutableBufferPointer { paddedBuffer in
            source.withUnsafeBufferPointer { src in
                output.values.withUnsafeMutableBufferPointer { dst in
                    var line = 0
                    while line < lines {
                        let base = horizontal ? line * w : line
                        let first = src[base]
                        let last = src[base + (n - 1) * step]
                        var i = 0
                        while i < r {
                            paddedBuffer[i] = first
                            paddedBuffer[r + n + i] = last
                            i += 1
                        }
                        i = 0
                        while i < n {
                            paddedBuffer[r + i] = src[base + i * step]
                            i += 1
                        }
                        var x = 0
                        while x < n {
                            var extreme = paddedBuffer[x]
                            var k = 1
                            while k < window {
                                let candidate = paddedBuffer[x + k]
                                if minimum {
                                    if candidate < extreme { extreme = candidate }
                                } else {
                                    if candidate > extreme { extreme = candidate }
                                }
                                k += 1
                            }
                            dst[base + x * step] = extreme
                            x += 1
                        }
                        line += 1
                    }
                }
            }
        }
        return output
    }

    /// Lab forward transfer function f(t) with the CIE break point.
    @inline(__always)
    private static func labForward(_ t: Double) -> Double {
        if t > labEps { return cbrt(t) }
        return (labKappa * t + 16.0) / 116.0
    }

    @inline(__always)
    private static func cosDegrees(_ degrees: Double) -> Double {
        return cos(degrees * Double.pi / 180.0)
    }

    @inline(__always)
    private static func sinDegrees(_ degrees: Double) -> Double {
        return sin(degrees * Double.pi / 180.0)
    }

    /// atan2 in degrees (numpy `np.degrees(np.arctan2(...))`).
    @inline(__always)
    private static func atan2Degrees(_ y: Double, _ x: Double) -> Double {
        return atan2(y, x) * 180.0 / Double.pi
    }

    /// Linearly interpolated LUT lookup, clamped to 0...1 (ops.py `_apply_lut`).
    @inline(__always)
    private static func lookup(_ x: Float, _ table: UnsafeBufferPointer<Float>) -> Float {
        let size = table.count
        guard size > 1 else { return min(max(x, 0), 1) }
        let clamped = x.isFinite ? min(max(x, 0), 1) : 0
        let position = clamped * Float(size - 1)
        let lower = Int(position)
        let upper = lower + 1 < size ? lower + 1 : size - 1
        let fraction = position - Float(lower)
        let lo = table[lower]
        return lo * (1 - fraction) + table[upper] * fraction
    }

    /// numpy-compatible linear-interpolated quantile of a sorted buffer.
    private static func quantile(_ sorted: [Float], _ p: Double) -> Float {
        let n = sorted.count
        if n == 0 { return 0 }
        if n == 1 { return sorted[0] }
        let rank = min(max(p, 0), 100) / 100.0 * Double(n - 1)
        let lower = Int(rank.rounded(.down))
        let clampedLower = min(max(lower, 0), n - 1)
        let upper = min(clampedLower + 1, n - 1)
        let fraction = Float(rank - Double(clampedLower))
        let low = sorted[clampedLower]
        return low + (sorted[upper] - low) * fraction
    }

    /// Collects finite plane samples, honouring mask > 0.5 when a usable mask is given.
    private static func gatherSamples(_ plane: FloatPlane, mask: FloatPlane?, into output: inout [Float]) {
        let total = plane.count
        guard total > 0, plane.values.count >= total else { return }
        let usableMask: FloatPlane?
        if let mask = mask, mask.width == plane.width, mask.height == plane.height,
           mask.values.count >= total {
            usableMask = mask
        } else {
            usableMask = nil
        }
        if let usableMask = usableMask {
            plane.values.withUnsafeBufferPointer { src in
                usableMask.values.withUnsafeBufferPointer { maskBuffer in
                    var i = 0
                    while i < total {
                        if maskBuffer[i] > 0.5 {
                            let v = src[i]
                            if v.isFinite { output.append(v) }
                        }
                        i += 1
                    }
                }
            }
        } else {
            plane.values.withUnsafeBufferPointer { src in
                var i = 0
                while i < total {
                    let v = src[i]
                    if v.isFinite { output.append(v) }
                    i += 1
                }
            }
        }
    }

    /// Collects per-channel samples (0...1 sRGB) for medianRGB.
    private static func gatherRGB(_ image: RGBAImage, mask: FloatPlane, useMask: Bool,
                                  red: inout [Float], green: inout [Float], blue: inout [Float]) {
        let total = image.count
        guard total > 0, image.bytes.count >= total * 4 else { return }
        let scale: Float = 1.0 / 255.0
        image.bytes.withUnsafeBufferPointer { src in
            mask.values.withUnsafeBufferPointer { maskBuffer in
                var i = 0
                while i < total {
                    let keep = useMask ? (i < maskBuffer.count && maskBuffer[i] > 0.5) : true
                    if keep {
                        let offset = i * 4
                        red.append(Float(src[offset]) * scale)
                        green.append(Float(src[offset + 1]) * scale)
                        blue.append(Float(src[offset + 2]) * scale)
                    }
                    i += 1
                }
            }
        }
    }
}
