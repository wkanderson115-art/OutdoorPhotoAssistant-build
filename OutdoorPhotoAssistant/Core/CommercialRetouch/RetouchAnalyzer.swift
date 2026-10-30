import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Face geometry detection + skin/scene analysis for the commercial retouch engine.
///
/// All heavy per-pixel analysis runs on a proxy (long edge <= 1024 px) and is
/// then upscaled through Core Image, so a 48 MP frame never allocates CPU
/// buffers larger than the proxy. The numbers are the ones tuned in
/// `tools/retouch_lab/portrait.py`.
final class RetouchAnalyzer {
    static let analysisEdge: CGFloat = 1024
    static let detectionEdge: CGFloat = 2000
    static let maxSpots = 80

    // MARK: - Face geometry

    /// Vision returns lower-left origin normalised rects; this converts to the
    /// top-left / y-down convention used everywhere else in the retouch code.
    func detectFace(in image: CIImage, context: CIContext, proxyEdge: CGFloat = 1600) -> FaceGeometry? {
        guard let cg = PixelKit.cgImage(image, context: context) ?? PixelKit.cgImage(
            image.transformed(by: CGAffineTransform(scaleX: min(1, proxyEdge / max(image.extent.width, image.extent.height)),
                                                    y: min(1, proxyEdge / max(image.extent.width, image.extent.height)))),
            context: context) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }
        // largest face wins
        let face = faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }
        guard let face else { return nil }
        let bb = face.boundingBox
        let box = CGRect(x: bb.minX, y: 1.0 - bb.maxY, width: bb.width, height: bb.height)

        func imageRect(from points: [CGPoint]?) -> CGRect? {
            guard let points, points.count >= 3 else { return nil }
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in points {
                // landmark points are normalised inside the face bounding box
                let x = bb.minX + p.x * bb.width
                let y = 1.0 - (bb.minY + p.y * bb.height)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            guard maxX > minX, maxY > minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        let landmarks = face.landmarks
        let leftEye = imageRect(from: landmarks?.leftEye?.normalizedPoints)
        let rightEye = imageRect(from: landmarks?.rightEye?.normalizedPoints)
        let lips = imageRect(from: landmarks?.outerLips?.normalizedPoints)
        let nose: CGPoint? = {
            guard let n = landmarks?.nose?.normalizedPoints, !n.isEmpty else { return nil }
            let p = n[n.count / 2]
            return CGPoint(x: bb.minX + p.x * bb.width, y: 1.0 - (bb.minY + p.y * bb.height))
        }()
        return FaceGeometry(box: box, leftEye: leftEye, rightEye: rightEye, lips: lips, nose: nose)
    }

    // MARK: - Skin analysis

    func analyze(image: CIImage, geometry: FaceGeometry, context: CIContext) -> SkinAnalysis? {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 8 else { return nil }
        let proxyEdge = min(Self.analysisEdge, longEdge)
        guard let proxy = PixelKit.renderRGBA8(image, maxEdge: proxyEdge, context: context) else { return nil }
        let pw = CGFloat(proxy.width), ph = CGFloat(proxy.height)
        let lab = PixelKit.lab(proxy)
        let ycc = PixelKit.ycbcr(proxy)

        let fw = max(8.0, geometry.width * pw)
        let fh = max(8.0, geometry.height * ph)
        let box = geometry.box
        let cx = box.midX, cy = box.midY

        var prior = FloatPlane(width: proxy.width, height: proxy.height)
        var region = FloatPlane(width: proxy.width, height: proxy.height)
        Self.ellipse(&prior, cx: cx, cy: box.minY + geometry.height * 0.46,
                     rx: geometry.width * 0.52, ry: geometry.height * 0.52, soft: 2.4)
        Self.ellipse(&region, cx: cx, cy: box.minY + geometry.height * 0.47,
                     rx: geometry.width * 0.54, ry: geometry.height * 0.54, soft: 2.0)

        // median skin colour inside the prior
        let labMedian = PixelKit.medianRGB(proxy, mask: prior)

        // coarse skin gate: YCbCr window + Lab distance + luma floor
        var coarse = FloatPlane(width: proxy.width, height: proxy.height)
        var lumaSum: Float = 0, lumaCount: Float = 0
        for y in 0..<proxy.height {
            for x in 0..<proxy.width {
                let pr = prior[x, y]
                if pr <= 0 { continue }
                let cb = ycc.cb[x, y] * 255, cr = ycc.cr[x, y] * 255, yy = ycc.y[x, y] * 255
                let inWindow = cb > 76 && cb < 128 && cr > 132 && cr < 174 && yy > 40 && yy < 246
                var v: Float = inWindow ? 0.6 : 0.0
                let dl = (lab.l[x, y] - labMedian.x) / 42.0
                let da = (lab.a[x, y] - labMedian.y) / 13.0
                let db = (lab.b[x, y] - labMedian.z) / 17.0
                let dist = sqrt(dl * dl + da * da + db * db)
                let gate = min(max((1.0 - dist * 0.85 - 0.15) / 0.5, 0), 1)
                v += 0.6 * gate
                coarse[x, y] = min(v, 1) * pr
                lumaSum += ycc.y[x, y]; lumaCount += 1
            }
        }

        // guided-filter refinement, then threshold + morphology (as in the lab)
        let guide = ycc.y
        let radius = max(2, Int((fw * 0.04).rounded()))
        let refined = PixelKit.guidedFilter(guide: guide, src: coarse, radius: radius, eps: 2e-3)
        var skin = FloatPlane(width: proxy.width, height: proxy.height)
        for i in 0..<skin.values.count {
            skin.values[i] = min(max((refined.values[i] - 0.30) / 0.42, 0), 1)
        }
        let closed = PixelKit.morphologicalClose(skin, radius: max(1, Int((fw * 0.006).rounded())))

        // dark hair passes the YCbCr skin window: drop anything far darker than the face
        var refLuma: [Float] = []
        for i in 0..<closed.values.count where closed.values[i] > 0.45 { refLuma.append(guide.values[i]) }
        let faceLuma = Float(PixelKit.percentile(FloatPlane(width: refLuma.count, height: 1,
                                                            values: refLuma), mask: nil, 60))
        let floor = max(0.02, faceLuma * 0.62)
        let ceil = max(floor + 0.001, faceLuma * 0.22)
        var gated = FloatPlane(width: proxy.width, height: proxy.height)
        for i in 0..<gated.values.count {
            let lg = min(max((guide.values[i] - floor) / ceil, 0), 1)
            gated.values[i] = closed.values[i] * lg * region.values[i]
        }

        // feature exclusions (eyes, brows, lips, nostrils)
        let (eyeL, eyeR) = geometry.derivedEyes()
        var feature = FloatPlane(width: proxy.width, height: proxy.height)
        for eye in [eyeL, eyeR] {
            Self.ellipse(&feature, rect: eye.insetBy(dx: -eye.width * 0.08, dy: -eye.height * 0.35),
                         soft: 2.0, featherPx: fw * 0.010, imageWidth: pw, imageHeight: ph)
            let brow = CGRect(x: eye.minX - eye.width * 0.06, y: eye.minY - eye.height * 1.75,
                              width: eye.width * 1.12, height: eye.height * 0.95)
            Self.ellipse(&feature, rect: brow, soft: 2.0, featherPx: fw * 0.008, imageWidth: pw, imageHeight: ph)
        }
        let lips = geometry.derivedLips()
        Self.ellipse(&feature, rect: lips.insetBy(dx: -lips.width * 0.06, dy: -lips.height * 0.10),
                     soft: 2.0, featherPx: fw * 0.010, imageWidth: pw, imageHeight: ph)
        let nose = geometry.nose ?? CGPoint(x: box.midX, y: box.minY + geometry.height * 0.60)
        Self.ellipse(&feature, rect: CGRect(x: nose.x - geometry.width * 0.065, y: nose.y - geometry.height * 0.04,
                                            width: geometry.width * 0.13, height: geometry.height * 0.08),
                     soft: 2.0, featherPx: fw * 0.006, imageWidth: pw, imageHeight: ph)
        var clean = FloatPlane(width: proxy.width, height: proxy.height)
        for i in 0..<clean.values.count {
            clean.values[i] = gated.values[i] * (1.0 - 0.95 * feature.values[i])
        }

        // sensor noise from the flattest skin areas
        let hp = Self.subtract(lab.l, PixelKit.gaussianBlur(lab.l, sigma: max(1.2, Double(fw) * 0.003)))
        let texture = PixelKit.gaussianBlur(hp, sigma: max(1.2, Double(fw) * 0.003))
        var flatMask = FloatPlane(width: proxy.width, height: proxy.height)
        for i in 0..<flatMask.values.count { flatMask.values[i] = clean.values[i] > 0.6 ? 1 : 0 }
        let noise = max(0.35, min(6.0, Double(PixelKit.median(texture, mask: flatMask)) * 1.4826))

        // skin colour + exposure references
        var strongSkin = FloatPlane(width: proxy.width, height: proxy.height)
        for i in 0..<strongSkin.values.count { strongSkin.values[i] = clean.values[i] > 0.7 ? 1 : 0 }
        let skinLab = PixelKit.medianRGB(proxy, mask: strongSkin)
        let exposure = Double(PixelKit.percentile(ycc.y, mask: strongSkin, 55))
        let wb = Self.whiteBalance(proxy)

        // upsample masks to full resolution
        let fullSize = CGSize(width: extent.width, height: extent.height)
        let skinImage = PixelKit.maskImage(from: clean, targetSize: fullSize)
        let featureImage = PixelKit.maskImage(from: PixelKit.gaussianBlur(feature, sigma: 2.0), targetSize: fullSize)

        return SkinAnalysis(skinMask: skinImage,
                            featureMask: featureImage,
                            noiseSigma: noise,
                            geometry: geometry,
                            skinLabMedian: SIMD3(Double(skinLab.x), Double(skinLab.y), Double(skinLab.z)),
                            exposure: exposure,
                            whiteBalance: wb,
                            longEdge: longEdge,
                            analysisEdge: proxyEdge)
    }

    // MARK: - Scene branch helpers

    /// Grey-world white balance limited to +-7 %, same clamp as the reference lab.
    static func whiteBalance(_ proxy: RGBAImage) -> SIMD3<Double> {
        var r: Double = 0, g: Double = 0, b: Double = 0
        var n: Double = 0
        var satValues: [Float] = []
        satValues.reserveCapacity(proxy.width * proxy.height)
        let stride = max(1, (proxy.width * proxy.height) / 40000)
        for i in Swift.stride(from: 0, to: proxy.width * proxy.height, by: stride) {
            let o = i * 4
            let rf = Float(proxy.bytes[o]) / 255, gf = Float(proxy.bytes[o + 1]) / 255, bf = Float(proxy.bytes[o + 2]) / 255
            let mx = max(rf, max(gf, bf)), mn = min(rf, min(gf, bf))
            satValues.append(mx > 1e-4 ? (mx - mn) / mx : 0)
        }
        guard !satValues.isEmpty else { return SIMD3(1, 1, 1) }
        satValues.sort()
        let cut = satValues[Int(Double(satValues.count - 1) * 0.30)]
        for i in Swift.stride(from: 0, to: proxy.width * proxy.height, by: stride) {
            let o = i * 4
            let rf = Double(proxy.bytes[o]) / 255, gf = Double(proxy.bytes[o + 1]) / 255, bf = Double(proxy.bytes[o + 2]) / 255
            let mx = max(rf, max(gf, bf)), mn = min(rf, min(gf, bf))
            let sat = mx > 1e-4 ? (mx - mn) / mx : 0
            if sat < Double(cut) { r += rf; g += gf; b += bf; n += 1 }
        }
        guard n > 10 else { return SIMD3(1, 1, 1) }
        r /= n; g /= n; b /= n
        let target = (r + g + b) / 3.0
        func clamp(_ v: Double) -> Double { min(1.07, max(0.93, v)) }
        return SIMD3(clamp(target / max(r, 1e-3)), clamp(target / max(g, 1e-3)), clamp(target / max(b, 1e-3)))
    }

    /// Highlight / shadow percentiles for the tone stage.
    static func toneReference(_ proxy: RGBAImage) -> (low: Double, high: Double) {
        var lumas: [Float] = []
        lumas.reserveCapacity(proxy.width * proxy.height)
        let stride = max(1, (proxy.width * proxy.height) / 60000)
        for i in Swift.stride(from: 0, to: proxy.width * proxy.height, by: stride) {
            let o = i * 4
            let r = Float(proxy.bytes[o]) / 255, g = Float(proxy.bytes[o + 1]) / 255, b = Float(proxy.bytes[o + 2]) / 255
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        let plane = FloatPlane(width: lumas.count, height: 1, values: lumas)
        return (Double(PixelKit.percentile(plane, mask: nil, 0.5)),
                Double(PixelKit.percentile(plane, mask: nil, 99.6)))
    }

    // MARK: - Plane helpers

    private static func subtract(_ a: FloatPlane, _ b: FloatPlane) -> FloatPlane {
        var out = FloatPlane(width: a.width, height: a.height)
        for i in 0..<out.values.count { out.values[i] = a.values[i] - b.values[i] }
        return out
    }

    /// Filled ellipse mask in normalised coordinates.
    static func ellipse(_ plane: inout FloatPlane, rect: CGRect, soft: Float,
                        featherPx: CGFloat = 0, imageWidth: CGFloat, imageHeight: CGFloat) {
        let cx = rect.midX, cy = rect.midY
        let rx = max(rect.width / 2, 1e-4), ry = max(rect.height / 2, 1e-4)
        ellipse(&plane, cx: cx, cy: cy, rx: rx, ry: ry, soft: soft)
    }

    static func ellipse(_ plane: inout FloatPlane, cx: CGFloat, cy: CGFloat,
                        rx: CGFloat, ry: CGFloat, soft: Float) {
        let w = plane.width, h = plane.height
        guard w > 0, h > 0, rx > 0, ry > 0 else { return }
        let x0 = max(0, Int(((cx - rx) * CGFloat(w)).rounded(.down)))
        let x1 = min(w - 1, Int(((cx + rx) * CGFloat(w)).rounded(.up)))
        let y0 = max(0, Int(((cy - ry) * CGFloat(h)).rounded(.down)))
        let y1 = min(h - 1, Int(((cy + ry) * CGFloat(h)).rounded(.up)))
        guard x1 >= x0, y1 >= y0 else { return }
        for y in y0...y1 {
            let ny = ((CGFloat(y) + 0.5) / CGFloat(h) - cy) / ry
            for x in x0...x1 {
                let nx = ((CGFloat(x) + 0.5) / CGFloat(w) - cx) / rx
                let d = Float(sqrt(nx * nx + ny * ny))
                let v = min(max((1.0 - d) * soft, 0), 1)
                plane.values[y * w + x] = max(plane.values[y * w + x], v)
            }
        }
    }
}
