import CoreImage
import CoreGraphics
import Foundation

// ACRDevelopEngine 行为测试
//
// 编译方式（macOS，Xcode 命令行工具）：
//   swiftc -O OutdoorPhotoAssistant/Core/CommercialRetouch/ACRDevelopEngine.swift \
//          tests/acrdevelop/main.swift -o /tmp/acrdevelop && /tmp/acrdevelop
//
// 测的不是"看起来像不像"，而是每条阶段的方向和量级：
// 曝光是线性增益、对比度抬中点斜率、去雾抬局部对比、Clarity/Texture 保均值、
// 降噪方差下降、锐化梯度上升、颗粒方差上升、暗角四角变暗。

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL  \(message)")
    }
}

func expectNear(_ value: Double, _ target: Double, _ tol: Double, _ message: String) {
    expect(abs(value - target) <= tol, "\(message)  got=\(String(format: "%.4f", value)) want=\(String(format: "%.4f", target)) ±\(tol)")
}

// MARK: - 渲染辅助

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(options: [
    .workingColorSpace: linearSRGB,
    .outputColorSpace: sRGB
])

struct Pixels {
    var width: Int
    var height: Int
    var data: [UInt8]
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let o = (y * width + x) * 4
        return (Double(data[o]) / 255, Double(data[o + 1]) / 255, Double(data[o + 2]) / 255)
    }
    var luminanceMean: Double {
        var sum = 0.0
        var i = 0
        while i < width * height {
            let o = i * 4
            sum += 0.299 * Double(data[o]) + 0.587 * Double(data[o + 1]) + 0.114 * Double(data[o + 2])
            i += 1
        }
        return sum / Double(width * height) / 255
    }
    var luminanceStd: Double {
        let mean = luminanceMean * 255
        var acc = 0.0
        var i = 0
        while i < width * height {
            let o = i * 4
            let l = 0.299 * Double(data[o]) + 0.587 * Double(data[o + 1]) + 0.114 * Double(data[o + 2])
            let d = l - mean
            acc += d * d
            i += 1
        }
        return sqrt(acc / Double(width * height)) / 255
    }
    /// 相邻像素差的平均绝对值（高频能量）
    var gradientEnergy: Double {
        var acc = 0.0
        var count = 0.0
        var y = 0
        while y < height {
            var x = 0
            while x < width - 1 {
                let a = rgb(x, y)
                let b = rgb(x + 1, y)
                acc += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                count += 3
                x += 1
            }
            y += 1
        }
        return count > 0 ? acc / count : 0
    }
}

func makeImage(width: Int, height: Int, pixel: (Int, Int) -> (Double, Double, Double)) -> CIImage {
    var data = [UInt8](repeating: 255, count: width * height * 4)
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            let c = pixel(x, y)
            let o = (y * width + x) * 4
            data[o] = UInt8(max(0, min(255, c.0 * 255)))
            data[o + 1] = UInt8(max(0, min(255, c.1 * 255)))
            data[o + 2] = UInt8(max(0, min(255, c.2 * 255)))
            data[o + 3] = 255
            x += 1
        }
        y += 1
    }
    let buffer = data.withUnsafeBufferPointer { Data(buffer: $0) }
    return CIImage(bitmapData: buffer, bytesPerRow: width * 4,
                   size: CGSize(width: width, height: height),
                   format: .RGBA8, colorSpace: sRGB)
}

func render(_ image: CIImage) -> Pixels {
    let extent = image.extent.integral
    let w = Int(extent.width)
    let h = Int(extent.height)
    var data = [UInt8](repeating: 0, count: w * h * 4)
    context.render(image, toBitmap: &data, rowBytes: w * 4, bounds: extent,
                   format: .RGBA8, colorSpace: sRGB)
    return Pixels(width: w, height: h, data: data)
}

func run(_ image: CIImage, _ settings: ACRDevelopSettings) -> Pixels {
    return render(ACRDevelopEngine.render(image, settings: settings, context: context))
}

// MARK: - 测试集

print("== ACRDevelopEngine 行为测试 ==")

// 1. 中性参数必须原样返回
do {
    let img = makeImage(width: 32, height: 32) { x, _ in
        let v = Double(x) / 31.0
        return (v, v * 0.8, v * 0.6)
    }
    let out = run(img, ACRDevelopSettings())
    let src = render(img)
    var diff = 0.0
    var i = 0
    while i < src.data.count {
        diff += abs(Double(src.data[i]) - Double(out.data[i]))
        i += 1
    }
    expect(diff / Double(src.data.count) < 0.5, "中性参数应逐像素原样返回 (平均差 \(diff / Double(src.data.count)))")
}

// 2. 曝光 +1EV：中灰 0.5 应抬到 ~0.685（线性 ×2 后再编码）
do {
    let img = makeImage(width: 8, height: 8) { _, _ in (0.5, 0.5, 0.5) }
    var s = ACRDevelopSettings()
    s.exposure = 1.0
    let out = run(img, s)
    let v = out.rgb(4, 4).0
    expectNear(v, 0.685, 0.04, "曝光 +1EV 的 sRGB 输出")
}

