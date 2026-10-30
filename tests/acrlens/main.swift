import CoreImage
import CoreGraphics
import Foundation

// ACRLensRepairEngine 行为测试（镜头 / 几何 / 修补 / AI 替代）
//
//   xcrun swiftc -O OutdoorPhotoAssistant/Core/CommercialRetouch/ACRLensRepairEngine.swift \
//                tests/acrlens/main.swift -o /tmp/acrlens-tests && /tmp/acrlens-tests

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
    expect(abs(value - target) <= tol,
           "\(message)  got=\(String(format: "%.4f", value)) want=\(String(format: "%.4f", target))")
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: sRGB])

struct Pixels {
    var width: Int
    var height: Int
    var data: [UInt8]
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let o = (y * width + x) * 4
        return (Double(data[o]) / 255, Double(data[o + 1]) / 255, Double(data[o + 2]) / 255)
    }
    var mean: Double {
        var s = 0.0
        var i = 0
        while i < width * height {
            let o = i * 4
            s += 0.299 * Double(data[o]) + 0.587 * Double(data[o + 1]) + 0.114 * Double(data[o + 2])
            i += 1
        }
        return s / Double(width * height) / 255
    }
    var std: Double {
        let m = mean * 255
        var acc = 0.0
        var i = 0
        while i < width * height {
            let o = i * 4
            let l = 0.299 * Double(data[o]) + 0.587 * Double(data[o + 1]) + 0.114 * Double(data[o + 2])
            acc += (l - m) * (l - m)
            i += 1
        }
        return sqrt(acc / Double(width * height)) / 255
    }
    var gradientEnergy: Double {
        var acc = 0.0
        var n = 0.0
        var y = 0
        while y < height {
            var x = 0
            while x < width - 1 {
                let a = rgb(x, y), b = rgb(x + 1, y)
                acc += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                n += 3
                x += 1
            }
            y += 1
        }
        return n > 0 ? acc / n : 0
    }
}

func makeImage(_ w: Int, _ h: Int, _ pixel: (Int, Int) -> (Double, Double, Double)) -> CIImage {
    var d = [UInt8](repeating: 255, count: w * h * 4)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            let c = pixel(x, y)
            let o = (y * w + x) * 4
            d[o] = UInt8(max(0, min(255, c.0 * 255)))
            d[o + 1] = UInt8(max(0, min(255, c.1 * 255)))
            d[o + 2] = UInt8(max(0, min(255, c.2 * 255)))
            d[o + 3] = 255
            x += 1
        }
        y += 1
    }
    let buf = d.withUnsafeBufferPointer { Data(buffer: $0) }
    return CIImage(bitmapData: buf, bytesPerRow: w * 4,
                   size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: sRGB)
}

func render(_ image: CIImage) -> Pixels {
    let e = image.extent.integral
    let w = Int(e.width), h = Int(e.height)
    var d = [UInt8](repeating: 0, count: w * h * 4)
    context.render(image, toBitmap: &d, rowBytes: w * 4, bounds: e,
                   format: .RGBA8, colorSpace: sRGB)
    return Pixels(width: w, height: h, data: d)
}

print("== ACRLensRepairEngine 行为测试 ==")

