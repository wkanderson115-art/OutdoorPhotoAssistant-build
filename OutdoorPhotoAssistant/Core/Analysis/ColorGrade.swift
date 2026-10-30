import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// 一套可解释的调色参数。所有值都是"相对默认值"的偏移量，含义与 Core Image 一一对应。
struct ColorGrade: Equatable {
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 1
    var contrast: Double = 1
    var brightness: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var clarity: Double = 0
    var vignette: Double = 0
    var redHue: Double = 0
    var redSat: Double = 0
    var redLum: Double = 0
    var orangeHue: Double = 0
    var orangeSat: Double = 0
    var orangeLum: Double = 0
    var yellowHue: Double = 0
    var yellowSat: Double = 0
    var yellowLum: Double = 0
    var greenHue: Double = 0
    var greenSat: Double = 0
    var greenLum: Double = 0
    var cyanHue: Double = 0
    var cyanSat: Double = 0
    var cyanLum: Double = 0
    var blueHue: Double = 0
    var blueSat: Double = 0
    var blueLum: Double = 0
    var purpleHue: Double = 0
    var purpleSat: Double = 0
    var purpleLum: Double = 0
    var curveShadow: Double = 0
    var curveMid: Double = 0
    var curveHighlight: Double = 0

    /// 场景 + 光线 + 时段 → 调色参数。
    /// period 传入 "日间" / "黄金时段" / "蓝调时刻" / "夜景" 时才会生效（上一版恒传空串，导致时段调色永远不触发）。
    static func automatic(scene: String, brightness: Double, period: String, confidence: Double) -> ColorGrade {
        var g = ColorGrade()
        let c = max(0.55, min(1.0, confidence))
        switch scene {
        case "人物", "自拍":
            g.temperature = brightness < 0.28 ? 7 : 3
            g.saturation = 1.02
            g.contrast = 0.98
            g.orangeSat = 5
            g.orangeLum = 4
            g.redSat = -3
            g.shadows = 3
        case "日落":
            g.temperature = 14
            g.saturation = 1.10
            g.contrast = 1.06
            g.highlights = -14
            g.orangeSat = 18 * c
            g.orangeLum = 5
            g.redSat = 8
            g.yellowSat = 7
            g.blueSat = -5
        case "海边":
            g.temperature = -6
            g.saturation = 1.06
            g.contrast = 1.04
            g.highlights = -10
            g.cyanSat = 14 * c
            g.blueSat = 12 * c
            g.blueLum = -3
            g.greenSat = -3
        case "风景", "花草":
            g.saturation = 1.08
            g.contrast = 1.07
            g.clarity = 0.12
            g.greenSat = 12 * c
            g.greenLum = 4
            g.blueSat = 8 * c
            g.yellowSat = 5
        case "建筑":
            g.saturation = 1.01
            g.contrast = 1.08
            g.clarity = 0.16
            g.highlights = -9
            g.shadows = 5
            g.cyanSat = 4
            g.blueSat = 5
        case "汽车":
            g.saturation = 1.08
            g.contrast = 1.10
            g.clarity = 0.14
            g.shadows = 3
            g.redSat = 7
            g.blueSat = 8
            g.cyanSat = 5
        case "夜景":
            g.temperature = -5
            g.saturation = 0.98
            g.contrast = 1.08
            g.highlights = -22
            g.shadows = 9
            g.blueSat = 8
            g.cyanSat = 6
            g.yellowSat = -6
        default:
            g.saturation = brightness > 0.82 ? 1.02 : 1.05
            g.contrast = 1.03
            g.highlights = brightness > 0.86 ? -10 : 0
        }

        switch period {
        case "黄金时段":
            g.temperature += 4
            g.orangeSat += 4
        case "蓝调时刻":
            g.temperature -= 5
            g.blueSat += 6
        case "夜景":
            g.highlights -= 4
            g.shadows += 2
        default:
            break
        }

        if brightness < 0.16 {
            g.shadows += 7
            g.contrast = min(g.contrast, 1.06)
        }
        if brightness > 0.92 {
            g.highlights -= 10
        }
        return g
    }