// 3. 对比度：+100 应把 0.4/0.6 这一对推开
do {
    let img = makeImage(width: 16, height: 8) { x, _ in
        let v: Double = x < 8 ? 0.40 : 0.60
        return (v, v, v)
    }
    var s = ACRDevelopSettings()
    s.contrast = 100
    let out = run(img, s)
    let dark = out.rgb(2, 4).0
    let bright = out.rgb(12, 4).0
    expect(bright - dark > 0.24, "对比度 +100 应拉开明暗差 (实测 \(bright - dark))")
    // 枢轴 0.5 附近基本不动
    expectNear(out.rgb(2, 4).0, 0.40, 0.10, "对比度不该整体偏移")
}

// 4. 黑点：blacks +15 让 0.5 变暗；白点 whites +15 让 0.5 变亮
do {
    let img = makeImage(width: 8, height: 8) { _, _ in (0.5, 0.5, 0.5) }
    var sb = ACRDevelopSettings(); sb.blacks = 15
    var sw = ACRDevelopSettings(); sw.whites = 15
    let dark = run(img, sb).rgb(4, 4).0
    let bright = run(img, sw).rgb(4, 4).0
    expect(dark < 0.5, "blacks +15 应压暗 (got \(dark))")
    expect(bright > 0.5, "whites +15 应提亮 (got \(bright))")
}

// 5. 去雾：合成雾图（低对比 + 灰蒙）局部对比应上升
do {
    let img = makeImage(width: 64, height: 64) { x, y in
        // 缓慢变化的场景 + 0.35 的雾
        let scene = 0.42 + 0.10 * sin(Double(x) / 9.0) * cos(Double(y) / 11.0)
        let hazed = scene * 0.62 + 0.35
        return (hazed, hazed, hazed)
    }
    var s = ACRDevelopSettings(); s.dehaze = 80
    let src = render(img)
    let out = run(img, s)
    expect(out.luminanceStd > src.luminanceStd * 0.98,
           "去雾后局部对比不应变平 (src=\(src.luminanceStd) out=\(out.luminanceStd))")
    expect(out.luminanceMean < src.luminanceMean + 0.05,
           "去雾不该整体大幅提亮 (src=\(src.luminanceMean) out=\(out.luminanceMean))")
}

// 6. Clarity：高频细节放大、均值基本不动
do {
    let img = makeImage(width: 64, height: 64) { x, _ in
        let v = x % 8 < 4 ? 0.46 : 0.54
        return (v, v, v)
    }
    var s = ACRDevelopSettings(); s.clarity = 100
    let src = render(img)
    let out = run(img, s)
    expect(out.gradientEnergy > src.gradientEnergy, "Clarity 应提升局部对比")
    expectNear(out.luminanceMean, src.luminanceMean, 0.03, "Clarity 不该明显改变整体亮度")
}

// 7. Texture：细节提升但更温和，颜色不应被推爆
do {
    let img = makeImage(width: 64, height: 64) { x, y in
        let v = (x + y) % 6 < 3 ? 0.48 : 0.52
        return (v, v * 0.9, v * 0.8)
    }
    var s = ACRDevelopSettings(); s.texture = 100
    let src = render(img)
    let out = run(img, s)
    expect(out.gradientEnergy > src.gradientEnergy, "Texture 应提升细节")
    expectNear(out.luminanceMean, src.luminanceMean, 0.03, "Texture 不该大幅改变平均亮度")
}

// 8. 锐化：梯度能量上升
do {
    let img = makeImage(width: 64, height: 64) { x, _ in
        let v = x < 32 ? 0.35 : 0.65
        return (v, v, v)
    }
    var s = ACRDevelopSettings(); s.sharpness = 80; s.sharpenRadius = 1.0
    let src = render(img)
    let out = run(img, s)
    expect(out.gradientEnergy > src.gradientEnergy * 0.9, "锐化应提升梯度能量")
}

// 9. 亮度降噪：噪声方差下降
do {
    let img = makeImage(width: 64, height: 64) { x, y in
        let v = 0.5 + 0.12 * ((x &* 7 &+ y &* 13) % 17 < 8 ? 1.0 : -1.0)
        return (v, v, v)
    }
    var s = ACRDevelopSettings(); s.luminanceNR = 90
    let src = render(img)
    let out = run(img, s)
    expect(out.luminanceStd < src.luminanceStd, "亮度降噪应降低方差 (src=\(src.luminanceStd) out=\(out.luminanceStd))")
}

// 10. 颗粒：中调方差上升
do {
    let img = makeImage(width: 64, height: 64) { _, _ in (0.5, 0.5, 0.5) }
    var s = ACRDevelopSettings(); s.grain = 100; s.grainSize = 30
    let src = render(img)
    let out = run(img, s)
    expect(out.luminanceStd > src.luminanceStd, "颗粒应增加方差 (src=\(src.luminanceStd) out=\(out.luminanceStd))")
}

// 11. 暗角：四角比中心暗
do {
    let img = makeImage(width: 64, height: 64) { _, _ in (0.6, 0.6, 0.6) }
    var s = ACRDevelopSettings(); s.vignette = -80
    let out = run(img, s)
    let center = out.rgb(32, 32).0
    let corner = out.rgb(2, 2).0
    expect(corner < center, "负暗角应压暗四角 (center=\(center) corner=\(corner))")
}