// 1. LCP 解析 + 焦段插值
do {
    let xml = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF><rdf:Description xmlns:stCamera="http://ns.adobe.com/photoshop/1.0/camera-profile">
      <stCamera:ProfileName="Test Lens Profile"
      <stCamera:Make="TEST" stCamera:Model="Cam" stCamera:Lens="18-200mm"
      stCamera:SensorFormatFactor="1.5" stCamera:FocalLength="18"
      stCamera:FocalLengthX="0.9" stCamera:ImageXCenter="0.5" stCamera:ImageYCenter="0.5"
      <stCamera:RadialDistortParam1="1.0" stCamera:RadialDistortParam2="0.5"
      stCamera:RadialDistortParam3="0.1" stCamera:VignetteModelParam1="-17.4"
      stCamera:VignetteModelParam2="3846.5" stCamera:VignetteModelParam3="-240376.9"/>
      <stCamera:ProfileName="Test Lens Profile"
      stCamera:FocalLength="200"
      stCamera:FocalLengthX="2.0" stCamera:ImageXCenter="0.5" stCamera:ImageYCenter="0.5"
      <stCamera:RadialDistortParam1="3.0" stCamera:RadialDistortParam2="1.5"
      stCamera:RadialDistortParam3="0.3" stCamera:VignetteModelParam1="-9.0"
      stCamera:VignetteModelParam2="1000.0" stCamera:VignetteModelParam3="-5000.0"/>
     </rdf:Description></rdf:RDF>
    </x:xmpmeta>
    """
    let profile = ACRLensProfile.parse(xml: xml)
    expect(profile != nil, "LCP 应能解析")
    if let p = profile {
        expect(p.entries.count == 2, "LCP 应有 2 个焦段条目 (got \(p.entries.count))")
        expectNear(p.sensorFormatFactor, 1.5, 1e-6, "SensorFormatFactor")
        if let mid = p.entry(forFocalLength: 100) {
            // 18mm: 1.0 → 200mm: 3.0，100mm 应落在中间
            expect(mid.radial1 > 1.0 && mid.radial1 < 3.0,
                   "焦段插值应落在两条之间 (got \(mid.radial1))")
        } else {
            expect(false, "entry(forFocalLength:) 不应为 nil")
        }
    }
}

// 2. 畸变系数与自动缩放
do {
    var e = ACRLensEntry()
    e.radial1 = 1.0
    e.radial2 = 0.5
    e.radial3 = 0.1
    let k = ACRLensRepairEngine.distortionCoefficients(entry: e, amount: 100)
    expect(k.0 < 0, "校正方向应与畸变相反（负号）")
    expectNear(abs(k.0), 1.0e-3, 1e-9, "k1 = radial1 * 1e-3")
    let s = ACRLensRepairEngine.autoFitScale(k1: k.0, k2: k.1, k3: k.2)
    expect(s >= 0.8 && s <= 2.0, "autoFitScale 应落在 [0.8, 2.0] (got \(s))")
}

// 3. 畸变校正真的动了画面、且中心基本不动
do {
    let img = makeImage(64, 64) { x, y in
        let grid = (x % 8 == 0 || y % 8 == 0) ? 0.25 : 0.95
        return (grid, grid, grid)
    }
    var e = ACRLensEntry()
    e.radial1 = 40.0
    e.focalLengthX = 1.0
    var c = ACRLensCorrection()
    c.enabled = true
    c.entry = e
    c.distortion = 100
    c.vignetting = 0
    c.chromaticAberration = 0
    c.autoScale = false
    let out = render(ACRLensRepairEngine.correctLens(img, correction: c, context: context))
    let src = render(img)
    expect(out.width == src.width && out.height == src.height, "畸变校正不该改尺寸")
    var diff = 0.0
    var i = 0
    while i < src.data.count {
        diff += abs(Double(src.data[i]) - Double(out.data[i]))
        i += 4
    }
    expect(diff / Double(src.data.count / 4) > 0.001, "畸变校正应改变边缘像素")
    let centerSrc = src.rgb(32, 32)
    let centerOut = out.rgb(32, 32)
    expect(abs(centerSrc.0 - centerOut.0) < 0.35, "画面中心不该被大幅拖动")
}

// 4. 几何：旋转 90° 保持尺寸、画面变化
do {
    let img = makeImage(32, 32) { x, _ in
        let v = Double(x) / 31.0
        return (v, 1 - v, 0.4)
    }
    var g = ACRGeometryAdjust()
    g.rotationDegrees = 90
    let out = render(ACRLensRepairEngine.applyGeometry(img, geometry: g))
    let src = render(img)
    expect(out.width == src.width && out.height == src.height, "旋转后尺寸保持")
    expect(abs(out.rgb(2, 2).0 - src.rgb(2, 2).0) > 0.02, "旋转应改变像素分布")
}

// 5. 修补：白底红点，heal 后中心变回白色
do {
    let img = makeImage(64, 64) { x, y in
        let dx = Double(x - 32), dy = Double(y - 32)
        return (dx * dx + dy * dy < 36) ? (0.95, 0.1, 0.1) : (0.92, 0.92, 0.92)
    }
    let spot = ACRHealSpot(center: CGPoint(x: 32, y: 32), radius: 9,
                           sourceOffset: CGVector(dx: 24, dy: 0), feather: 0.4, opacity: 1.0)
    var settings = ACRRepairSettings()
    settings.healSpots = [spot]
    let out = render(ACRLensRepairEngine.applyRepair(img, settings: settings, context: context))
    let c = out.rgb(32, 32)
    expect(c.0 > 0.7 && c.1 > 0.7, "heal 后中心应变成白色 (R=\(c.0) G=\(c.1))")
    expect(abs(c.0 - c.1) < 0.12, "heal 后中心应接近中性 (R=\(c.0) G=\(c.1))")
}

// 6. 补光：暗部被提亮，白区基本不动
do {
    let img = makeImage(64, 32) { x, _ in
        let v = x < 32 ? 0.12 : 0.95
        return (v, v, v)
    }
    var settings = ACRRepairSettings()
    settings.fillLight = 80
    let out = render(ACRLensRepairEngine.applyRepair(img, settings: settings, context: context))
    let src = render(img)
    expect(out.rgb(8, 16).0 > src.rgb(8, 16).0 + 0.01, "补光应提亮暗部")
    expect(abs(out.rgb(56, 16).0 - src.rgb(56, 16).0) < 0.03, "白区不该被补光推爆")
}

// 7. 去紫边：高饱和紫边被拉向中性
do {
    let img = makeImage(32, 32) { _, _ in (0.55, 0.2, 0.75) }
    var settings = ACRRepairSettings()
    settings.defringe = 100
    let out = render(ACRLensRepairEngine.applyRepair(img, settings: settings, context: context))
    let src = render(img)
    let cs = src.rgb(16, 16), co = out.rgb(16, 16)
    let chromaSrc = abs(cs.0 - cs.1) + abs(cs.2 - cs.1)
    let chromaOut = abs(co.0 - co.1) + abs(co.2 - co.1)
    expect(chromaOut < chromaSrc, "去紫边应降低色度 (before=\(chromaSrc) after=\(chromaOut))")
}

// 8. 去红眼：掩膜内红通道被压下来
do {
    let img = makeImage(32, 32) { _, _ in (0.95, 0.25, 0.2) }
    let mask = makeImage(32, 32) { _, _ in (1, 1, 1) }
    var settings = ACRRepairSettings()
    settings.redeye = 100
    settings.redeyeMask = mask
    let out = render(ACRLensRepairEngine.applyRepair(img, settings: settings, context: context))
    let src = render(img)
    let cs = src.rgb(16, 16), co = out.rgb(16, 16)
    expect(co.0 < cs.0, "红眼修正后 R 应下降 (before=\(cs.0) after=\(co.0))")
    expect(abs(co.1 - cs.1) < 0.02, "G 通道不该被改")
}

// 9. 去摩尔纹：高频能量下降
do {
    let img = makeImage(64, 64) { x, y in
        let v = (x + y) % 2 == 0 ? 0.85 : 0.35
        return (v, v, v)
    }
    var settings = ACRRepairSettings()
    settings.moire = 100
    let out = render(ACRLensRepairEngine.applyRepair(img, settings: settings, context: context))
    let src = render(img)
    expect(out.gradientEnergy < src.gradientEnergy, "去摩尔纹应降低高频能量")
}

// 10. 暗角校正：四角变亮
do {
    let img = makeImage(64, 64) { _, _ in (0.45, 0.45, 0.45) }
    var e = ACRLensEntry()
    e.vignette1 = 5.0e5      // → k1 = 0.5
    var c = ACRLensCorrection()
    c.enabled = true
    c.entry = e
    c.distortion = 0
    c.chromaticAberration = 0
    c.vignetting = 100
    let out = render(ACRLensRepairEngine.correctLens(img, correction: c, context: context))
    let src = render(img)
    expect(out.rgb(2, 2).0 > src.rgb(2, 2).0 + 0.02, "暗角校正应提亮四角")
    expect(abs(out.rgb(32, 32).0 - src.rgb(32, 32).0) < 0.02, "中心不该被暗角校正影响")
}

// 11. AI 替代实现：降噪降方差、超分放大、主体蒙版非空
do {
    let noisy = makeImage(64, 64) { x, y in
        let v = 0.5 + 0.12 * (((x &* 7 &+ y &* 13) % 17 < 8) ? 1.0 : -1.0)
        return (v, v, v)
    }
    let src = render(noisy)
    let dn = render(ACRLensRepairEngine.denoiseSubstitute(noisy, amount: 90, context: context))
    expect(dn.std < src.std, "降噪替代应降低方差")

    let up = ACRLensRepairEngine.upscaleSubstitute(noisy, factor: 2)
    expect(up.extent.width == CGFloat(src.width) * 2, "超分替代应把宽度放大 2 倍")

    let mask = ACRLensRepairEngine.subjectMaskSubstitute(noisy, context: context)
    expect(mask != nil, "主体蒙版替代应返回非空")
}

// 12. 单应求解：点对相同时应得到单位矩阵；透视时角点被拉动
do {
    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                   CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
    if let h = ACRLensRepairEngine.homography(from: corners, to: corners) {
        expectNear(h[0], 1.0, 1e-6, "单位单应 h0")
        expectNear(h[4], 1.0, 1e-6, "单位单应 h4")
        expectNear(h[2], 0.0, 1e-6, "单位单应平移项 h2")
        expectNear(h[5], 0.0, 1e-6, "单位单应平移项 h5")
        expectNear(h[6], 0.0, 1e-6, "单位单应透视项 h6")
        expectNear(h[7], 0.0, 1e-6, "单位单应透视项 h7")
    } else {
        expect(false, "单位单应求解不应失败")
    }
    let img = makeImage(64, 64) { x, y in
        let v = (x % 8 < 4 ? 0.3 : 0.8) * (y % 8 < 4 ? 1.0 : 0.7)
        return (v, v, v)
    }
    var g = ACRGeometryAdjust()
    g.perspectiveHorizontal = 0.2
    let out = render(ACRLensRepairEngine.applyGeometry(img, geometry: g))
    let src = render(img)
    expect(out.width == src.width, "透视校正不该改尺寸")
    var diff = 0.0
    var i = 0
    while i < src.data.count {
        diff += abs(Double(src.data[i]) - Double(out.data[i]))
        i += 4
    }
    expect(diff / Double(src.data.count / 4) > 0.001, "透视校正应改变像素")
}
print("")
if failures == 0 {
    print("PASS  \(checks) 项断言全部通过")
    exit(0)
} else {
    print("FAIL  \(failures)/\(checks) 项断言失败")
    exit(1)
}
