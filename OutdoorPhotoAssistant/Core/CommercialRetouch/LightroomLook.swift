import CoreImage
import CoreGraphics
import Foundation

// MARK: - 数据模型
//
// 这套参数是 Adobe Camera Raw / Lightroom 的 PV2012 开发参数语义，
// 字段名与 `crs:` XMP 键一一对应（见 LightroomPresetParser）。
// 参考实现与逆向来源：
//   * skymanbp/autoshade  `src/recipe.rs`（crs 键、范围、XMP 往返）
//   * alfanick/mini-film  `src/xmp.rs`（ToneCurvePV2012 / HSL 8 带的解析约定）
//   * darktable 手册 tone equalizer / filmic（掩膜式局部色调映射）
//   * RawTherapee RawPedia wavelet / local contrast（带通式清晰度）
// 单位与范围全部按 Adobe 约定，方便直接和 .xmp 互转。

/// 曲线上一个控制点。`input`/`output` 都是 0...255 的 Adobe 约定刻度。
struct LightroomCurvePoint: Codable, Equatable, Hashable {
    var input: Double
    var output: Double

    init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

/// 一套完整的 Lightroom 风格开发参数。
///
/// 分三类：
/// 1. **色调类**（exposure / contrast / highlights / shadows / whites / blacks / 曲线）——
///    决定明暗结构；
/// 2. **色彩类**（hsl 8 带 / vibrance / saturation / 分离色调）——决定风格；
/// 3. **细节类**（texture / clarity / dehaze / sharpness / grain / vignette）——决定质感。
///
/// 渲染顺序严格按 ACR 的真实顺序，见 `apply(to:skinMask:context:)` 的注释。
struct LightroomLook: Codable, Equatable, Hashable {
    var name: String = ""

    // 基础面板
    var exposure: Double = 0            // -5...5 EV
    var contrast: Double = 0            // -100...100
    var highlights: Double = 0          // -100...100，负值回收高光
    var shadows: Double = 0             // -100...100，正值提亮阴影
    var whites: Double = 0              // -100...100，白点
    var blacks: Double = 0              // -100...100，黑点
    var texture: Double = 0             // -100...100，中频细节（皮肤/织物/树叶）
    var clarity: Double = 0             // -100...100，低频局部对比（中间调体积感）
    var dehaze: Double = 0              // -100...100，去雾
    var vibrance: Double = 0            // -100...100，带肤色保护的饱和
    var saturation: Double = 0          // -100...100，均匀饱和

    // 参数化曲线（LR 的 4 段亮度权重）
    var parametricShadows: Double = 0
    var parametricDarks: Double = 0
    var parametricLights: Double = 0
    var parametricHighlights: Double = 0

    // 点曲线（复合曲线 + 三条分通道曲线）
    var toneCurve: [LightroomCurvePoint] = []
    var curveRed: [LightroomCurvePoint] = []
    var curveGreen: [LightroomCurvePoint] = []
    var curveBlue: [LightroomCurvePoint] = []

    // HSL / 颜色混合器：Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta
    var hslHue: [Double] = Array(repeating: 0, count: 8)
    var hslSaturation: [Double] = Array(repeating: 0, count: 8)
    var hslLuminance: [Double] = Array(repeating: 0, count: 8)

    // 分离色调（兼容新版 Color Grading 的阴影/高光两轮）
    var shadowHue: Double = 0           // 0...360
    var shadowSaturation: Double = 0    // 0...100
    var highlightHue: Double = 0
    var highlightSaturation: Double = 0
    var splitBalance: Double = 0        // -100...100

    // 细节
    var sharpness: Double = 0           // 0...150
    var sharpenRadius: Double = 1.0     // 0.5...3.0
    var sharpenMasking: Double = 0      // 0...100
    var grain: Double = 0               // 0...100
    var grainSize: Double = 25          // 0...100
    var vignette: Double = 0            // -100...100

    init() {}

    static let neutral = LightroomLook()

    /// 什么都不做（用来跳过整段渲染，省一次全图往返）。只比数值，不比名字。
    var isNeutral: Bool {
        var probe = self
        probe.name = ""
        return probe == LightroomLook.neutral
    }

    /// 按强度缩放。只缩“有方向的调整量”，不缩结构参数（半径、颗粒尺寸、色相）。
    func scaled(by strength: Double) -> LightroomLook {
        let s = strength.isFinite ? min(2.0, max(0.0, strength)) : 1.0
        guard s != 1.0 else { return self }
        var out = self
        out.exposure *= s
        out.contrast *= s
        out.highlights *= s
        out.shadows *= s
        out.whites *= s
        out.blacks *= s
        out.texture *= s
        out.clarity *= s
        out.dehaze *= s
        out.vibrance *= s
        out.saturation *= s
        out.parametricShadows *= s
        out.parametricDarks *= s
        out.parametricLights *= s
        out.parametricHighlights *= s
        out.hslHue = out.hslHue.map { $0 * s }
        out.hslSaturation = out.hslSaturation.map { $0 * s }
        out.hslLuminance = out.hslLuminance.map { $0 * s }
        out.shadowSaturation *= s
        out.highlightSaturation *= s
        // 掩膜（sharpenMasking）是结构参数，不随强度缩
        out.sharpness *= s
        out.grain *= s
        out.vignette *= s
        // 曲线按强度往“恒等”方向插值
        out.toneCurve = Self.scaledCurve(self.toneCurve, by: s)
        out.curveRed = Self.scaledCurve(self.curveRed, by: s)
        out.curveGreen = Self.scaledCurve(self.curveGreen, by: s)
        out.curveBlue = Self.scaledCurve(self.curveBlue, by: s)
        return out
    }