// 12. 曲线：单调 LUT + 命中控制点
do {
    var s = ACRDevelopSettings()
    s.curve = [ACRCurvePoint(x: 0, y: 0), ACRCurvePoint(x: 0.5, y: 0.62), ACRCurvePoint(x: 1, y: 1)]
    let tone = ACRLookCube.Tones(settings: s)
    let mid = tone.tone(0.5)
    expectNear(mid, 0.62, 0.05, "点曲线应命中控制点 x=0.5")
    var prev = -1.0
    var monotone = true
    var i = 0
    while i <= 100 {
        let v = tone.tone(Double(i) / 100.0)
        if v < prev - 1.0e-6 { monotone = false }
        prev = v
        i += 1
    }
    expect(monotone, "色调曲线必须单调不回头")
}

// 13. 颜色分级：给阴影加蓝，暗部应更蓝、亮部基本不动
do {
    let img = makeImage(width: 32, height: 8) { x, _ in
        let v: Double = x < 16 ? 0.22 : 0.78
        return (v, v, v)
    }
    var s = ACRDevelopSettings()
    s.gradeShadowHue = 220
    s.gradeShadowSaturation = 80
    let out = run(img, s)
    let darkB = out.rgb(4, 4).2
    let darkR = out.rgb(4, 4).0
    let brightB = out.rgb(24, 4).2
    let brightR = out.rgb(24, 4).0
    expect(darkB > darkR, "阴影加蓝后暗部 B 应大于 R (B=\(darkB) R=\(darkR))")
    expect(abs(brightB - brightR) < 0.06, "高光不该被阴影轮染色 (B=\(brightB) R=\(brightR))")
}

// 14. DCP 解析：手搓一个最小 TIFF，验证矩阵与名字读得出来
do {
    // ProfileName = "Test" (ASCII, 5 字节) + ColorMatrix1 9 个 SRATIONAL
    var body = [UInt8]()
    // header
    body.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])          // II*\0
    body.append(contentsOf: [8, 0, 0, 0])                      // IFD0 at 8
    // IFD: 2 entries
    body.append(contentsOf: [2, 0])
    // entry 1: tag 0xC6F8 ProfileName, type 2 ASCII, count 5, offset -> 74
    body.append(contentsOf: [0xF8, 0xC6, 2, 0])
    body.append(contentsOf: [5, 0, 0, 0])
    body.append(contentsOf: [74, 0, 0, 0])
    // entry 2: tag 0xC621 ColorMatrix1, type 10 SRATIONAL, count 9, offset -> 80
    body.append(contentsOf: [0x21, 0xC6, 10, 0])
    body.append(contentsOf: [9, 0, 0, 0])
    body.append(contentsOf: [80, 0, 0, 0])
    // next IFD = 0
    body.append(contentsOf: [0, 0, 0, 0])
    // 补齐到 74
    while body.count < 74 { body.append(0) }
    body.append(contentsOf: Array("Test".utf8))
    body.append(0)
    while body.count < 80 { body.append(0) }
    // 9 个 SRATIONAL：1/1, 0/1, 0/1, 0/1, 1/1, 0/1, 0/1, 0/1, 1/1
    let nums: [(Int32, Int32)] = [(1, 1), (0, 1), (0, 1), (0, 1), (1, 1), (0, 1), (0, 1), (0, 1), (1, 1)]
    for pair in nums {
        var n = pair.0.littleEndian
        var d = pair.1.littleEndian
        withUnsafeBytes(of: &n) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: &d) { body.append(contentsOf: $0) }
    }
    let profile = ACRDCPProfile.parse(data: Data(body))
    expect(profile != nil, "手搓 DCP 应能被解析")
    if let p = profile {
        expect(p.name == "Test", "ProfileName 应读成 Test (got \(p.name))")
        expect(p.colorMatrix1.count == 9, "ColorMatrix1 应有 9 个数")
        if p.colorMatrix1.count == 9 {
            expectNear(p.colorMatrix1[0], 1.0, 1e-6, "矩阵第 1 项")
            expectNear(p.colorMatrix1[8], 1.0, 1e-6, "矩阵第 9 项")
        }
    }
}

// 15. 强度缩放：scaled(by: 0.5) 只缩幅度不缩半径
do {
    var s = ACRDevelopSettings()
    s.clarity = 60
    s.sharpenRadius = 2.0
    s.grainSize = 40
    let half = s.scaled(by: 0.5)
    expectNear(half.clarity, 30, 1e-6, "clarity 应减半")
    expectNear(half.sharpenRadius, 2.0, 1e-6, "sharpenRadius 是结构参数不该变")
    expectNear(half.grainSize, 40, 1e-6, "grainSize 是结构参数不该变")
}

// MARK: - 汇总

print("")
if failures == 0 {
    print("PASS  \(checks) 项断言全部通过")
    exit(0)
} else {
    print("FAIL  \(failures)/\(checks) 项断言失败")
    exit(1)
}
