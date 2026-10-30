import Foundation
import CoreImage

extension BlemishModelBridge {
    /// Computes the 9 model features on the detector proxy and re-scores the
    /// classical candidates. Additive: if anything is missing it returns the
    /// input candidates unchanged, so the shipping detector can never break.
    ///
    /// Feature order must match `BlemishLearnedModel.weights`:
    /// dL, dA, dB, log1, log2, log3, grad, ringStd, dE
    static func rescore(spots: [BlemishSpot], proxy: RGBAImage?, faceWidthPx: Double) -> [BlemishSpot] {
        guard !spots.isEmpty, let proxy, faceWidthPx > 8 else { return spots }
        let w = proxy.width, h = proxy.height
        guard w > 16, h > 16 else { return spots }

        let lab = PixelKit.lab(proxy)
        let blurRadius = max(4.0, faceWidthPx * 0.05)
        let surround = PixelKit.gaussianBlur(lab.l, sigma: blurRadius)
        let surroundA = PixelKit.gaussianBlur(lab.a, sigma: blurRadius)
        let surroundB = PixelKit.gaussianBlur(lab.b, sigma: blurRadius)

        var log1 = PixelKit.gaussianBlur(lab.l, sigma: max(1.2, faceWidthPx * 0.004 * 0.7))
        var log1b = PixelKit.gaussianBlur(lab.l, sigma: max(1.2, faceWidthPx * 0.004 * 1.6))
        var log2 = PixelKit.gaussianBlur(lab.l, sigma: max(1.2, faceWidthPx * 0.006 * 0.7))
        var log2b = PixelKit.gaussianBlur(lab.l, sigma: max(1.2, faceWidthPx * 0.006 * 1.6))
        var log3 = PixelKit.gaussianBlur(lab.l, sigma: max(1.2, faceWidthPx * 0.009 * 0.7))
        var log3b = PixelKit.gaussianBlur(lab.l, sigma: max(1.2, faceWidthPx * 0.009 * 1.6))
        var smooth = PixelKit.gaussianBlur(lab.l, sigma: 1.4)

        let ringRadius = max(4, Int((faceWidthPx * 0.02).rounded()))
        let ringMean = PixelKit.boxBlur(lab.l, radius: ringRadius)

        var rows: [[Float]] = []
        rows.reserveCapacity(spots.count)
        for spot in spots {
            let x = Int((spot.center.x * CGFloat(w)).rounded())
            let y = Int((spot.center.y * CGFloat(h)).rounded())
            guard x > 2, y > 2, x < w - 3, y < h - 3 else {
                rows.append([])
                continue
            }
            let l = lab.l[x, y], a = lab.a[x, y], b = lab.b[x, y]
            let dL = l - surround[x, y]
            let dA = a - surroundA[x, y]
            let dB = b - surroundB[x, y]
            let scaled = [
                (Float(faceWidthPx * 0.004) * Float(faceWidthPx * 0.004)) * (log1[x, y] - log1b[x, y]),
                (Float(faceWidthPx * 0.006) * Float(faceWidthPx * 0.006)) * (log2[x, y] - log2b[x, y]),
                (Float(faceWidthPx * 0.009) * Float(faceWidthPx * 0.009)) * (log3[x, y] - log3b[x, y])
            ]
            let gx = smooth[x + 1, y] - smooth[x - 1, y]
            let gy = smooth[x, y + 1] - smooth[x, y - 1]
            let grad = (gx * gx + gy * gy).squareRoot()

            // ring variance from the local mean of squares minus square of mean
            var sumSq: Float = 0
            var count: Float = 0
            for yy in max(0, y - ringRadius)...min(h - 1, y + ringRadius) {
                for xx in max(0, x - ringRadius)...min(w - 1, x + ringRadius) {
                    let dx = Float(xx - x) / Float(ringRadius)
                    let dy = Float(yy - y) / Float(ringRadius)
                    let dist = (dx * dx + dy * dy).squareRoot()
                    if dist > 0.6 && dist <= 1.0 {
                        let v = lab.l[xx, yy]
                        sumSq += v * v
                        count += 1
                    }
                }
            }
            let mean = count > 0 ? (sumSq / count).squareRoot() : 0
            let ringStd = count > 1 ? max(0, (sumSq / count) - mean * mean).squareRoot() : 0

            let labA = SIMD3<Float>(surround[x, y], surroundA[x, y], surroundB[x, y])
            let dE = PixelKit.deltaE2000(SIMD3<Float>(l, a, b), labA)

            rows.append([dL, dA, dB, scaled[0], scaled[1], scaled[2], grad, ringStd, dE])
        }

        let kept = rescore(spots, features: rows)
        return kept
    }
}