    private static func scaledCurve(_ points: [LightroomCurvePoint], by s: Double) -> [LightroomCurvePoint] {
        guard s != 1.0 else { return points }
        return points.map { point in
            LightroomCurvePoint(input: point.input,
                                output: point.input + (point.output - point.input) * s)
        }
    }

    /// clamp 到 Adobe 约定范围，顺手把非有限值清零（手写/Hostile XMP 都能吃）。
    func clamped() -> LightroomLook {
        var out = self
        func c(_ v: Double, _ lo: Double, _ hi: Double, _ neutral: Double = 0) -> Double {
            v.isFinite ? min(hi, max(lo, v)) : neutral
        }
        out.exposure = c(exposure, -5, 5)
        out.contrast = c(contrast, -100, 100)
        out.highlights = c(highlights, -100, 100)
        out.shadows = c(shadows, -100, 100)
        out.whites = c(whites, -100, 100)
        out.blacks = c(blacks, -100, 100)
        out.texture = c(texture, -100, 100)
        out.clarity = c(clarity, -100, 100)
        out.dehaze = c(dehaze, -100, 100)
        out.vibrance = c(vibrance, -100, 100)
        out.saturation = c(saturation, -100, 100)
        out.parametricShadows = c(parametricShadows, -100, 100)
        out.parametricDarks = c(parametricDarks, -100, 100)
        out.parametricLights = c(parametricLights, -100, 100)
        out.parametricHighlights = c(parametricHighlights, -100, 100)
        out.shadowHue = c(shadowHue, 0, 360).truncatingRemainder(dividingBy: 360)
        if out.shadowHue < 0 { out.shadowHue += 360 }
        out.shadowSaturation = c(shadowSaturation, 0, 100)
        out.highlightHue = c(highlightHue, 0, 360).truncatingRemainder(dividingBy: 360)
        if out.highlightHue < 0 { out.highlightHue += 360 }
        out.highlightSaturation = c(highlightSaturation, 0, 100)
        out.splitBalance = c(splitBalance, -100, 100)
        out.sharpness = c(sharpness, 0, 150)
        out.sharpenRadius = c(min(max(sharpenRadius, 0.5), 3.0), 0.5, 3.0, 1.0)
        out.sharpenMasking = c(sharpenMasking, 0, 100)
        out.grain = c(grain, 0, 100)
        out.grainSize = c(min(max(grainSize, 0), 100), 0, 100, 25)
        out.vignette = c(vignette, -100, 100)
        out.hslHue = Self.normalizedArray(hslHue)
        out.hslSaturation = Self.normalizedArray(hslSaturation)
        out.hslLuminance = Self.normalizedArray(hslLuminance)
        out.toneCurve = Self.normalizedCurve(toneCurve)
        out.curveRed = Self.normalizedCurve(curveRed)
        out.curveGreen = Self.normalizedCurve(curveGreen)
        out.curveBlue = Self.normalizedCurve(curveBlue)
        return out
    }

    private static func normalizedArray(_ values: [Double]) -> [Double] {
        var out = Array(repeating: 0.0, count: 8)
        for i in 0..<min(8, values.count) {
            let v = values[i]
            out[i] = v.isFinite ? min(100, max(-100, v)) : 0
        }
        return out
    }

    /// 曲线点规范化：clamp 到 0...255、按 x 排序、同 x 只留最后一个、最多 32 个点。
    private static func normalizedCurve(_ points: [LightroomCurvePoint]) -> [LightroomCurvePoint] {
        var cleaned: [LightroomCurvePoint] = []
        for point in points {
            guard point.input.isFinite, point.output.isFinite else { continue }
            let x = min(255, max(0, point.input))
            let y = min(255, max(0, point.output))
            cleaned.append(LightroomCurvePoint(input: x, output: y))
        }
        guard !cleaned.isEmpty else { return [] }
        cleaned.sort { $0.input < $1.input }
        var unique: [LightroomCurvePoint] = []
        for point in cleaned {
            if let last = unique.last, abs(last.input - point.input) < 0.0001 {
                unique[unique.count - 1] = point
            } else {
                unique.append(point)
            }
        }
        if unique.count > 32 { unique = Array(unique.prefix(32)) }
        return unique
    }
}

// MARK: - 纯色调数学（可单测，不依赖 Core Image）

/// 1D 色调映射：端点 → 对比 S 曲线 → 用户点曲线。
///
/// 为什么拆这三段：LR 的 Whites/Blacks 是**端点位移**，Contrast 是**支点幂律**，
/// 点曲线是**手绘锚点**——三者作用域不同，混成一个公式就会互相污染。
enum LightroomTone {
    /// 对比支点。0.46 是 sRGB 中灰（线性 0.18 编码后约 0.46），和 ACR 一致。
    static let contrastPivot = 0.46

