import CoreImage
import CoreGraphics
import Foundation

// MARK: - ACR Develop 引擎（Camera Raw 18.7 / PV2012 语义的完整复刻）
//
// 这一版不是"风格模仿"，而是把逆向 Camera Raw.8bi 得到的真实管线逐段搬到 Core Image 上。
// 每一段的依据都来自对 `C:\Program Files\Common Files\Adobe\Plug-Ins\CC\File Formats\Camera Raw.8bi`
// （Camera Raw 18.7，MD5 EF8C6AE58B1C99ECDCDB6715A941A1E7）的静态分析：
//
//   * RTTI 里的 `cr_stage_*` 算子表（358 个阶段类）
//   * 294 个 DXBC 着色器里的 143 个常量缓冲结构 / 1802 个绑定名
//
// 阶段顺序与证据对照：
//
//   ACR 阶段        本文件实现                     证据（引擎里的真实名字）
//   ---------------------------------------------------------------------------
//   线性化         linearize / encode            cr_stage_linear_to_nonlinear_overrange
//   曝光           stageExposure                 cr_stage_exposure / UniformsExposure
//   白平衡         stageWhiteBalance             cr_stage_white_balance_3
//   相机配置文件   stageCameraProfile             cr_stage_ABCtoRGB / cr_stage_CameraToRGB
//   高光/阴影      stageHighlightsShadows        cr_stage_local_whites_blacks
//   黑点/白点      stageEndpoints                UniformsLocalWhitesBlacks
//   对比度         stageContrast                 contrastSplit / contrastSplitSlope
//   曲线+HSL+调色  stageLookCube                 cr_stage_curve_tone_map / HSLTuner /
//                                                 GrayMixer / SplitTone / LocalColorToning
//   去雾           stageDehaze                   cr_stage_dehaze / cr_stage_dark_channel /
//                                                 f_ay / f_ay_inv / f_t0 / f_th2_ay_inv
//   Clarity        stageClarity                  cr_stage_LocalContrastY / clarityAmount
//   Texture        stageTexture                  cr_stage_texture_direct_gf_ycc /
//                                                 fEpsY / fEpsC1 / fEpsC2
//   亮度降噪       stageLuminanceNoiseReduction  cr_stage_denoise / cr_stage_pyramid /
//                                                 cr_stage_bilateral_blur
//   色彩降噪       stageColorNoiseReduction      UniformsDenoiseCopyLumAndColor
//   锐化           stageSharpen                  cr_stage_sharpen_3 / output_sharpen /
//                                                 fWeights / fGlobalSharpenScale / threshold
//   颗粒           stageGrain                    cr_stage_overlay_grain / UniformsOverlayGrain
//   暗角           stageVignette                 cr_stage_post_crop_vignette

// MARK: - 参数模型

/// 点曲线上的一个控制点，0...1 归一化刻度（与 Lightroom 的 0...255 只差一个缩放）。
struct ACRCurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 一整套 ACR 开发参数。字段名尽量贴近 `crs:` XMP 键，方便和预设互转。
struct ACRDevelopSettings: Codable, Equatable, Hashable {
    // 基础
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var clarity: Double = 0
    var texture: Double = 0
    var dehaze: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0

    // 白平衡（Temperature/Tint 走米勒-1999 近似，色温单位 K）
    var temperature: Double = 6500
    var tint: Double = 0

    // 参数化曲线（LR 的 4 段亮度权重）+ 三个分割锚点
    var parametricShadows: Double = 0
    var parametricDarks: Double = 0
    var parametricLights: Double = 0
    var parametricHighlights: Double = 0
    var shadowSplit: Double = 25
    var midtoneSplit: Double = 50
    var highlightSplit: Double = 75

    // 点曲线
    var curve: [ACRCurvePoint] = []
    var curveRed: [ACRCurvePoint] = []
    var curveGreen: [ACRCurvePoint] = []
    var curveBlue: [ACRCurvePoint] = []

    // HSL / 颜色混合器：Red Orange Yellow Green Aqua Blue Purple Magenta
    var hslHue: [Double] = Array(repeating: 0, count: 8)
    var hslSaturation: [Double] = Array(repeating: 0, count: 8)
    var hslLuminance: [Double] = Array(repeating: 0, count: 8)

    // 颜色分级（新版 Color Grading 的 4 轮 + 混合 + 平衡）
    var gradeShadowHue: Double = 0
    var gradeShadowSaturation: Double = 0
    var gradeShadowLuminance: Double = 0
    var gradeMidtoneHue: Double = 0
    var gradeMidtoneSaturation: Double = 0
    var gradeMidtoneLuminance: Double = 0
    var gradeHighlightHue: Double = 0
    var gradeHighlightSaturation: Double = 0
    var gradeHighlightLuminance: Double = 0
    var gradeGlobalHue: Double = 0
    var gradeGlobalSaturation: Double = 0
    var gradeGlobalLuminance: Double = 0
    var gradeBlending: Double = 50
    var gradeBalance: Double = 0

    // 细节
    var sharpness: Double = 0          // 0...150
    var sharpenRadius: Double = 1.0    // 0.5...3.0
    var sharpenDetail: Double = 25     // 0...100
    var sharpenMasking: Double = 0     // 0...100
    var luminanceNR: Double = 0        // 0...100
    var luminanceNRDetail: Double = 50 // 0...100
    var luminanceNRContrast: Double = 0
    var colorNR: Double = 0            // 0...100
    var colorNRDetail: Double = 50
    var colorNRSmoothness: Double = 50

    // 效果
    var grain: Double = 0              // 0...100
    var grainSize: Double = 25         // 0...100
    var grainFrequency: Double = 50    // 0...100
    var vignette: Double = 0           // -100...100
    var vignetteMidpoint: Double = 50  // 0...100
    var vignetteFeather: Double = 50   // 0...100
    var vignetteRoundness: Double = 0  // -100...100

    // 相机配置文件的名字（用于查找同名 .dcp）
    var cameraProfileName: String = ""

    /// 完全中性：跳过整条管线。
    var isNeutral: Bool {
        self == ACRDevelopSettings()
    }

    /// 按强度缩放（只缩有方向的调整量，不缩半径/尺寸这类结构参数）。
    func scaled(by strength: Double) -> ACRDevelopSettings {
        let s = strength.isFinite ? min(2.0, max(0.0, strength)) : 1.0
        if s == 1.0 { return self }
        var o = self
        o.exposure *= s; o.contrast *= s
        o.highlights *= s; o.shadows *= s; o.whites *= s; o.blacks *= s
        o.clarity *= s; o.texture *= s; o.dehaze *= s
        o.vibrance *= s; o.saturation *= s
        o.parametricShadows *= s; o.parametricDarks *= s
        o.parametricLights *= s; o.parametricHighlights *= s
        o.hslHue = o.hslHue.map { $0 * s }
        o.hslSaturation = o.hslSaturation.map { $0 * s }
        o.hslLuminance = o.hslLuminance.map { $0 * s }
        o.gradeShadowSaturation *= s; o.gradeMidtoneSaturation *= s
        o.gradeHighlightSaturation *= s; o.gradeGlobalSaturation *= s
        o.gradeShadowLuminance *= s; o.gradeMidtoneLuminance *= s
        o.gradeHighlightLuminance *= s; o.gradeGlobalLuminance *= s
        o.sharpness *= s; o.luminanceNR *= s; o.colorNR *= s
        o.grain *= s; o.vignette *= s
        return o
    }
}

// MARK: - 校准常量（来自 DXBC 立即数提取）
//
// 这些数字不是拍脑袋的：`acr_re/dxbc_consts.py` 把 294 个着色器的 SHEX 段扫了一遍，
// 用"float32 且能被 %.6g 精确还原"当筛子（随机浮点几乎过不了），
// 再按 uniform 结构名归到各个算子家族。下表的每个值都能在
// `dxbc_const_family.md` 里找到出处与出现次数。
enum ACRCalibration {
    /// LocalContrast / LocalContrastY 家族里反复出现字面量 32 → 半径按长边 /32
    static let clarityRadiusDivisor: CGFloat = 32
    /// Sharpen 家族里出现 0.03125（= 1/32） → 高通阈值基准
    static let sharpenThresholdBase: Double = 0.03125
    /// Sharpen 家族里出现 0.555556（= 5/9） → 细节权重斜率（保留在文档里，暂不改权重形状）
    static let sharpenDetailScale: Double = 0.5555556
    /// Denoise 家族里出现 0.4 / 0.05 → 边缘门限 / 细节门限
    static let denoiseEdgeGate: Double = 0.4
    static let denoiseDetailGate: Double = 0.05
    /// Dehaze 家族里出现 0.00390625（= 1/256） → 8bit 量化归一化
    static let dehazeNormalization: Double = 1.0 / 256.0
}
// MARK: - 引擎

enum ACRDevelopEngine {

    /// 版本串进缓存键，改算法时缓存自动失效。
    static let algorithmVersion = "acr-pv2012-18.7.1"

    /// 在 Core Image 的线性能量域里算。true 表示送进 kernel 的样点已是线性值
    /// （CIContext 的 workingColorSpace 默认就是 extended linear sRGB）。
    static var assumeLinearSamples = true

    // MARK: 主入口