    /// 构图风格（自然 / 电影 / 主体）：直接影响最终成片，而不是只改 UI 文字。
    func applyingStyle(_ style: String) -> ColorGrade {
        var g = self
        switch style {
        case "电影":
            g.contrast += 0.04
            g.saturation *= 0.94
            g.vignette += 0.10
            g.curveShadow -= 0.06
            g.curveHighlight -= 0.05
        case "主体":
            g.clarity += 0.04
            g.shadows += 3
        default:
            break
        }
        return g
    }
}

/// 把 ColorGrade 变成 Core Image 管线。输入输出都是 CIImage，整条链路只在最后渲染一次。
enum ColorGradeEngine {
    private static let cubeLock = NSLock()
    private static var cubeCache: [String: Data] = [:]

    static func apply(_ grade: ColorGrade, to input: CIImage) -> CIImage {
        var current = input

        if abs(grade.saturation - 1) > 0.001 || abs(grade.contrast - 1) > 0.001 || abs(grade.brightness) > 0.001 {
            let controls = CIFilter.colorControls()
            controls.inputImage = current
            controls.saturation = Float(grade.saturation)
            controls.contrast = Float(grade.contrast)
            controls.brightness = Float(grade.brightness)
            current = controls.outputImage ?? current
        }

        if abs(grade.temperature) > 0.1 || abs(grade.tint) > 0.1 {
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = current
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: CGFloat(6500 - grade.temperature * 45), y: CGFloat(grade.tint * 12))
            current = temp.outputImage ?? current
        }

        if abs(grade.highlights) > 0.1 || abs(grade.shadows) > 0.1 {
            let curves = CIFilter.highlightShadowAdjust()
            curves.inputImage = current
            // CIHighlightShadowAdjust: highlightAmount 1 = 不压高光，0 = 最大压暗；shadowAmount 0 = 不提阴影，1 = 最大提亮
            curves.highlightAmount = Float(max(0, min(1, 1 + grade.highlights / 100)))
            curves.shadowAmount = Float(max(0, min(1, grade.shadows / 20)))
            current = curves.outputImage ?? current
        }

        if hasSelective(grade) {
            current = applyCube(grade, to: current)
        }

        if hasToneCurve(grade) {
            current = applyToneCurve(grade, to: current)
        }

        if grade.clarity > 0.01 {
            let sharp = CIFilter.sharpenLuminance()
            sharp.inputImage = current
            sharp.sharpness = Float(min(1, grade.clarity))
            sharp.radius = 1.0
            current = sharp.outputImage ?? current
        }

        if grade.vignette > 0.01 {
            let vig = CIFilter.vignette()
            vig.inputImage = current
            vig.intensity = Float(min(1.6, grade.vignette))
            vig.radius = 1.5
            current = vig.outputImage ?? current
        }