    /// 端点位移。blacks>0 抬黑位（阴影变亮），whites>0 提前到达白点（高光更亮）。
    static func endpoints(_ x: Double, blacks: Double, whites: Double) -> Double {
        let b = -min(100, max(-100, blacks)) / 100 * 0.06
        let w = 1 - min(100, max(-100, whites)) / 100 * 0.08
        let span = max(0.2, w - b)
        return min(1, max(0, (x - b) / span))
    }

    /// 支点幂律 S 曲线：0→0、pivot→pivot、1→1，单调，两端不动。
    static func contrastCurve(_ x: Double, contrast: Double) -> Double {
        let v = min(1, max(0, x))
        let c = min(100, max(-100, contrast)) / 100
        guard abs(c) > 0.0001 else { return v }
        let e = 1 + 0.60 * c
        let p = contrastPivot
        if v <= p {
            return p * pow(max(v, 0) / p, e)
        }
        return 1 - (1 - p) * pow(max(1 - v, 0) / (1 - p), e)
    }

    /// 参数化曲线的 4 段权重（LR 的 Shadows/Darks/Lights/Highlights）。
    /// 每段是一个平滑窗，相加后作为“亮度增益”的调制，而不是位移。
    static func parametricGain(luma: Double, look: LightroomLook) -> Double {
        let l = min(1, max(0, luma))
        let shadows = smoothstep(0.35, 0.0, l)          // 0...0.35 最强
        let darks = bell(l, center: 0.30, width: 0.28)
        let lights = bell(l, center: 0.70, width: 0.28)
        let highlights = smoothstep(0.65, 1.0, l)
        let amount = (look.parametricShadows * shadows
                      + look.parametricDarks * darks
                      + look.parametricLights * lights
                      + look.parametricHighlights * highlights) / 100
        return 1 + amount * 0.45
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    static func bell(_ x: Double, center: Double, width: Double) -> Double {
        let d = abs(x - center) / max(0.0001, width)
        return d >= 1 ? 0 : (1 - d * d) * (1 - d * d)
    }

    // MARK: 点曲线（Fritsch–Carlson 单调三次，不产生过冲）

    /// 把曲线点采样成 256 项 LUT（输入 0...1 → 输出 0...1）。
    /// 空曲线返回恒等表；单点返回常数；两点线性。
    static func curveLUT(_ points: [LightroomCurvePoint], count: Int = 256) -> [Double] {
        var lut = (0..<count).map { Double($0) / Double(count - 1) }
        guard !points.isEmpty else { return lut }
        let xs = points.map { min(255, max(0, $0.input)) / 255 }
        let ys = points.map { min(255, max(0, $0.output)) / 255 }
        guard xs.count >= 2 else {
            let y = ys.first ?? 0
            return Array(repeating: y, count: count)
        }
        let tangents = monotoneTangents(xs: xs, ys: ys)
        for i in 0..<count {
            let x = Double(i) / Double(count - 1)
            lut[i] = min(1, max(0, hermite(x: x, xs: xs, ys: ys, tangents: tangents)))
        }
        return lut
    }

    /// Fritsch–Carlson 切线：保证插值单调、不过冲（曲线最怕 S 形回勾）。
    private static func monotoneTangents(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = xs[i + 1] - xs[i]
            delta[i] = dx == 0 ? 0 : (ys[i + 1] - ys[i]) / dx
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            if delta[i - 1] * delta[i] <= 0 {
                m[i] = 0
            } else {
                m[i] = (delta[i - 1] + delta[i]) / 2
            }
        }
        for i in 0..<(n - 1) {
            if delta[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / delta[i]
            let b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }
        return m
    }

    private static func hermite(x: Double, xs: [Double], ys: [Double], tangents: [Double]) -> Double {
        if x <= xs[0] { return ys[0] + tangents[0] * (x - xs[0]) }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        guard h > 0 else { return ys[i] }
        let t = (x - xs[i]) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * ys[i] + h10 * h * tangents[i] + h01 * ys[i + 1] + h11 * h * tangents[i + 1]
    }

    static func sampleLUT(_ lut: [Double], _ x: Double) -> Double {
        guard !lut.isEmpty else { return x }
        let v = min(1, max(0, x)) * Double(lut.count - 1)
        let i0 = Int(v)
        let i1 = min(lut.count - 1, i0 + 1)
        let t = v - Double(i0)
        return lut[i0] * (1 - t) + lut[i1] * t
    }

    /// 完整 1D 色调：端点 → 对比 → 点曲线。
    static func map(_ x: Double, look: LightroomLook) -> Double {
        var v = endpoints(x, blacks: look.blacks, whites: look.whites)
        v = contrastCurve(v, contrast: look.contrast)
        if !look.toneCurve.isEmpty {
            v = sampleLUT(curveLUT(look.toneCurve), v)
        }
        return min(1, max(0, v))
    }
}

// MARK: - 纯色彩数学（HSV + 8 带 HSL + 分离色调）

enum LightroomColor {
    /// LR 的 8 个色带中心（度）。相邻带重叠 60°，所以调橙色会轻微带动红和黄。
    static let bandCenters: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]