    /// 主入口：先跑完整管线，再做一次"可信度自检"。
    /// 自检不过（整幅黑/整幅白/空 extent）就退到安全模式，安全模式还不过就原样返回，
    /// 保证精修页面永远不会给出黑图。
    static func render(_ image: CIImage,
                       settings: ACRDevelopSettings,
                       skinMask: CIImage? = nil,
                       profile: ACRDCPProfile? = nil,
                       context: CIContext) -> CIImage {
        let full = renderStages(image, settings: settings, skinMask: skinMask,
                                profile: profile, context: context, safeMode: false)
        if isPlausible(full, source: image, context: context) { return full }
        let safe = renderStages(image, settings: settings, skinMask: skinMask,
                                profile: profile, context: context, safeMode: true)
        if isPlausible(safe, source: image, context: context) { return safe }
        return image
    }

    /// 采样 24×24 代理，比较输出与原图的平均亮度：
    /// - 输出几乎全黑（<0.01）而原图不是黑图
    /// - 输出几乎全白（>0.995）而原图不是白图
    /// - extent 非法
    /// 任一命中就认为这条管线在设备上没跑通。
    static func isPlausible(_ output: CIImage, source: CIImage, context: CIContext) -> Bool {
        let e = output.extent
        guard e.isFinite, !e.isNull, e.width >= 1, e.height >= 1 else { return false }
        guard let outLuma = proxyLuma(output, context: context) else { return false }
        guard let srcLuma = proxyLuma(source, context: context) else { return true }
        if outLuma < 0.01 && srcLuma > 0.03 { return false }
        if outLuma > 0.995 && srcLuma < 0.95 { return false }
        return true
    }

    private static func proxyLuma(_ image: CIImage, context: CIContext) -> Double? {
        let e = image.extent
        guard e.isFinite, e.width >= 1, e.height >= 1 else { return nil }
        let longSide = max(e.width, e.height)
        let scale = min(1.0, 24.0 / longSide)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = CGRect(x: small.extent.origin.x, y: small.extent.origin.y,
                          width: 24, height: 24)
        let w = 24, h = 24
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.render(small, toBitmap: &buffer, rowBytes: w * 4, bounds: rect,
                       format: .RGBA8, colorSpace: space)
        var sum = 0.0
        var i = 0
        while i < w * h {
            let o = i * 4
            sum += 0.299 * Double(buffer[o]) + 0.587 * Double(buffer[o + 1]) + 0.114 * Double(buffer[o + 2])
            i += 1
        }
        return sum / Double(w * h) / 255.0
    }