        return current
    }

    private static func hasSelective(_ g: ColorGrade) -> Bool {
        let sats = [g.redSat, g.orangeSat, g.yellowSat, g.greenSat, g.cyanSat, g.blueSat, g.purpleSat]
        let hues = [g.redHue, g.orangeHue, g.yellowHue, g.greenHue, g.cyanHue, g.blueHue, g.purpleHue]
        let lums = [g.redLum, g.orangeLum, g.yellowLum, g.greenLum, g.cyanLum, g.blueLum, g.purpleLum]
        return sats.contains { abs($0) > 0.1 } || hues.contains { abs($0) > 0.1 } || lums.contains { abs($0) > 0.1 }
    }

    private static func hasToneCurve(_ g: ColorGrade) -> Bool {
        abs(g.curveShadow) > 0.005 || abs(g.curveMid) > 0.005 || abs(g.curveHighlight) > 0.005
    }

    private static func applyToneCurve(_ g: ColorGrade, to image: CIImage) -> CIImage {
        let s = min(max(0.25 + g.curveShadow * 0.24, 0.02), 0.48)
        let m = min(max(0.50 + g.curveMid * 0.30, s + 0.01), 0.98)
        let h = min(max(0.75 + g.curveHighlight * 0.24, m + 0.01), 0.98)
        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: CGFloat(s)), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: CGFloat(m)), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: CGFloat(h)), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    private static func applyCube(_ grade: ColorGrade, to image: CIImage) -> CIImage {
        let dimension: Float = 24
        let filter = CIFilter.colorCube()
        filter.inputImage = image
        filter.cubeDimension = dimension
        filter.cubeData = cubeData(for: grade)
        if #available(iOS 16.0, *) {
            filter.extrapolate = true
        }
        return filter.outputImage ?? image
    }

    private static func cubeData(for grade: ColorGrade) -> Data {
        let key = cacheKey(grade)
        cubeLock.lock()
        if let cached = cubeCache[key] {
            cubeLock.unlock()
            return cached
        }
        cubeLock.unlock()

        let dimension = 24
        var cube = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var offset = 0
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let rr = Float(r) / Float(dimension - 1)
                    let gg = Float(g) / Float(dimension - 1)
                    let bb = Float(b) / Float(dimension - 1)
                    let adjusted = adjustRGB(rr, gg, bb, grade)
                    cube[offset] = adjusted.0
                    cube[offset + 1] = adjusted.1
                    cube[offset + 2] = adjusted.2
                    cube[offset + 3] = 1
                    offset += 4
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }

        cubeLock.lock()
        if cubeCache.count > 16 { cubeCache.removeAll() }
        cubeCache[key] = data
        cubeLock.unlock()
        return data
    }

    private static func cacheKey(_ g: ColorGrade) -> String {
        let values = [g.redHue, g.redSat, g.redLum,
                      g.orangeHue, g.orangeSat, g.orangeLum,
                      g.yellowHue, g.yellowSat, g.yellowLum,
                      g.greenHue, g.greenSat, g.greenLum,
                      g.cyanHue, g.cyanSat, g.cyanLum,
                      g.blueHue, g.blueSat, g.blueLum,
                      g.purpleHue, g.purpleSat, g.purpleLum]
        return values.map { String(Int(($0 * 10).rounded())) }.joined(separator: ",")
    }

    private static func adjustRGB(_ r: Float, _ g: Float, _ b: Float, _ grade: ColorGrade) -> (Float, Float, Float) {
        var h: Float = 0
        var s: Float = 0
        var l: Float = 0
        rgbToHSL(r, g, b, &h, &s, &l)
        let deg = Double(h) * 360
        let adjustment: (Double, Double, Double)
        switch deg {
        case 345...360, 0..<15:
            adjustment = (grade.redHue, grade.redSat, grade.redLum)
        case 15..<45:
            adjustment = (grade.orangeHue, grade.orangeSat, grade.orangeLum)
        case 45..<75:
            adjustment = (grade.yellowHue, grade.yellowSat, grade.yellowLum)
        case 75..<165:
            adjustment = (grade.greenHue, grade.greenSat, grade.greenLum)
        case 165..<200:
            adjustment = (grade.cyanHue, grade.cyanSat, grade.cyanLum)
        case 200..<255:
            adjustment = (grade.blueHue, grade.blueSat, grade.blueLum)
        default:
            adjustment = (grade.purpleHue, grade.purpleSat, grade.purpleLum)
        }
        h = fmodPositive(h + Float(adjustment.0 / 360), 1)
        s = max(0, min(1, s * Float(max(0, 1 + adjustment.1 / 100))))
        l = max(0, min(1, l + Float(adjustment.2 / 100)))
        return hslToRGB(h, s, l)
    }

    private static func rgbToHSL(_ r: Float, _ g: Float, _ b: Float,
                                 _ h: inout Float, _ s: inout Float, _ l: inout Float) {
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        l = (maxV + minV) / 2
        let d = maxV - minV
        if d == 0 {
            h = 0
            s = 0
            return
        }
        let denominator = 1 - abs(2 * l - 1)
        s = denominator != 0 ? d / denominator : 0
        if maxV == r {
            h = (g - b) / d / 6
        } else if maxV == g {
            h = ((b - r) / d + 2) / 6
        } else {
            h = ((r - g) / d + 4) / 6
        }
        h = fmodPositive(h, 1)
    }

    private static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> (Float, Float, Float) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        return (hue(h + 1.0 / 3.0), hue(h), hue(h - 1.0 / 3.0))
    }

    private static func fmodPositive(_ value: Float, _ modulus: Float) -> Float {
        let x = value.truncatingRemainder(dividingBy: modulus)
        return x < 0 ? x + modulus : x
    }
}