    static func rgbToHSV(_ c: SIMD3<Double>) -> (h: Double, s: Double, v: Double) {
        let r = c.x, g = c.y, b = c.z
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        var h = 0.0
        if delta > 1e-9 {
            if maxV == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxV == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        let s = maxV <= 1e-9 ? 0 : delta / maxV
        return (h, s, maxV)
    }

    static func hsvToRGB(h: Double, s: Double, v: Double) -> SIMD3<Double> {
        let hue = h.truncatingRemainder(dividingBy: 360)
        let hh = (hue < 0 ? hue + 360 : hue) / 60
        let c = v * s
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let base: SIMD3<Double>
        switch Int(hh) % 6 {
        case 0: base = SIMD3(c, x, 0)
        case 1: base = SIMD3(x, c, 0)
        case 2: base = SIMD3(0, c, x)
        case 3: base = SIMD3(0, x, c)
        case 4: base = SIMD3(x, 0, c)
        default: base = SIMD3(c, 0, x)
        }
        return SIMD3(base.x + m, base.y + m, base.z + m)
    }

    /// 8 带三角权重（按最邻近两带分摊，和归一化）。
    static func bandWeights(hue: Double) -> [Double] {
        var weights = [Double](repeating: 0, count: 8)
        for i in 0..<8 {
            var d = abs(hue - bandCenters[i])
            if d > 180 { d = 360 - d }
            weights[i] = max(0, 1 - d / 60)
        }
        let sum = weights.reduce(0, +)
        if sum > 0 { weights = weights.map { $0 / sum } }
        return weights
    }

    /// 应用 HSL 8 带：色相 ±100 → ±30°，饱和 ±100 → ×0.9，明度 ±100 → ×0.7。
    static func applyHSL(_ rgb: SIMD3<Double>, look: LightroomLook) -> SIMD3<Double> {
        var hsv = rgbToHSV(rgb)
        guard hsv.v > 0.0005 else { return rgb }
        let weights = bandWeights(hue: hsv.h)
        var hueShift = 0.0
        var satShift = 0.0
        var lumShift = 0.0
        for i in 0..<8 {
            hueShift += weights[i] * look.hslHue[i]
            satShift += weights[i] * look.hslSaturation[i]
            lumShift += weights[i] * look.hslLuminance[i]
        }
        guard abs(hueShift) + abs(satShift) + abs(lumShift) > 0.0001 else { return rgb }
        // 低饱和像素本来就没有可信色相，色相旋转按饱和度衰减，避免灰面被推色
        hsv.h += hueShift * 0.30 * min(1, hsv.s * 1.6)
        hsv.s = min(1, max(0, hsv.s * (1 + satShift / 100 * 0.9)))
        hsv.v = min(1, max(0, hsv.v * (1 + lumShift / 100 * 0.7)))
        return hsvToRGB(h: hsv.h, s: hsv.s, v: hsv.v)
    }

    /// 分离色调：阴影/高光各染一层，用乘法保留明暗结构（直接加色会发灰）。
    static func applySplitToning(_ rgb: SIMD3<Double>, look: LightroomLook) -> SIMD3<Double> {
        let shadowAmount = min(100, max(0, look.shadowSaturation))
        let highlightAmount = min(100, max(0, look.highlightSaturation))
        guard shadowAmount > 0.01 || highlightAmount > 0.01 else { return rgb }
        let luma = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        let balance = min(100, max(-100, look.splitBalance)) / 100 * 0.15
        let shadowWeight = LightroomTone.smoothstep(0.58 - balance, 0.10 - balance, luma)
        let highlightWeight = LightroomTone.smoothstep(0.42 + balance, 0.90 + balance, luma)
        var out = rgb
        if shadowAmount > 0.01 && shadowWeight > 0.001 {
            let tint = hsvToRGB(h: look.shadowHue, s: 1, v: 1)
            let k = min(0.5, shadowAmount / 100 * 0.45) * shadowWeight
            out = out * (SIMD3(1, 1, 1) - SIMD3(k, k, k)) + out * tint * SIMD3(k, k, k)
        }
        if highlightAmount > 0.01 && highlightWeight > 0.001 {
            let tint = hsvToRGB(h: look.highlightHue, s: 1, v: 1)
            let k = min(0.5, highlightAmount / 100 * 0.40) * highlightWeight
            out = out * (SIMD3(1, 1, 1) - SIMD3(k, k, k)) + out * tint * SIMD3(k, k, k)
        }
        return SIMD3(min(1, max(0, out.x)), min(1, max(0, out.y)), min(1, max(0, out.z)))
    }

    /// 单点立方体采样（CPU 端烘焙 3D LUT 用）。
    static func cubeSample(rgb: SIMD3<Double>, look: LightroomLook,
                           toneLUT: [Double], lutR: [Double], lutG: [Double], lutB: [Double]) -> SIMD3<Double> {
        // 1) 复合色调（逐通道，ACR 也是逐通道上曲线）
        var c = SIMD3(LightroomTone.sampleLUT(toneLUT, rgb.x),
                      LightroomTone.sampleLUT(toneLUT, rgb.y),
                      LightroomTone.sampleLUT(toneLUT, rgb.z))
        // 2) 分通道曲线
        if !lutR.isEmpty { c.x = LightroomTone.sampleLUT(lutR, c.x) }
        if !lutG.isEmpty { c.y = LightroomTone.sampleLUT(lutG, c.y) }
        if !lutB.isEmpty { c.z = LightroomTone.sampleLUT(lutB, c.z) }
        // 3) HSL 8 带
        c = applyHSL(c, look: look)
        // 4) 分离色调
        c = applySplitToning(c, look: look)
        return SIMD3(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z)))
    }
}