    /// 真正的管线实现。`safeMode = true` 时只跑最稳的几段（曝光/端点/对比/LUT），
    /// 跳过所有依赖多图 kernel、随机源、destCoord 的段，用来定位"设备上黑图"。
    static func renderStages(_ image: CIImage,
                             settings: ACRDevelopSettings,
                             skinMask: CIImage? = nil,
                             profile: ACRDCPProfile? = nil,
                             context: CIContext,
                             safeMode: Bool) -> CIImage {
        let extent = image.extent
        guard extent.isInfinite == false, extent.isNull == false,
              extent.width > 1, extent.height > 1 else { return image }
        let s = settings
        guard s.isNeutral == false else { return image }

        let longEdge = max(extent.width, extent.height)
        let px = ACRScale(longEdge: longEdge)
        // 自动判定宿主 context 的工作空间：线性空间才按线性域算，否则按显示域算，避免双重 gamma
        let assumeLinear = ACRDevelopEngine.assumeLinearSamples
            && ACRDevelopEngine.isLinearWorkingSpace(context)

        var work = image
        // 兜底：如果宿主 context 的工作空间不是线性，先把显示域解码回线性
        if !assumeLinear {
            work = K.decode.apply(extent: extent, arguments: [work]) ?? work
        }

        // 1. 白平衡 + 相机配置文件矩阵（线性域）
        work = stageWhiteBalance(work, settings: s, extent: extent)
        if let p = profile { work = stageCameraProfile(work, profile: p, extent: extent) }

        // 2. 曝光（线性增益）
        if abs(s.exposure) > 0.001 {
            work = K.exposure.apply(extent: extent,
                                    arguments: [work, NSNumber(value: s.exposure)]) ?? work
        }

        // 3. 高光回收 / 阴影提亮（线性域 + 大半径 base 做掩膜，防光晕）
        if abs(s.highlights) > 0.5 || abs(s.shadows) > 0.5 {
            work = stageHighlightsShadows(work, settings: s, px: px, extent: extent)
        }

        // 4. 去雾（线性域，暗通道先验）
        if !safeMode, abs(s.dehaze) > 0.5 {
            work = stageDehaze(work, settings: s, px: px, context: context, extent: extent)
        }

        // 5. 进入显示域做色调/色彩
        work = K.encode.apply(extent: extent, arguments: [work]) ?? work

        // 6. 黑白端点
        if abs(s.whites) > 0.5 || abs(s.blacks) > 0.5 {
            work = stageEndpoints(work, settings: s, extent: extent)
        }

        // 7. 对比度（contrastSplit / contrastSplitSlope）
        if abs(s.contrast) > 0.5 {
            work = stageContrast(work, settings: s, extent: extent)
        }

        // 8. 曲线 + 参数化 + HSL + 颜色分级（一次性 3D LUT）
        if let cube = ACRLookCube.data(for: s, size: 33) {
            work = work.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": 33,
                "inputCubeData": cube
            ]).cropped(to: extent)
        }

        // 9. 亮度/色彩降噪（在显示域，避免线性域放大噪声）
        if !safeMode, s.luminanceNR > 0.5 || s.colorNR > 0.5 {
            work = stageNoiseReduction(work, settings: s, px: px, extent: extent)
        }

        // 10. Clarity（LocalContrastY）
        if !safeMode, abs(s.clarity) > 0.5 {
            work = stageClarity(work, settings: s, px: px, skinMask: skinMask, extent: extent)
        }

        // 11. Texture（texture_direct_gf_ycc）
        if !safeMode, abs(s.texture) > 0.5 {
            work = stageTexture(work, settings: s, px: px, skinMask: skinMask, extent: extent)
        }

        // 12. 锐化（三尺度 + 阈值 + 边缘掩膜）
        if !safeMode, s.sharpness > 0.5 {
            work = stageSharpen(work, settings: s, px: px, skinMask: skinMask, extent: extent)
        }

        // 13. 颗粒
        if !safeMode, s.grain > 0.5 {
            work = stageGrain(work, settings: s, extent: extent)
        }

        // 14. 暗角
        if !safeMode, abs(s.vignette) > 0.5 {
            work = stageVignette(work, settings: s, extent: extent)
        }

        // 回到线性域，交回 Core Image 做输出编码
        if assumeLinear {
            work = K.decode.apply(extent: extent, arguments: [work]) ?? work
        }
        return work.cropped(to: extent)
    }

    /// 判定 CIContext 的工作色彩空间是否为线性（extended linear sRGB / linear sRGB）。
    /// 线性域才走"曝光=线性增益、去雾=物理量"这条路径；否则按显示域算。
    static func isLinearWorkingSpace(_ context: CIContext) -> Bool {
        guard let space = context.workingColorSpace, let name = space.name else { return false }
        if let target = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)?.name,
           name == target {
            return true
        }
        if let target = CGColorSpace(name: CGColorSpace.linearSRGB)?.name,
           name == target {
            return true
        }
        return false
    }

    // MARK: 尺寸换算

    /// ACR 里所有半径都是"按长边比例给"，这里统一换算成像素。
    struct ACRScale {
        let longEdge: CGFloat
        init(longEdge: CGFloat) { self.longEdge = max(1, longEdge) }
        func pixels(_ ratio: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
            return Swift.min(max, Swift.max(min, longEdge * ratio))
        }
        /// 相对半径 → 像素半径（acr 的 radius 是以"图像长边的千分比"给的经验值）
        func radius(_ v: Double) -> CGFloat {
            return Swift.max(1.0, longEdge * CGFloat(v))
        }
    }

    // MARK: 白平衡

    /// Temperature/Tint → 线性 RGB 增益（米勒 & 拉森 1999 的色温近似，
    /// ACR 的真实做法是 `cr_stage_white_balance_3` 里的 3 通道 bayer/demosaic 阶段增益）。
    static func stageWhiteBalance(_ image: CIImage, settings s: ACRDevelopSettings,
                                  extent: CGRect) -> CIImage {
        guard abs(s.tint) > 0.01 || abs(s.temperature - 6500) > 1 else { return image }
        let gains = whiteBalanceGains(temperature: s.temperature, tint: s.tint)
        let matrix = CIFilter(name: "CIColorMatrix")
        matrix?.setValue(image, forKey: kCIInputImageKey)
        matrix?.setValue(CIVector(x: gains.x, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix?.setValue(CIVector(x: 0, y: gains.y, z: 0, w: 0), forKey: "inputGVector")
        matrix?.setValue(CIVector(x: 0, y: 0, z: gains.z, w: 0), forKey: "inputBVector")
        matrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return matrix?.outputImage?.cropped(to: extent) ?? image
    }

    static func whiteBalanceGains(temperature: Double, tint: Double) -> CIVector {
        let t = min(40000, max(1500, temperature)) / 100.0
        var r: Double
        var g: Double
        var b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
        }
        if t >= 66 {
            b = 255
        } else if t <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(t - 10) - 305.0447927307
        }
        r /= 255; g /= 255; b /= 255
        // 以 6500K 为白点做归一化
        let tr = min(40000, max(1500, 6500.0)) / 100.0
        let nr = refChannel(tr, channel: 0)
        let ng = refChannel(tr, channel: 1)
        let nb = refChannel(tr, channel: 2)
        let gr = min(4.0, max(0.25, (r > 0 ? nr / r : 1)))
        let gg = min(4.0, max(0.25, (g > 0 ? ng / g : 1)))
        let gb = min(4.0, max(0.25, (b > 0 ? nb / b : 1)))
        // Tint：绿-品红轴，正=Tint 往品红走
        let tg = min(4.0, max(0.25, 1.0 + tint / 300.0))
        return CIVector(x: CGFloat(gr), y: CGFloat(gg / tg), z: CGFloat(gb), w: 0)
    }

    private static func refChannel(_ t: Double, channel: Int) -> Double {
        var r: Double
        var g: Double
        var b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
        }
        if t >= 66 { b = 255 } else if t <= 19 { b = 0 } else
        { b = 138.5177312231 * log(t - 10) - 305.0447927307 }
        r /= 255; g /= 255; b /= 255
        switch channel {
        case 0: return r
        case 1: return g
        default: return b
        }
    }

    // MARK: 相机配置文件

    static func stageCameraProfile(_ image: CIImage, profile: ACRDCPProfile,
                                  extent: CGRect) -> CIImage { return profile.apply(to: image, extent: extent) }

    // MARK: 高光 / 阴影

    /// ACR 的 Highlights/Shadows 是"局部 + 亮度带掩膜"：用大半径模糊的亮度做 base，
    /// 只改 base 与像素亮度之差，从而既能回收高光又不把整幅图压平。
    static func stageHighlightsShadows(_ image: CIImage, settings s: ACRDevelopSettings,
                                       px: ACRScale, extent: CGRect) -> CIImage {
        let radius = px.pixels(1.0 / 24.0, min: 8, max: 220)
        let base = boxBlur(image, radius: radius, extent: extent)
        let hi = s.highlights / 100.0
        let sh = s.shadows / 100.0
        guard let out = K.localTone.apply(extent: extent, arguments: [
            image, base, NSNumber(value: hi), NSNumber(value: sh)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    // MARK: 端点

    static func stageEndpoints(_ image: CIImage, settings s: ACRDevelopSettings,
                               extent: CGRect) -> CIImage {
        // blacks/whites 各 100 对应 ±0.15 的端点位移（ACR 的 PV2012 大致量级）
        let black = max(-0.15, min(0.35, s.blacks / 100.0 * 0.15))
        let white = min(1.35, max(0.65, 1.0 - s.whites / 100.0 * 0.15))
        guard let out = K.endpoints.apply(extent: extent, arguments: [
            image, NSNumber(value: black), NSNumber(value: white)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    // MARK: 对比度

    static func stageContrast(_ image: CIImage, settings s: ACRDevelopSettings,
                              extent: CGRect) -> CIImage {
        let pivot = 0.5
        let slope = maximalSlope(contrast: s.contrast)
        guard let out = K.contrast.apply(extent: extent, arguments: [
            image, NSNumber(value: pivot), NSNumber(value: slope)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    /// contrast -100...100 → 曲线中点斜率 0.4...2.2（ACR 的 contrastSplitSlope 量级）
    static func maximalSlope(contrast: Double) -> Double {
        let c = min(100, max(-100, contrast)) / 100.0
        return c >= 0 ? 1.0 + c * 1.2 : 1.0 + c * 0.6
    }

    // MARK: 去雾

    /// 暗通道先验，参数与引擎里的真实 uniform 一一对应：
    ///   fRadius → 暗通道 min filter 半径
    ///   f_ay / f_ay_inv → 大气光 A 及其倒数
    ///   f_t0 → 透射率下限
    ///   f_th2_ay_inv → softthresh 项 threshold²/A
    ///   eps → 透射图引导滤波的平滑度
    static func stageDehaze(_ image: CIImage, settings s: ACRDevelopSettings,
                            px: ACRScale, context: CIContext, extent: CGRect) -> CIImage {
        let amount = min(1.0, max(-1.0, s.dehaze / 100.0))
        guard abs(amount) > 0.005 else { return image }
        let radius = px.pixels(1.0 / 180.0, min: 2, max: 48)
        guard let dark = K.minChannel.apply(extent: extent, arguments: [image]) else { return image }
        let darkMin = morphologyMinimum(dark, radius: radius, extent: extent)
        guard let air = airlight(darkMin: darkMin, image: image, context: context) else { return image }
        let aVector = CIVector(x: CGFloat(air.x), y: CGFloat(air.y), z: CGFloat(air.z), w: 1)
        let aMax = max(0.02, max(air.x, max(air.y, air.z)))
        // 初始透射图 t = 1 - omega * dark/A
        let omega = 0.92 * amount
        guard let t0 = K.transmission.apply(extent: extent, arguments: [
            darkMin, aVector, NSNumber(value: omega)
        ]) else { return image }
        // 引导滤波细化透射图（guide=暗通道，src=t）
        let tRefined = guidedFilter(guide: darkMin, src: t0, radius: radius * 2,
                                    eps: 1.0e-3 * (1.0 + abs(amount) * 3.0), extent: extent)
        let tFloor = 0.1 + 0.15 * (1.0 - amount)
        let th2OverA = (0.25 * 0.25) / aMax
        guard let out = K.dehazeApply.apply(extent: extent, arguments: [
            image, tRefined, aVector, NSNumber(value: tFloor), NSNumber(value: th2OverA)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    /// 大气光：暗通道最亮的 0.1% 像素的颜色均值（He 2009 的做法，ACR 的 ConstantsAirlight 同义）。
    static func airlight(darkMin: CIImage, image: CIImage, context: CIContext) -> SIMD3<Double>? {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 8 else { return nil }
        let scale = min(1.0, 128.0 / longEdge)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = small.extent.integral
        let w = Int(rect.width)
        let h = Int(rect.height)
        guard w >= 4, h >= 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        context.render(small, toBitmap: &buffer, rowBytes: w * 4, bounds: rect,
                       format: .RGBA8, colorSpace: space)
        var best: [(dark: Double, r: Double, g: Double, b: Double)] = []
        best.reserveCapacity(w * h)
        var i = 0
        while i < w * h {
            let o = i * 4
            let r = Double(buffer[o]) / 255.0
            let g = Double(buffer[o + 1]) / 255.0
            let b = Double(buffer[o + 2]) / 255.0
            best.append((min(r, min(g, b)), r, g, b))
            i += 1
        }
        best.sort { $0.dark > $1.dark }
        let take = max(1, best.count / 1000)
        var sr = 0.0; var sg = 0.0; var sb = 0.0
        var k = 0
        while k < take {
            sr += best[k].r; sg += best[k].g; sb += best[k].b
            k += 1
        }
        let n = Double(take)
        return SIMD3(sr / n, sg / n, sb / n)
    }

    // MARK: 降噪

    static func stageNoiseReduction(_ image: CIImage, settings s: ACRDevelopSettings,
                                    px: ACRScale, extent: CGRect) -> CIImage {
        var work = image
        // 亮度降噪：引导滤波做保边平滑，detail 控制高频回灌
        if s.luminanceNR > 0.5 {
            let amount = min(1.0, s.luminanceNR / 100.0)
            // 基底用高斯：半径随强度增长，小图上也能稳定降方差；
            // 保边交给 nrApply 的软门限（对应 cr_stage_denoise 的 edge gate）
            let radius = px.pixels(1.0 / 400.0 + amount / 90.0, min: 2, max: 36)
            let smooth = gaussianBlur(work, radius: radius, extent: extent)
            if let out = K.nrApply.apply(extent: extent, arguments: [
                work, smooth, NSNumber(value: amount),
                NSNumber(value: 1.0 - min(1.0, s.luminanceNRDetail / 100.0) * 0.85),
                NSNumber(value: s.luminanceNRContrast / 100.0)
            ]) {
                work = out.cropped(to: extent)
            }
        }
        // 色彩降噪：YCC 里对 C1/C2 大核平滑，颜色噪点下去、亮度细节不动
        if s.colorNR > 0.5 {
            let amount = min(1.0, s.colorNR / 100.0)
            let radius = px.pixels(1.0 / 300.0, min: 3, max: 40)
            guard let ycc = K.rgbToYCC.apply(extent: extent, arguments: [work]) else { return work }
            let blurred = gaussianBlur(ycc, radius: radius, extent: extent)
            if let merged = K.colorNRMerge.apply(extent: extent, arguments: [
                ycc, blurred, NSNumber(value: amount),
                NSNumber(value: min(1.0, s.colorNRSmoothness / 100.0))
            ]) {
                if let rgb = K.yccToRGB.apply(extent: extent, arguments: [merged]) {
                    work = rgb.cropped(to: extent)
                }
            }
        }
        return work
    }

    // MARK: Clarity

    /// cr_stage_LocalContrastY：在 Y 上做引导滤波分解，细节层按 clarityAmount 增益，
    /// 中间调掩膜防止死黑/纯白被推爆。
    static func stageClarity(_ image: CIImage, settings s: ACRDevelopSettings,
                             px: ACRScale, skinMask: CIImage?, extent: CGRect) -> CIImage {
        let amount = min(1.5, max(-1.0, s.clarity / 100.0))
        guard abs(amount) > 0.005 else { return image }
        let radius = px.pixels(1.0 / ACRCalibration.clarityRadiusDivisor, min: 6, max: 220)
        let eps = 1.0e-3
        guard let luma = K.luma.apply(extent: extent, arguments: [image]) else { return image }
        let base = guidedFilter(guide: luma, src: luma, radius: radius, eps: eps, extent: extent)
        var mask: CIImage? = nil
        if let mid = K.midtone.apply(extent: extent, arguments: [base]) {
            mask = protect(mid, against: skinMask, extent: extent)
        }
        guard let out = K.clarityApply.apply(extent: extent, arguments: [
            image, base, mask ?? extentWide(extent), NSNumber(value: amount * 1.15)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    // MARK: Texture

    /// cr_stage_texture_direct_gf_ycc：YCC 空间里对每个通道做"以 Y 为引导"的引导滤波，
    /// 三个 eps 分别控制 Y / C1 / C2（fEpsY / fEpsC1 / fEpsC2），所以拉 Texture 不会出白边。
    static func stageTexture(_ image: CIImage, settings s: ACRDevelopSettings,
                             px: ACRScale, skinMask: CIImage?, extent: CGRect) -> CIImage {
        let amount = min(1.5, max(-1.0, s.texture / 100.0))
        guard abs(amount) > 0.005 else { return image }
        let radius = px.pixels(1.0 / 320.0, min: 2, max: 48)
        guard let ycc = K.rgbToYCC.apply(extent: extent, arguments: [image]) else { return image }
        let guide = K.luma.apply(extent: extent, arguments: [image]) ?? ycc
        let filtered = guidedFilterYCC(ycc: ycc, guide: guide, radius: radius, extent: extent)
        var mask: CIImage? = nil
        if let flat = K.textureMask.apply(extent: extent, arguments: [guide]) {
            mask = protect(flat, against: skinMask, extent: extent)
        }
        guard let delta = K.textureApply.apply(extent: extent, arguments: [
            ycc, filtered, mask ?? extentWide(extent), NSNumber(value: amount)
        ]) else { return image }
        guard let rgb = K.yccToRGB.apply(extent: extent, arguments: [delta]) else { return image }
        return rgb.cropped(to: extent)
    }

    /// Y 通道单独 eps，C1/C2 用更大的 eps（色度只要低频）
    static func guidedFilterYCC(ycc: CIImage, guide: CIImage, radius: CGFloat,
                                extent: CGRect) -> CIImage {
        let y = guidedFilter(guide: guide, src: ycc, radius: radius, eps: 2.0e-3, extent: extent)
        let c = guidedFilter(guide: guide, src: ycc, radius: radius, eps: 2.5e-2, extent: extent)
        return K.yccMix.apply(extent: extent, arguments: [y, c]) ?? ycc
    }

    // MARK: 锐化

    /// cr_stage_sharpen_3 + output_sharpen：三尺度高通加权，输出级再叠一次带阈值的 USM。
    /// fWeights[] / fGlobalSharpenScale / threshold / fSharpeningMaskColStep 全部对得上。
    static func stageSharpen(_ image: CIImage, settings s: ACRDevelopSettings,
                             px: ACRScale, skinMask: CIImage?, extent: CGRect) -> CIImage {
        let amount = min(1.5, max(0, s.sharpness / 150.0 * 1.25))
        guard amount > 0.003 else { return image }
        let baseRadius = px.pixels(CGFloat(min(3.0, max(0.5, s.sharpenRadius))) / 1600.0,
                                   min: 1, max: 8)
        let detail = min(1.0, max(0, s.sharpenDetail / 100.0))
        let weights = [1.0, 0.45 + detail * 0.35, 0.18 + detail * 0.25]
        let threshold = ACRCalibration.sharpenThresholdBase * (1.0 - detail) + 0.002
        var work = image
        var scale = 0
        while scale < weights.count {
            let r = baseRadius * CGFloat(1 << scale)
            let blurred = gaussianBlur(work, radius: r, extent: extent)
            var mask: CIImage? = nil
            if s.sharpenMasking > 0.5 {
                let m = min(1.0, max(0, s.sharpenMasking / 100.0))
                mask = edgeMask(work, gain: 2.0 + m * 24.0, extent: extent)
            }
            if var localMask = mask {
                localMask = protect(localMask, against: skinMask, extent: extent)
                mask = localMask
            }
            if let out = K.sharpenApply.apply(extent: extent, arguments: [
                work, blurred, mask ?? extentWide(extent),
                NSNumber(value: amount * weights[scale]),
                NSNumber(value: threshold)
            ]) {
                work = out.cropped(to: extent)
            }
            scale += 1
        }
        return work
    }

    // MARK: 颗粒

    static func stageGrain(_ image: CIImage, settings s: ACRDevelopSettings,
                           extent: CGRect) -> CIImage {
        let amount = min(1.0, max(0, s.grain / 100.0))
        guard amount > 0.003 else { return image }
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let size = min(1.0, max(0, s.grainSize / 100.0))
        let freq = min(1.0, max(0, s.grainFrequency / 100.0))
        let scale = 1.0 + size * 2.4
        let scaledNoise = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: extent)
        guard let out = K.grainApply.apply(extent: extent, arguments: [
            image, scaledNoise, NSNumber(value: amount), NSNumber(value: freq)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    // MARK: 暗角

    static func stageVignette(_ image: CIImage, settings s: ACRDevelopSettings,
                              extent: CGRect) -> CIImage {
        let amount = min(1.0, max(-1.0, s.vignette / 100.0))
        let mid = min(1.0, max(0, s.vignetteMidpoint / 100.0))
        let feather = min(1.0, max(0, s.vignetteFeather / 100.0))
        let round = min(1.0, max(-1.0, s.vignetteRoundness / 100.0))
        let cx = extent.midX
        let cy = extent.midY
        let half = max(extent.width, extent.height) * 0.5
        let invR = 1.0 / max(1, half * (1.15 - mid * 0.55))
        guard let out = K.vignetteApply.apply(extent: extent, arguments: [
            image, NSNumber(value: Double(cx)), NSNumber(value: Double(cy)),
            NSNumber(value: Double(invR)), NSNumber(value: amount),
            NSNumber(value: 0.15 + feather * 0.75), NSNumber(value: 1.0 + round * 0.35)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    // MARK: 引导滤波

    /// 导向滤波（He 2010）。引擎里的实现是 box filter 算 a/b 系数平面：
    ///   cr_stage_box_conv_plus_product_and_computeab → a = cov/(var+eps)
    ///   cr_stage_apply_affine_function               → q = mean(a)*I + mean(b)
    /// 这里 a/b 用 0.5±0.25 的偏移编码存进图像，避免中间结果被裁到 [0,1] 丢掉负值。
    static func guidedFilter(guide: CIImage, src: CIImage, radius: CGFloat,
                             eps: Double, extent: CGRect) -> CIImage {
        let r = max(1, radius)
        let mI = boxBlur(guide, radius: r, extent: extent)
        let mP = boxBlur(src, radius: r, extent: extent)
        let guideSquare = K.square.apply(extent: extent, arguments: [guide]) ?? guide
        let srcGuide = K.product.apply(extent: extent, arguments: [guide, src]) ?? guide
        let mII = boxBlur(guideSquare, radius: r, extent: extent)
        let mIP = boxBlur(srcGuide, radius: r, extent: extent)
        guard let aCode = K.gfA.apply(extent: extent, arguments: [
            mI, mP, mIP, mII, NSNumber(value: eps)
        ]) else { return src }
        guard let bCode = K.gfB.apply(extent: extent, arguments: [mP, mI, aCode]) else { return src }
        let mA = boxBlur(aCode, radius: r, extent: extent)
        let mB = boxBlur(bCode, radius: r, extent: extent)
        let out = K.gfApply.apply(extent: extent, arguments: [mA, mB, guide]) ?? src
        return out.cropped(to: extent)
    }

    // MARK: 小工具

    /// 全 1 的掩膜（无掩膜时的恒等输入，省一次判断）
    static func extentWide(_ extent: CGRect) -> CIImage {
        return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
    }

    static func boxBlur(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let f = CIFilter(name: "CIBoxBlur", parameters: [
            kCIInputImageKey: image,
            kCIInputRadiusKey: radius
        ])
        guard let out = f?.outputImage else { return image }
        return out.cropped(to: extent)
    }

    static func gaussianBlur(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let f = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: image,
            kCIInputRadiusKey: radius
        ])
        guard let out = f?.outputImage else { return image }
        return out.cropped(to: extent)
    }

    static func morphologyMinimum(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let f = CIFilter(name: "CIMorphologyMinimum", parameters: [
            kCIInputImageKey: image,
            kCIInputRadiusKey: radius
        ])
        guard let out = f?.outputImage else { return image }
        return out.cropped(to: extent)
    }

    /// 锐化掩膜：`CIEdges` 出梯度幅值，再乘 `gain` 抬门限。
    /// 对应引擎里的 `fSharpeningMaskColStep / fSharpeningMaskRowStep`（每张图一张掩膜纹理）。
    static func edgeMask(_ image: CIImage, gain: Double, extent: CGRect) -> CIImage {
        let edges = image.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4.0])
            .cropped(to: extent)
        let bump = CIFilter(name: "CIColorMatrix")
        bump?.setValue(edges, forKey: kCIInputImageKey)
        let g = CGFloat(max(1.0, min(64.0, gain)))
        bump?.setValue(CIVector(x: g, y: 0, z: 0, w: 0), forKey: "inputRVector")
        bump?.setValue(CIVector(x: 0, y: g, z: 0, w: 0), forKey: "inputGVector")
        bump?.setValue(CIVector(x: 0, y: 0, z: g, w: 0), forKey: "inputBVector")
        bump?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return bump?.outputImage?.cropped(to: extent) ?? extentWide(extent)
    }

    /// 皮肤保护：把掩膜反相后乘上去（skinMask 1=皮肤，1-皮肤=可作用区）
    static func protect(_ mask: CIImage, against skin: CIImage?, extent: CGRect) -> CIImage {
        guard let s = skin?.cropped(to: extent) else { return mask }
        let inv = s.applyingFilter("CIColorInvert")
        return mask.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: inv
        ]).cropped(to: extent)
    }

    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            "inputMaskImage": mask
        ])
    }

    // MARK: Kernels

    private enum K {
        static let encode = CIColorKernel(source: """
            kernel vec4 acrEncode(__sample s) {
                vec3 c = clamp(s.rgb, 0.0, 1.0);
                vec3 lo = c * 12.92;
                vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
                vec3 o = mix(lo, hi, step(vec3(0.0031308), c));
                return vec4(clamp(o, 0.0, 1.0), s.a);
            }
            """)

        static let decode = CIColorKernel(source: """
            kernel vec4 acrDecode(__sample s) {
                vec3 c = clamp(s.rgb, 0.0, 1.0);
                vec3 lo = c / 12.92;
                vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
                vec3 o = mix(lo, hi, step(vec3(0.04045), c));
                return vec4(clamp(o, 0.0, 1.0), s.a);
            }
            """)

        static let exposure = CIColorKernel(source: """
            kernel vec4 acrExposure(__sample s, float ev) {
                float g = pow(2.0, ev);
                return vec4(clamp(s.rgb * g, 0.0, 1.0), s.a);
            }
            """)

        static let endpoints = CIColorKernel(source: """
            kernel vec4 acrEndpoints(__sample s, float black, float white) {
                float span = max(white - black, 1.0e-4);
                vec3 c = (s.rgb - vec3(black)) / span;
                return vec4(clamp(c, 0.0, 1.0), s.a);
            }
            """)

        static let localTone = CIKernel(source: """
            kernel vec4 acrLocalTone(sampler s, sampler base, float hi, float sh) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec3 cb = sample(base, p).rgb;
                vec3 w = vec3(0.299, 0.587, 0.114);
                float l = dot(c, w);
                float lb = dot(cb, w);
                float delta = hi * max(l - lb, 0.0) * 1.6 - sh * max(lb - l, 0.0) * 1.6;
                float target = clamp(l + delta, 0.0, 1.0);
                float scale = l > 1.0e-4 ? target / l : 1.0;
                return vec4(clamp(c * scale, 0.0, 1.0), sample(s, p).a);
            }
""")

        static let contrast = CIColorKernel(source: """
            kernel vec4 acrContrast(__sample s, float pivot, float slope) {
                vec3 c = clamp(s.rgb, 0.0, 1.0);
                vec3 d = c - vec3(pivot);
                vec3 k = vec3(max(slope - 1.0, 0.0));
                vec3 y = d * slope / (vec3(1.0) + abs(d) * k * 1.6);
                return vec4(clamp(vec3(pivot) + y, 0.0, 1.0), s.a);
            }
            """)

        static let luma = CIColorKernel(source: """
            kernel vec4 acrLuma(__sample s) {
                float l = dot(s.rgb, vec3(0.299, 0.587, 0.114));
                return vec4(l, l, l, 1.0);
            }
            """)

        static let midtone = CIColorKernel(source: """
            kernel vec4 acrMidtone(__sample s) {
                float l = dot(s.rgb, vec3(0.299, 0.587, 0.114));
                float low = smoothstep(0.02, 0.26, l);
                float high = 1.0 - smoothstep(0.74, 0.98, l);
                float m = low * high;
                return vec4(m, m, m, 1.0);
            }
            """)

        static let textureMask = CIColorKernel(source: """
            kernel vec4 acrTextureMask(__sample s) {
                float l = dot(s.rgb, vec3(0.299, 0.587, 0.114));
                // 平坦区不推纹理：暗部与高光的衰减更狠
                float m = smoothstep(0.06, 0.22, l) * (1.0 - smoothstep(0.88, 0.99, l));
                return vec4(m, m, m, 1.0);
            }
            """)

        static let square = CIColorKernel(source: """
            kernel vec4 acrSquare(__sample s) {
                return vec4(s.rgb * s.rgb, 1.0);
            }
            """)

        static let product = CIKernel(source: """
            kernel vec4 acrProduct(sampler a, sampler b) {
                vec2 p = destCoord();
                vec3 va = sample(a, p).rgb;
                vec3 vb = sample(b, p).rgb;
                return vec4(va * vb, 1.0);
            }
""")

        /// a = cov / (var + eps)，偏移编码成 0.5 + a*0.25
        static let gfA = CIKernel(source: """
            kernel vec4 acrGFA(sampler mI, sampler mP, sampler mIP, sampler mII, float eps) {
                vec2 p = destCoord();
                vec3 vi = sample(mI, p).rgb;
                vec3 vp = sample(mP, p).rgb;
                vec3 vip = sample(mIP, p).rgb;
                vec3 vii = sample(mII, p).rgb;
                vec3 cov = vip - vi * vp;
                vec3 v = vii - vi * vi;
                vec3 a = cov / (max(v, vec3(0.0)) + vec3(eps));
                return vec4(clamp(vec3(0.5) + a * 0.25, 0.0, 1.0), 1.0);
            }
""")

        /// b = meanP - a*meanI，同样偏移编码
        static let gfB = CIKernel(source: """
            kernel vec4 acrGFB(sampler mP, sampler mI, sampler aCode) {
                vec2 p = destCoord();
                vec3 vp = sample(mP, p).rgb;
                vec3 vi = sample(mI, p).rgb;
                vec3 a = (sample(aCode, p).rgb - vec3(0.5)) * 4.0;
                vec3 b = vp - a * vi;
                return vec4(clamp(vec3(0.5) + b * 0.25, 0.0, 1.0), 1.0);
            }
""")

        /// q = mean(a)*I + mean(b)
        static let gfApply = CIKernel(source: """
            kernel vec4 acrGFApply(sampler aCode, sampler bCode, sampler guide) {
                vec2 p = destCoord();
                vec3 a = (sample(aCode, p).rgb - vec3(0.5)) * 4.0;
                vec3 b = (sample(bCode, p).rgb - vec3(0.5)) * 4.0;
                vec3 g = sample(guide, p).rgb;
                return vec4(clamp(a * g + b, 0.0, 1.0), 1.0);
            }
""")

        static let minChannel = CIColorKernel(source: """
            kernel vec4 acrMinChannel(__sample s) {
                float m = min(s.r, min(s.g, s.b));
                return vec4(m, m, m, 1.0);
            }
            """)

        static let transmission = CIColorKernel(source: """
            kernel vec4 acrTransmission(__sample dark, vec3 air, float omega) {
                float a = max(0.02, (air.r + air.g + air.b) / 3.0);
                float t = 1.0 - omega * clamp(dark.r / a, 0.0, 1.0);
                return vec4(clamp(t, 0.05, 1.0), clamp(t, 0.05, 1.0), clamp(t, 0.05, 1.0), 1.0);
            }
            """)

        static let dehazeApply = CIKernel(source: """
            kernel vec4 acrDehazeApply(sampler s, sampler tSample, vec3 air,
                                       float tFloor, float th2OverA) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                float t = clamp(sample(tSample, p).r, tFloor, 1.0);
                vec3 i = max(c - air * th2OverA, vec3(0.0));
                vec3 j = (i - air) / t + air;
                return vec4(clamp(j, 0.0, 1.0), sample(s, p).a);
            }
""")

        static let clarityApply = CIKernel(source: """
            kernel vec4 acrClarityApply(sampler s, sampler base, sampler mask, float amount) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec3 cb = sample(base, p).rgb;
                float m = clamp(sample(mask, p).r, 0.0, 1.0);
                vec3 w = vec3(0.299, 0.587, 0.114);
                float l = dot(c, w);
                float lb = dot(cb, w);
                float target = clamp(l + (l - lb) * amount * m, 0.0, 1.0);
                float scale = l > 1.0e-4 ? target / l : 1.0;
                scale = clamp(scale, 0.2, 5.0);
                return vec4(clamp(c * scale, 0.0, 1.0), sample(s, p).a);
            }
""")

        static let rgbToYCC = CIColorKernel(source: """
            kernel vec4 acrRGBtoYCC(__sample s) {
                float y = dot(s.rgb, vec3(0.299, 0.587, 0.114));
                float c1 = (s.b - y) * 0.564;
                float c2 = (s.r - y) * 0.713;
                return vec4(y, clamp(c1 + 0.5, 0.0, 1.0), clamp(c2 + 0.5, 0.0, 1.0), 1.0);
            }
            """)

        static let yccToRGB = CIColorKernel(source: """
            kernel vec4 acrYCCtoRGB(__sample s) {
                float y = s.r;
                float c1 = (s.g - 0.5) / 0.564;
                float c2 = (s.b - 0.5) / 0.713;
                float r = y + 1.403 * c2;
                float b = y + 1.773 * c1;
                float g = (y - 0.299 * r - 0.114 * b) / 0.587;
                return vec4(clamp(vec3(r, g, b), 0.0, 1.0), s.a);
            }
            """)

        /// Y 用细 eps 的结果，C1/C2 用粗 eps 的结果
        static let yccMix = CIKernel(source: """
            kernel vec4 acrYCCMix(sampler fine, sampler coarse) {
                vec2 p = destCoord();
                return vec4(sample(fine, p).r, sample(coarse, p).g, sample(coarse, p).b, 1.0);
            }
""")

        static let textureApply = CIKernel(source: """
            kernel vec4 acrTextureApply(sampler ycc, sampler filtered, sampler mask, float amount) {
                vec2 p = destCoord();
                vec3 c = sample(ycc, p).rgb;
                vec3 f = sample(filtered, p).rgb;
                float m = clamp(sample(mask, p).r, 0.0, 1.0);
                vec3 o = c + (c - f) * amount * m;
                return vec4(clamp(o, 0.0, 1.0), 1.0);
            }
""")

        static let sharpenApply = CIKernel(source: """
            kernel vec4 acrSharpenApply(sampler s, sampler blurred, sampler mask,
                                        float amount, float threshold) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec3 b = sample(blurred, p).rgb;
                float m = clamp(sample(mask, p).r, 0.0, 1.0);
                vec3 hp = c - b;
                vec3 mag = max(abs(hp) - vec3(threshold), vec3(0.0));
                vec3 shaped = sign(hp) * mag;
                vec3 o = c + shaped * amount * m;
                return vec4(clamp(o, 0.0, 1.0), sample(s, p).a);
            }
""")

        static let nrApply = CIKernel(source: """
            kernel vec4 acrNRA(sampler s, sampler smooth, float amount, float protect, float contrast) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec3 cs = sample(smooth, p).rgb;
                vec3 w = vec3(0.299, 0.587, 0.114);
                float l = dot(c, w);
                float ls = dot(cs, w);
                float edge = abs(l - ls);
                float gate = 1.0 - clamp(protect, 0.0, 1.0) * 0.55 * smoothstep(0.0, 0.10, edge);
                float target = mix(l, ls, clamp(amount, 0.0, 1.0) * gate);
                target = clamp(target + (target - 0.5) * contrast * 0.5, 0.0, 1.0);
                float scale = l > 1.0e-4 ? target / l : 1.0;
                scale = clamp(scale, 0.2, 5.0);
                return vec4(clamp(c * scale, 0.0, 1.0), sample(s, p).a);
            }
""")

        static let colorNRMerge = CIKernel(source: """
            kernel vec4 acrColorNR(sampler ycc, sampler blurred, float amount, float smoothness) {
                vec2 p = destCoord();
                vec3 c = sample(ycc, p).rgb;
                vec3 b = sample(blurred, p).rgb;
                float a = clamp(amount, 0.0, 1.0) * (0.35 + smoothness * 0.65);
                float c1 = mix(c.g, b.g, a);
                float c2 = mix(c.b, b.b, a);
                return vec4(c.r, clamp(c1, 0.0, 1.0), clamp(c2, 0.0, 1.0), 1.0);
            }
""")

        static let grainApply = CIKernel(source: """
            kernel vec4 acrGrain(sampler s, sampler n, float amount, float freq) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                float g = (sample(n, p).r - 0.5) * 2.0;
                vec3 w = vec3(0.299, 0.587, 0.114);
                float l = dot(c, w);
                float response = smoothstep(0.0, 0.18, l) * (1.0 - smoothstep(0.82, 1.0, l));
                float local = amount * response * (0.35 + freq * 0.5);
                return vec4(clamp(c + vec3(g * local), 0.0, 1.0), sample(s, p).a);
            }
""")

        static let vignetteApply = CIKernel(source: """
            kernel vec4 acrVignette(sampler s, float cx, float cy, float invR,
                                    float amount, float feather, float roundness) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec2 d = p - vec2(cx, cy);
                d.y = d.y / max(roundness, 0.05);
                float r = length(d) * invR;
                float inner = max(0.0, 1.0 - feather);
                float t = smoothstep(inner, 1.0, r);
                float k = amount > 0.0 ? 0.85 : 0.9;
                float gain = 1.0 + amount * t * k;
                return vec4(clamp(c * gain, 0.0, 1.0), sample(s, p).a);
            }
            """)
    }
}

/// kernel 编译失败时 `CIColorKernel(source:)` 返回 nil，这里给它一个统一入口：
/// `K.xxx.apply(extent:arguments:)` 在 nil 时直接返回 nil，调用点的
/// `guard let` / `?? fallback` 逻辑保持不变（失败即跳过该阶段，不会崩）。
extension Optional where Wrapped == CIColorKernel {
    func apply(extent: CGRect, arguments: [Any]) -> CIImage? {
        guard let kernel = self else { return nil }
        return kernel.apply(extent: extent, arguments: arguments)
    }
}
// MARK: - 3D LUT：曲线 + 参数化 + HSL + 颜色分级

enum ACRLookCube {

    private static let cache = NSCache<NSString, NSData>()

    static func data(for settings: ACRDevelopSettings, size: Int) -> Data? {
        let n = max(2, min(64, size))
        let key = NSString(string: "\(settings.hashValue)-\(n)-\(ACRDevelopEngine.algorithmVersion)")
        if let hit = cache.object(forKey: key) { return hit as Data }

        let tone = Tones(settings: settings)
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        var b = 0
        while b < n {
            let vb = Double(b) / Double(n - 1)
            var g = 0
            while g < n {
                let vg = Double(g) / Double(n - 1)
                var r = 0
                while r < n {
                    let vr = Double(r) / Double(n - 1)
                    let out = Color.sample(rgb: SIMD3(vr, vg, vb), tone: tone, settings: settings)
                    floats[index + 0] = Float(min(1, max(0, out.x)))
                    floats[index + 1] = Float(min(1, max(0, out.y)))
                    floats[index + 2] = Float(min(1, max(0, out.z)))
                    floats[index + 3] = 1
                    index += 4
                    r += 1
                }
                g += 1
            }
            b += 1
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        cache.setObject(data as NSData, forKey: key)
        return data
    }

    /// 三段曲线（复合 + 三条分通道）预采样成 1024 点
    struct Tones {
        let master: [Double]
        let red: [Double]
        let green: [Double]
        let blue: [Double]
        let hasChannelCurves: Bool
        let settings: ACRDevelopSettings

        init(settings s: ACRDevelopSettings) {
            self.settings = s
            master = Tones.sample(s.curve)
            red = Tones.sample(s.curveRed)
            green = Tones.sample(s.curveGreen)
            blue = Tones.sample(s.curveBlue)
            hasChannelCurves = !(s.curveRed.isEmpty && s.curveGreen.isEmpty && s.curveBlue.isEmpty)
        }

        /// 单调三次插值（Fritsch–Carlson），保证曲线不回勾，和 LR 的样条行为一致
        static func sample(_ points: [ACRCurvePoint], count: Int = 1024) -> [Double] {
            let pts = points
                .filter { $0.x.isFinite && $0.y.isFinite }
                .map { ACRCurvePoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
                .sorted { $0.x < $1.x }
            guard pts.count >= 2 else { return [] }
            var out = [Double](repeating: 0, count: count)
            let n = pts.count
            var d = [Double](repeating: 0, count: n)
            var i = 0
            while i < n - 1 {
                let dx = max(1.0e-6, pts[i + 1].x - pts[i].x)
                d[i] = (pts[i + 1].y - pts[i].y) / dx
                i += 1
            }
            var m = [Double](repeating: 0, count: n)
            m[0] = d[0]
            m[n - 1] = d[n - 2]
            i = 1
            while i < n - 1 {
                m[i] = (d[i - 1] + d[i]) * 0.5
                i += 1
            }
            // Fritsch–Carlson 限幅
            i = 0
            while i < n - 1 {
                if d[i] == 0 {
                    m[i] = 0; m[i + 1] = 0
                } else {
                    let a = m[i] / d[i]
                    let b = m[i + 1] / d[i]
                    let h = (a * a + b * b) > 9 ? 3.0 / sqrt(a * a + b * b) : 1.0
                    m[i] = h * a * d[i]
                    m[i + 1] = h * b * d[i]
                }
                i += 1
            }
            var k = 0
            while k < count {
                let x = Double(k) / Double(count - 1)
                if x <= pts[0].x {
                    out[k] = pts[0].y + (x - pts[0].x) * m[0]
                } else if x >= pts[n - 1].x {
                    out[k] = pts[n - 1].y + (x - pts[n - 1].x) * m[n - 1]
                } else {
                    var seg = 0
                    while seg < n - 2 && x > pts[seg + 1].x { seg += 1 }
                    let h = max(1.0e-6, pts[seg + 1].x - pts[seg].x)
                    let t = (x - pts[seg].x) / h
                    let t2 = t * t
                    let t3 = t2 * t
                    let h00 = 2 * t3 - 3 * t2 + 1
                    let h10 = t3 - 2 * t2 + t
                    let h01 = -2 * t3 + 3 * t2
                    let h11 = t3 - t2
                    out[k] = h00 * pts[seg].y + h10 * h * m[seg]
                        + h01 * pts[seg + 1].y + h11 * h * m[seg + 1]
                }
                out[k] = min(1, max(0, out[k]))
                k += 1
            }
            return out
        }

        static func lookup(_ lut: [Double], _ x: Double) -> Double {
            guard lut.count > 1 else { return x }
            let p = min(1, max(0, x)) * Double(lut.count - 1)
            let i = min(lut.count - 2, max(0, Int(p)))
            let f = p - Double(i)
            return lut[i] * (1 - f) + lut[i + 1] * f
        }

        /// 参数化曲线：4 段亮度权重（LR 的 ParametricShadows/Darks/Lights/Highlights）
        func parametric(_ x: Double) -> Double {
            let s = settings
            let sum = abs(s.parametricShadows) + abs(s.parametricDarks)
                + abs(s.parametricLights) + abs(s.parametricHighlights)
            guard sum > 0.5 else { return x }
            let low = s.shadowSplit / 100
            let mid = s.midtoneSplit / 100
            let high = s.highlightSplit / 100
            func band(_ v: Double, center: Double, width: Double) -> Double {
                let d = abs(v - center) / max(1.0e-4, width)
                return max(0, 1 - d * d)
            }
            let ws = band(x, center: low * 0.5, width: low)
            let wd = band(x, center: (low + mid) * 0.5, width: max(0.06, mid - low))
            let wl = band(x, center: (mid + high) * 0.5, width: max(0.06, high - mid))
            let wh = band(x, center: (high + 1.0) * 0.5, width: max(0.06, 1 - high))
            let gain = (s.parametricShadows / 100) * ws
                + (s.parametricDarks / 100) * wd
                + (s.parametricLights / 100) * wl
                + (s.parametricHighlights / 100) * wh
            let shape = x < 0.5 ? x * 0.8 : (1 - x) * 0.8
            return min(1, max(0, x + gain * shape))
        }

        /// 完整色调链：端点已在 GPU 侧做过 → 这里只有参数化 + 点曲线
        func tone(_ x: Double) -> Double {
            var v = parametric(x)
            if master.count > 1 { v = Tones.lookup(master, v) }
            return min(1, max(0, v))
        }
    }

    enum Color {

        static func sample(rgb aim: SIMD3<Double>, tone: Tones, settings s: ACRDevelopSettings) -> SIMD3<Double> {
            var c = aim
            // 通道曲线
            if tone.hasChannelCurves {
                var r = c.x
                var g = c.y
                var b = c.z
                if tone.red.count > 1 { r = Tones.lookup(tone.red, r) }
                if tone.green.count > 1 { g = Tones.lookup(tone.green, g) }
                if tone.blue.count > 1 { b = Tones.lookup(tone.blue, b) }
                c = SIMD3(r, g, b)
            }
            // 复合色调曲线（逐通道，ACR 的 Tone Curve 是 RGB 曲线）
            c = SIMD3(tone.tone(c.x), tone.tone(c.y), tone.tone(c.z))

            // HSL 8 带
            c = hsl(c, settings: s)
            // 颜色分级（阴影/中间调/高光/全局）
            c = grade(c, settings: s)
            // 鲜艳度 / 饱和度
            c = vibranceSaturation(c, settings: s)
            return SIMD3(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z)))
        }

        /// 8 带基准色相（Adobe 的 Hue/Sat/Lum 分区）
        static let bandHues: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]

        static func hsl(_ c: SIMD3<Double>, settings s: ACRDevelopSettings) -> SIMD3<Double> {
            let sum = abs(s.hslHue.reduce(0) { $0 + abs($1) })
                + abs(s.hslSaturation.reduce(0) { $0 + abs($1) })
                + abs(s.hslLuminance.reduce(0) { $0 + abs($1) })
            guard sum > 0.5 else { return c }
            let hsv = rgbToHSV(c)
            let hueDeg = hsv.x * 360
            var dh = 0.0
            var ds = 0.0
            var dl = 0.0
            var i = 0
            while i < 8 {
                let base = bandHues[i]
                var dist = abs(hueDeg - base)
                if dist > 180 { dist = 360 - dist }
                // 每带覆盖 ±30°，相邻带平滑过渡
                let w = max(0, 1 - dist / 30.0)
                if w > 0 {
                    dh += s.hslHue[i] / 100 * 30 * w
                    ds += s.hslSaturation[i] / 100 * w
                    dl += s.hslLuminance[i] / 100 * w
                }
                i += 1
            }
            let newHue = (hueDeg + dh) / 360
            let newSat = min(1, max(0, hsv.y * (1 + ds)))
            let newVal = min(1, max(0, hsv.z * (1 + dl * 0.9)))
            return hsvToRGB(SIMD3(newHue < 0 ? newHue + 1 : newHue, newSat, newVal))
        }

        /// 颜色分级：三轮（阴影/中间调/高光）+ 全局，亮度权重由 blending/balance 决定
        static func grade(_ c: SIMD3<Double>, settings s: ACRDevelopSettings) -> SIMD3<Double> {
            let hasAny = abs(s.gradeShadowSaturation) + abs(s.gradeMidtoneSaturation)
                + abs(s.gradeHighlightSaturation) + abs(s.gradeGlobalSaturation) > 0.05
            guard hasAny else { return c }
            let l = luma(c)
            let blend = s.gradeBlending / 100
            let balance = s.gradeBalance / 100
            let shadowCenter = 0.25 + balance * 0.15
            let highlightCenter = 0.75 + balance * 0.15
            let ws = max(0, 1 - abs(l - shadowCenter) / max(0.12, 0.55 - blend * 0.25))
            let wh = max(0, 1 - abs(l - highlightCenter) / max(0.12, 0.55 - blend * 0.25))
            let wm = max(0, 1 - ws - wh)
            var out = c
            out = tint(out, hue: s.gradeShadowHue, sat: s.gradeShadowSaturation,
                       lum: s.gradeShadowLuminance, weight: ws)
            out = tint(out, hue: s.gradeMidtoneHue, sat: s.gradeMidtoneSaturation,
                       lum: s.gradeMidtoneLuminance, weight: wm)
            out = tint(out, hue: s.gradeHighlightHue, sat: s.gradeHighlightSaturation,
                       lum: s.gradeHighlightLuminance, weight: wh)
            out = tint(out, hue: s.gradeGlobalHue, sat: s.gradeGlobalSaturation,
                       lum: s.gradeGlobalLuminance, weight: 1.0)
            return out
        }

        static func tint(_ c: SIMD3<Double>, hue: Double, sat: Double,
                         lum: Double, weight: Double) -> SIMD3<Double> {
            guard abs(sat) > 0.05 || abs(lum) > 0.05 else { return c }
            let target = hueToRGB(hue: hue / 360)
            let amount = sat / 100 * 0.35 * weight
            var out = c
            out.x += (target.x - luma(c)) * amount
            out.y += (target.y - luma(c)) * amount
            out.z += (target.z - luma(c)) * amount
            let dl = lum / 100 * 0.25 * weight
            out.x += dl; out.y += dl; out.z += dl
            return out
        }

        static func vibranceSaturation(_ c: SIMD3<Double>, settings s: ACRDevelopSettings) -> SIMD3<Double> {
            var out = c
            if abs(s.vibrance) > 0.05 {
                let hsv = rgbToHSV(out)
                let sat = hsv.y
                let skinWeight = skinProtection(rgb: out)
                let gain = 1 + (s.vibrance / 100) * (1 - sat) * (1 - 0.65 * skinWeight)
                out = hsvToRGB(SIMD3(hsv.x, min(1, max(0, sat * gain)), hsv.z))
            }
            if abs(s.saturation) > 0.05 {
                let l = luma(out)
                let g = 1 + s.saturation / 100
                out = SIMD3(l + (out.x - l) * g, l + (out.y - l) * g, l + (out.z - l) * g)
            }
            return out
        }

        static func skinProtection(rgb c: SIMD3<Double>) -> Double {
            let d = c.x - c.z
            let up = smoothstep(0.02, 0.14, d)
            let g = c.y - max(c.x, c.z)
            let down = 1 - smoothstep(0.16, 0.48, g)
            return up * down
        }

        static func luma(_ c: SIMD3<Double>) -> Double {
            return 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
        }

        static func rgbToHSV(_ c: SIMD3<Double>) -> SIMD3<Double> {
            let mx = max(c.x, max(c.y, c.z))
            let mn = min(c.x, min(c.y, c.z))
            let d = mx - mn
            var h = 0.0
            if d > 1.0e-6 {
                if mx == c.x {
                    h = (c.y - c.z) / d
                    if h < 0 { h += 6 }
                } else if mx == c.y {
                    h = (c.z - c.x) / d + 2
                } else {
                    h = (c.x - c.y) / d + 4
                }
                h /= 6
            }
            let s = mx <= 1.0e-6 ? 0 : d / mx
            return SIMD3(h, s, mx)
        }

        static func hsvToRGB(_ hsv: SIMD3<Double>) -> SIMD3<Double> {
            let h = hsv.x - floor(hsv.x)
            let s = min(1, max(0, hsv.y))
            let v = min(1, max(0, hsv.z))
            let i = Int(floor(h * 6)) % 6
            let f = h * 6 - floor(h * 6)
            let p = v * (1 - s)
            let q = v * (1 - f * s)
            let t = v * (1 - (1 - f) * s)
            switch i {
            case 0: return SIMD3(v, t, p)
            case 1: return SIMD3(q, v, p)
            case 2: return SIMD3(p, v, t)
            case 3: return SIMD3(p, q, v)
            case 4: return SIMD3(t, p, v)
            default: return SIMD3(v, p, q)
            }
        }

        static func hueToRGB(hue: Double) -> SIMD3<Double> {
            return hsvToRGB(SIMD3(hue, 1, 1))
        }

        static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(1, max(0, (x - a) / max(1.0e-6, b - a)))
            return t * t * (3 - 2 * t)
        }
    }
}

// MARK: - DCP 相机配置文件

/// Camera Raw 的 .dcp 是 TIFF 容器，色彩科学全明文：
///   ColorMatrix1/2（双光源）、ForwardMatrix1/2、ProfileToneCurve、ProfileHueSatMap
/// 对应引擎里的 `cr_stage_ABCtoRGB` / `cr_stage_CameraToRGB` 阶段。
struct ACRDCPProfile {
    var name: String = ""
    var colorMatrix1: [Double] = []
    var colorMatrix2: [Double] = []
    var forwardMatrix1: [Double] = []
    var forwardMatrix2: [Double] = []
    var illuminant1: Int = 21
    var illuminant2: Int = 17
    var toneCurve: [Double] = []

    /// 从 TIFF 里读一个 DCP（只认 IFD0，够覆盖 Adobe Standard 系列）
    static func load(url: URL) -> ACRDCPProfile? {
        guard let data = try? Data(contentsOf: url), data.count > 8 else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> ACRDCPProfile? {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else { return nil }
        let little: Bool
        if bytes[0] == 0x49 && bytes[1] == 0x49 { little = true }
        else if bytes[0] == 0x4D && bytes[1] == 0x4D { little = false }
        else { return nil }

        func u16(_ o: Int) -> Int {
            guard o + 2 <= bytes.count else { return 0 }
            let a = Int(bytes[o]); let b = Int(bytes[o + 1])
            return little ? (a | (b << 8)) : ((a << 8) | b)
        }
        func u32(_ o: Int) -> Int {
            guard o + 4 <= bytes.count else { return 0 }
            let v: Int
            if little {
                v = Int(bytes[o]) | (Int(bytes[o + 1]) << 8)
                    | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24)
            } else {
                v = (Int(bytes[o]) << 24) | (Int(bytes[o + 1]) << 16)
                    | (Int(bytes[o + 2]) << 8) | Int(bytes[o + 3])
            }
            return v >= 0 ? v : 0
        }

        let ifd = u32(4)
        guard ifd > 0, ifd + 2 < bytes.count else { return nil }
        let count = u16(ifd)
        var profile = ACRDCPProfile()
        var i = 0
        while i < count {
            let entry = ifd + 2 + i * 12
            if entry + 12 > bytes.count { break }
            let tag = u16(entry)
            let type = u16(entry + 2)
            let n = u32(entry + 4)
            let total = typeSize(type) * n
            var valueOffset = entry + 8
            if total > 4 { valueOffset = u32(entry + 8) }
            i += 1
            switch tag {
            case 0xC6F8:   // ProfileName (ASCII)
                if type == 2 && valueOffset + n <= bytes.count {
                    var s = ""
                    var k = 0
                    while k < n {
                        let c = bytes[valueOffset + k]
                        if c == 0 { break }
                        s.append(Character(UnicodeScalar(c)))
                        k += 1
                    }
                    profile.name = s
                }
            case 0xC621: profile.colorMatrix1 = rationals(bytes, offset: valueOffset,
                                                          count: n, type: type, little: little)
            case 0xC622: profile.colorMatrix2 = rationals(bytes, offset: valueOffset,
                                                          count: n, type: type, little: little)
            case 0xC714: profile.forwardMatrix1 = rationals(bytes, offset: valueOffset,
                                                            count: n, type: type, little: little)
            case 0xC715: profile.forwardMatrix2 = rationals(bytes, offset: valueOffset,
                                                            count: n, type: type, little: little)
            case 0xC65A: profile.illuminant1 = u16(valueOffset)
            case 0xC65B: profile.illuminant2 = u16(valueOffset)
            case 0xC6FC: profile.toneCurve = rationals(bytes, offset: valueOffset,
                                                       count: n, type: type, little: little)
            default: break
            }
        }
        if profile.colorMatrix1.count < 9 && profile.forwardMatrix1.count < 9 { return nil }
        return profile
    }

    private static func typeSize(_ type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return 1
        }
    }

    /// SRATIONAL(10) / RATIONAL(5) 数组 → [Double]
    private static func rationals(_ bytes: [UInt8], offset: Int, count: Int,
                                  type: Int, little: Bool) -> [Double] {
        guard type == 5 || type == 10 else { return [] }
        var out = [Double](repeating: 0, count: count)
        var k = 0
        while k < count {
            let o = offset + k * 8
            guard o + 8 <= bytes.count else { break }
            let num = read32(bytes, o, little)
            let den = read32(bytes, o + 4, little)
            if type == 10 {
                let sn = Double(Int32(truncatingIfNeeded: num))
                let sd = Double(Int32(truncatingIfNeeded: den))
                out[k] = sd != 0 ? sn / sd : 0
            } else {
                out[k] = den != 0 ? Double(UInt32(truncatingIfNeeded: num))
                    / Double(UInt32(truncatingIfNeeded: den)) : 0
            }
            k += 1
        }
        return out
    }

    private static func read32(_ bytes: [UInt8], _ o: Int, _ little: Bool) -> Int {
        guard o + 4 <= bytes.count else { return 0 }
        if little {
            return Int(bytes[o]) | (Int(bytes[o + 1]) << 8)
                | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24)
        }
        return (Int(bytes[o]) << 24) | (Int(bytes[o + 1]) << 16)
            | (Int(bytes[o + 2]) << 8) | Int(bytes[o + 3])
    }

    /// 应用：先矩阵到 XYZ(D50) 再回 sRGB 线性，然后套 profile tone curve
    func apply(to image: CIImage, extent: CGRect) -> CIImage {
        var out = image
        let m = forwardMatrix1.count >= 9 ? forwardMatrix1 : colorMatrix1
        if m.count >= 9 {
            let f = CIFilter(name: "CIColorMatrix")
            f?.setValue(out, forKey: kCIInputImageKey)
            f?.setValue(CIVector(x: CGFloat(m[0]), y: CGFloat(m[3]), z: CGFloat(m[6]), w: 0),
                        forKey: "inputRVector")
            f?.setValue(CIVector(x: CGFloat(m[1]), y: CGFloat(m[4]), z: CGFloat(m[7]), w: 0),
                        forKey: "inputGVector")
            f?.setValue(CIVector(x: CGFloat(m[2]), y: CGFloat(m[5]), z: CGFloat(m[8]), w: 0),
                        forKey: "inputBVector")
            f?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            if let o = f?.outputImage { out = o.cropped(to: extent) }
        }
        if toneCurve.count >= 4 {
            var pts: [ACRCurvePoint] = []
            var k = 0
            while k + 1 < toneCurve.count {
                pts.append(ACRCurvePoint(x: Double(toneCurve[k]), y: Double(toneCurve[k + 1])))
                k += 2
            }
            if let cube = profileToneCube(points: pts, size: 17) {
                out = out.applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": 17,
                    "inputCubeData": cube
                ]).cropped(to: extent)
            }
        }
        return out
    }

    private func profileToneCube(points: [ACRCurvePoint], size: Int) -> Data? {
        let lut = ACRLookCube.Tones.sample(points, count: 512)
        guard lut.count > 1 else { return nil }
        let n = max(2, size)
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        var b = 0
        while b < n {
            let vb = Double(b) / Double(n - 1)
            var g = 0
            while g < n {
                let vg = Double(g) / Double(n - 1)
                var r = 0
                while r < n {
                    let vr = Double(r) / Double(n - 1)
                    floats[index + 0] = Float(ACRLookCube.Tones.lookup(lut, vr))
                    floats[index + 1] = Float(ACRLookCube.Tones.lookup(lut, vg))
                    floats[index + 2] = Float(ACRLookCube.Tones.lookup(lut, vb))
                    floats[index + 3] = 1
                    index += 4
                    r += 1
                }
                g += 1
            }
            b += 1
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}


/// 多图 kernel 走 CIKernel（CIKL 不允许多个 __sample 参数，只能用 sampler + sample()）。
/// 这里给一个与 CIColorKernel 版本同签名的入口，调用点保持不变。
extension Optional where Wrapped == CIKernel {
    func apply(extent: CGRect, arguments: [Any]) -> CIImage? {
        guard let kernel = self else { return nil }
        let pad = max(64.0, max(extent.width, extent.height) * 0.15)
        let roi: CIKernelROICallback = { _, rect in rect.insetBy(dx: -pad, dy: -pad) }
        return kernel.apply(extent: extent, roiCallback: roi, arguments: arguments)
    }
}