// MARK: - 内置 Look（把我们已有的 6 个风格翻译成 LR 参数）

enum LightroomLookCatalog {
    /// 六个内置风格。数值是按“商业自然 → 电影感 → 夜景”这条线手工配的，
    /// 全部落在 QC 门禁能过的范围里（不加过量的 clarity/dehaze）。
    static func look(for style: RetouchLook) -> LightroomLook {
        switch style {
        case .commercialNatural:
            var l = LightroomLook()
            l.name = "商业自然"
            l.contrast = 7
            l.whites = 4
            l.blacks = -3
            l.texture = 8
            l.clarity = 6
            l.vibrance = 8
            l.hslSaturation = [4, 5, 2, 0, 0, 0, 0, 0]
            l.hslLuminance = [2, 3, 1, 0, 0, 0, 0, 0]
            l.shadowHue = 210; l.shadowSaturation = 4
            l.highlightHue = 40; l.highlightSaturation = 5
            return l
        case .refinedPortrait:
            var l = LightroomLook()
            l.name = "精致写真"
            l.contrast = 9
            l.texture = 4
            l.clarity = 3
            l.vibrance = 6
            l.hslSaturation = [3, 6, 2, 0, 0, 0, 0, 0]
            l.hslLuminance = [2, 5, 2, 0, 0, 0, 0, 0]
            l.shadowHue = 220; l.shadowSaturation = 5
            l.highlightHue = 35; l.highlightSaturation = 6
            return l
        case .cinematic:
            var l = LightroomLook()
            l.name = "电影人像"
            l.contrast = 13
            l.blacks = -8
            l.highlights = -8
            l.texture = 6
            l.clarity = 8
            l.vibrance = 4
            l.saturation = -6
            l.hslHue = [0, 0, 0, -12, -8, -6, 0, 0]
            l.hslSaturation = [0, 2, 0, 6, 5, 4, 0, 0]
            l.shadowHue = 200; l.shadowSaturation = 12
            l.highlightHue = 45; l.highlightSaturation = 9
            l.splitBalance = -10
            return l
        case .freshJapanese:
            var l = LightroomLook()
            l.name = "清新日系"
            l.exposure = 0.10
            l.contrast = -5
            l.blacks = 6
            l.whites = 5
            l.texture = 3
            l.clarity = -3
            l.vibrance = 10
            l.saturation = -4
            l.hslHue = [0, 0, 0, 8, 6, 0, 0, 0]
            l.hslSaturation = [0, -4, 2, 8, 6, 0, 0, 0]
            l.hslLuminance = [2, 6, 4, 2, 0, 0, 0, 0]
            l.shadowHue = 200; l.shadowSaturation = 3
            l.highlightHue = 55; l.highlightSaturation = 6
            return l
        case .landscapeNatural:
            var l = LightroomLook()
            l.name = "自然风光"
            l.contrast = 8
            l.texture = 12
            l.clarity = 10
            l.vibrance = 14
            l.dehaze = 6
            l.hslHue = [0, 0, -4, -6, -4, 0, 0, 0]
            l.hslSaturation = [0, 0, 4, 10, 8, 8, 0, 0]
            l.hslLuminance = [0, 0, -2, -2, -4, -6, 0, 0]
            l.shadowHue = 200; l.shadowSaturation = 3
            l.highlightHue = 50; l.highlightSaturation = 4
            return l
        case .nightClear:
            var l = LightroomLook()
            l.name = "深夜清透"
            l.contrast = 12
            l.highlights = -14
            l.shadows = 10
            l.blacks = -4
            l.texture = 6
            l.clarity = 6
            l.vibrance = 8
            l.saturation = -4
            l.dehaze = 4
            l.hslSaturation = [0, 0, 0, 0, 4, 6, 4, 0]
            l.hslLuminance = [0, 0, 0, 0, 2, 6, 4, 0]
            l.shadowHue = 230; l.shadowSaturation = 10
            l.highlightHue = 45; l.highlightSaturation = 6
            return l
        }
    }
}

// MARK: - 渲染（Core Image 阶段）

extension LightroomLook {

    /// 按 ACR/LR 的真实顺序渲染：
    ///
    /// 1. 曝光（线性域增益）
    /// 2. 高光回收 / 阴影提亮（掩膜式局部色调映射，用大半径 base 防光晕）
    /// 3. 去雾（暗通道先验，暗通道在代理上估）
    /// 4. **一次性 3D LUT**：端点 → 对比 → 点曲线 → 分通道曲线 → HSL 8 带 → 分离色调
    /// 5. Clarity / Texture（带通，中间调掩膜，默认避开皮肤）
    /// 6. Vibrance / Saturation（Vibrance 带肤色保护）
    /// 7. 锐化（含边缘掩膜）→ 颗粒 → 暗角
    ///
    /// `skinMask` 传进来时 Clarity/Texture/锐化都会避开皮肤，这是商业精修和
    /// 随手调色的分界线。强度请先过 `scaled(by:)` 再进来，这里不再处理。
    ///
    /// **实现已切到 `ACRDevelopEngine`**（Camera Raw 18.7 逆向复刻版）：
    /// 曝光走线性增益、高光/阴影走引导滤波 base、去雾走完整暗通道先验、
    /// Clarity 走 LocalContrastY、Texture 走 YCC 直接引导滤波、锐化走三尺度带阈值 USM、
    /// 降噪/颜色分级/颗粒/暗角都是独立阶段。想回退旧实现把下面这行换成
    /// `return applyLegacy(to: image, skinMask: skinMask, context: context)`。
    func apply(to image: CIImage, skinMask: CIImage? = nil, context: CIContext) -> CIImage {
        return ACRDevelopEngine.render(image,
                                       settings: acrSettings,
                                       skinMask: skinMask,
                                       profile: nil,
                                       context: context)
    }

    /// 旧的 Core Image 拼装实现，保留做对照（AB 测试 / 回归对比用）。
    func applyLegacy(to image: CIImage, skinMask: CIImage? = nil, context: CIContext) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 1, extent.height > 1 else { return image }
        guard !isNeutral else { return image }
        var work = image

        // 1. 曝光
        if abs(exposure) > 0.001 {
            work = work.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }

        // 2. 高光 / 阴影（半径按长边给，一次全图，halo 由 base 半径压住）
        if abs(highlights) > 0.5 || abs(shadows) > 0.5 {
            let radius = max(6, min(120, extent.width / 24))
            let shadowAmount = min(1, max(-1, shadows / 100)) * 0.9
            let highlightAmount = 1 - min(1, max(-1, -highlights / 100)) * 0.55
            work = work.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": shadowAmount,
                "inputHighlightAmount": highlightAmount,
                "inputRadius": radius
            ])
        }

        // 3. 去雾
        if abs(dehaze) > 0.5 {
            work = applyDehaze(to: work, amount: dehaze, context: context)
        }

        // 4. 3D LUT（曲线 + HSL + 分离色调）
        if let cube = Self.cubeData(for: self, size: 33) {
            work = work.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": 33,
                "inputCubeData": cube
            ])
        }

        // 5. Clarity / Texture
        if abs(clarity) > 0.5 {
            work = localContrast(work, radius: max(18, extent.width / 40), amount: clarity / 100 * 0.55,
                                 midtoneOnly: true, skinMask: skinMask)
        }
        if abs(texture) > 0.5 {
            work = localContrast(work, radius: max(2, extent.width / 380), amount: texture / 100 * 0.75,
                                 midtoneOnly: false, skinMask: skinMask)
        }

        // 6. Vibrance / Saturation
        if abs(vibrance) > 0.5, let kernel = LightroomKernels.vibrance {
            work = kernel.apply(extent: extent, arguments: [work, Float(vibrance / 100)]) ?? work
        }
        if abs(saturation) > 0.5 {
            work = work.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + saturation / 100
            ])
        }

        // 7. 锐化 / 颗粒 / 暗角
        if sharpness > 0.5 {
            work = sharpen(work, skinMask: skinMask, extent: extent)
        }
        if grain > 0.5 {
            work = addGrain(work, extent: extent)
        }
        if abs(vignette) > 0.5 {
            work = work.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: vignette / 100,
                kCIInputRadiusKey: 1.6
            ])
        }
        return work.cropped(to: extent)
    }

    // MARK: 3D LUT 烘焙

    /// 33³ 的 float32 RGBA 立方体（CIColorCube 要求 R 变化最快）。
    /// 结果进 NSCache：同一套参数只算一次（约 3.6 万个采样点，主线程 ~2ms 级）。
    static func cubeData(for look: LightroomLook, size: Int) -> Data? {
        let n = max(2, min(64, size))
        let key = NSString(string: "\(look.hashValue)-\(n)")
        if let cached = LightroomCubeCache.shared.object(forKey: key) { return cached as Data }

        let lookup = look.clamped()
        let toneLUT = LightroomTone.curveLUT(lookup.toneCurve)
        let lutR = lookup.curveRed.isEmpty ? [Double]() : LightroomTone.curveLUT(lookup.curveRed)
        let lutG = lookup.curveGreen.isEmpty ? [Double]() : LightroomTone.curveLUT(lookup.curveGreen)
        let lutB = lookup.curveBlue.isEmpty ? [Double]() : LightroomTone.curveLUT(lookup.curveBlue)
        // 参数化曲线折进复合 LUT，避免再跑一次全图
        var toned = toneLUT
        if abs(lookup.parametricShadows) + abs(lookup.parametricDarks)
            + abs(lookup.parametricLights) + abs(lookup.parametricHighlights) > 0.5 {
            toned = (0..<toned.count).map { i in
                let x = Double(i) / Double(toned.count - 1)
                let gain = LightroomTone.parametricGain(luma: toneLUT[i], look: lookup)
                return min(1, max(0, toneLUT[i] + (gain - 1) * x * 0.6))
            }
        }
        // 端点位移/对比/点曲线已经在曲线阶段之外，这里把 toneCurve 直接算进 LUT
        var composed = [Double](repeating: 0, count: 256)
        for i in 0..<256 {
            let x = Double(i) / 255
            var v = LightroomTone.endpoints(x, blacks: lookup.blacks, whites: lookup.whites)
            v = LightroomTone.contrastCurve(v, contrast: lookup.contrast)
            v = LightroomTone.sampleLUT(toned, v)
            composed[i] = min(1, max(0, v))
        }

        var floats = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        for b in 0..<n {
            let vb = Double(b) / Double(n - 1)
            for g in 0..<n {
                let vg = Double(g) / Double(n - 1)
                for r in 0..<n {
                    let vr = Double(r) / Double(n - 1)
                    let out = LightroomColor.cubeSample(rgb: SIMD3(vr, vg, vb), look: lookup,
                                                        toneLUT: composed,
                                                        lutR: lutR, lutG: lutG, lutB: lutB)
                    floats[index + 0] = Float(out.x)
                    floats[index + 1] = Float(out.y)
                    floats[index + 2] = Float(out.z)
                    floats[index + 3] = 1
                    index += 4
                }
            }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        LightroomCubeCache.shared.setObject(data as NSData, forKey: key)
        return data
    }

    // MARK: 子阶段

    /// 去雾：暗通道先验。A（大气光）在 96px 代理上按“暗通道最亮的 0.1%”估。
    private func applyDehaze(to image: CIImage, amount: Double, context: CIContext) -> CIImage {
        let extent = image.extent
        let strength = min(0.95, max(0, amount / 100))
        guard strength > 0.001, let atmosphere = Self.atmosphericLight(image, context: context) else {
            // 估不出大气光就退化成“压黑点 + 提对比”，至少方向是对的
            let gain = 1 + strength * 0.25
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: gain,
                kCIInputBrightnessKey: -strength * 0.02
            ])
        }
        guard let kernel = LightroomKernels.dehaze else { return image }
        return kernel.apply(extent: extent, arguments: [image, atmosphere, Float(strength)]) ?? image
    }

    /// 暗通道先验的大气光：取暗通道最亮的那一小撮像素的颜色均值。
    static func atmosphericLight(_ image: CIImage, context: CIContext) -> CIColor? {
        guard let proxy = PixelKit.renderRGBA8(image, maxEdge: 96, context: context),
              proxy.width > 0, proxy.height > 0 else { return nil }
        let count = proxy.width * proxy.height
        guard count > 16, proxy.bytes.count >= count * 4 else { return nil }
        // 每个像素的暗通道值 + 亮度，取最亮的 0.1%
        var samples: [(dark: Float, r: Float, g: Float, b: Float)] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let o = i * 4
            let r = Float(proxy.bytes[o]) / 255
            let g = Float(proxy.bytes[o + 1]) / 255
            let b = Float(proxy.bytes[o + 2]) / 255
            samples.append((min(r, min(g, b)), r, g, b))
        }
        samples.sort { $0.dark > $1.dark }
        let take = max(1, count / 1000)
        var sr: Float = 0, sg: Float = 0, sb: Float = 0
        for i in 0..<take {
            sr += samples[i].r; sg += samples[i].g; sb += samples[i].b
        }
        let k = Float(take)
        return CIColor(red: CGFloat(sr / k), green: CGFloat(sg / k), blue: CGFloat(sb / k), alpha: 1)
    }

    /// 带通局部对比（= LR 的 Clarity/Texture 简化模型：unsharp + 掩膜 + 皮肤保护）。
    private func localContrast(_ image: CIImage, radius: CGFloat, amount: Double,
                               midtoneOnly: Bool, skinMask: CIImage?) -> CIImage {
        guard amount > 0.001 else { return image }
        let extent = image.extent
        let boosted = image.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount
        ]).cropped(to: extent)
        var mask: CIImage?
        if midtoneOnly, let kernel = LightroomKernels.midtone {
            mask = kernel.apply(extent: extent, arguments: [image])?.cropped(to: extent)
        }
        if let skin = skinMask?.cropped(to: extent), let baseMask = mask {
            let invert = skin.applyingFilter("CIColorInvert")
            let product = baseMask.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: invert
            ])
            mask = product.cropped(to: extent)
        } else if let skin = skinMask?.cropped(to: extent), mask == nil {
            mask = skin.applyingFilter("CIColorInvert").cropped(to: extent)
        }
        guard let finalMask = mask else { return boosted }
        return PixelKit.blend(boosted, over: image, mask: finalMask)
    }

    /// 锐化：amount 0...150 → 0...1.2 强度，masking 越高越只作用于边缘。
    ///
    /// 边缘掩膜用 `CIEdges` 的梯度幅值，而不是亮度阈值——LR 的 Sharpening
    /// masking 只保护平坦区，不影响亮度高的边缘。
    private func sharpen(_ image: CIImage, skinMask: CIImage?, extent: CGRect) -> CIImage {
        let amount = min(1.2, sharpness / 150 * 1.2)
        let sharpened = image.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: amount,
            kCIInputRadiusKey: max(0.5, min(3.0, sharpenRadius))
        ]).cropped(to: extent)
        guard sharpenMasking > 0.5 else { return sharpened }
        let masking = min(1, max(0, sharpenMasking / 100))
        // 梯度幅值 → [0,1] 掩膜，masking 越大门限越高（只保边缘）
        let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4.0])
            .cropped(to: extent)
        let boost = CIFilter.colorMatrix()
        boost.inputImage = edges
        boost.rVector = CIVector(x: 1 + masking * 20, y: 0, z: 0, w: 0)
        boost.gVector = CIVector(x: 0, y: 1 + masking * 20, z: 0, w: 0)
        boost.bVector = CIVector(x: 0, y: 0, z: 1 + masking * 20, w: 0)
        boost.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let edgeMask = boost.outputImage?.cropped(to: extent) else { return sharpened }
        let finalMask = skinMask.map { skin in
            edgeMask.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: skin.cropped(to: extent).applyingFilter("CIColorInvert")
            ]).cropped(to: extent)
        } ?? edgeMask
        return PixelKit.blend(sharpened, over: image, mask: finalMask)
    }

    /// 胶片颗粒：CIRandomGenerator → 去饱和 → 柔光叠加，size 只影响颗粒尺度。
    private func addGrain(_ image: CIImage, extent: CGRect) -> CIImage {
        let amount = min(1, grain / 100)
        guard amount > 0.001, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let scale = 1 + min(1, max(0, grainSize / 100)) * 2   // 颗粒越大，采样越粗
        var grained = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: extent)
        grained = grained.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 0.5
        ])
        grained = grained.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(amount * 0.35), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(amount * 0.35), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amount * 0.35), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 1)
        ])
        let blended = grained.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ])
        return blended.cropped(to: extent)
    }

}

// MARK: - 全文件共享的 kernel 与缓存
//
// 放在 extension 外面：类型级存储属性写在 extension 里虽然合法，但把 kernel
// 统一收在一个 enum 里更好查，也避免每次改动都要跨 extension 找定义。

private enum LightroomKernels {
    /// Vibrance：按 (1 - 饱和度) 加权，并对肤色色相做保护（LR 的 Vibrance 也是这个思路）。
    static let vibrance = CIColorKernel(source: """
        kernel vec4 lightroomVibrance(__sample s, float amount) {
            float mx = max(max(s.r, s.g), s.b);
            float mn = min(min(s.r, s.g), s.b);
            float sat = mx <= 1.0e-5 ? 0.0 : (mx - mn) / mx;
            // 肤色：R 明显高于 B，且 G 夹在中间
            float skin = smoothstep(0.02, 0.14, s.r - s.b)
                       * (1.0 - smoothstep(0.16, 0.48, s.g - max(s.r, s.b)));
            float weight = (1.0 - sat) * (1.0 - 0.65 * skin);
            float gain = 1.0 + amount * weight;
            float luma = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
            vec3 rgb = vec3(luma) + (s.rgb - vec3(luma)) * gain;
            return vec4(clamp(rgb, 0.0, 1.0), s.a);
        }
        """)

    /// 中间调掩膜：0.05 以下和 0.96 以上衰减，给 Clarity 用（保护死黑与纯白）。
    static let midtone = CIColorKernel(source: """
        kernel vec4 lightroomMidtone(__sample s) {
            float luma = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
            float low = smoothstep(0.05, 0.28, luma);
            float high = 1.0 - smoothstep(0.72, 0.96, luma);
            float mask = low * high;
            return vec4(mask, mask, mask, 1.0);
        }
        """)

    /// 去雾：J = (I - A) / max(t, 0.2) + A，t 由暗通道估（dark channel prior）。
    static let dehaze = CIColorKernel(source: """
        kernel vec4 lightroomDehaze(__sample s, vec3 atmosphere, float strength) {
            float dark = min(s.r, min(s.g, s.b));
            float a = max(0.02, dot(atmosphere, vec3(0.3333)));
            float t = 1.0 - 0.92 * strength * clamp(dark / a, 0.0, 1.0);
            t = clamp(t, 0.2, 1.0);
            vec3 rgb = (s.rgb - atmosphere) / t + atmosphere;
            // 去雾后整体会变亮变艳，按强度混回去，避免“塑料天”
            rgb = mix(s.rgb, rgb, strength);
            return vec4(clamp(rgb, 0.0, 1.0), s.a);
        }
        """)
}

/// 3D LUT 缓存：同一套参数只烘焙一次。键用 `LightroomLook` 的 hash。
private enum LightroomCubeCache {
    static let shared = NSCache<NSString, NSData>()
}

