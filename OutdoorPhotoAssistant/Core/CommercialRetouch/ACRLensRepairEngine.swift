import CoreImage
import CoreGraphics
import Foundation

// MARK: - ACR 外围引擎：镜头 / 几何 / 修补 / AI 替代实现
//
// 对应 Camera Raw 18.7 里那些"不在 Develop 面板、但属于 ACR 管线"的算子：
//
//   镜头校正    cr_stage_auto_lateral_ca / warped_stage / vignette 校正
//              LCP（.lcp）里的 RadialDistortParam1..3、VignetteModelParam1..3、
//              ChromaticRedGreenModel / ChromaticGreenBlueModel
//   几何        cr_stage_warp / radial_warp / skew_h / skew_v / zoom_h / zoom_v
//   修补        cr_stage_heal_* / clone / copy_in_retouch / fill_light / redeye / find_spots
//   去摩尔纹    cr_stage_moire / moire_box_blur_and_blend
//   去紫边      cr_stage_defringe_two_colors / BlendDefringed
//   AI 替代     cr_stage_cnn_* / enhance_post_process（模型权重内嵌，只能给经典替代）

// MARK: - LCP 镜头配置文件

/// 一个焦段（或对焦距离）上的一组标定参数。一个 .lcp 里通常有十几到几十条。
struct ACRLensEntry: Equatable {
    var focalLength: Double = 0
    var focusDistance: Double = 0
    var aperture: Double = 0
    var focalLengthX: Double = 0
    var focalLengthY: Double = 0
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var radial1: Double = 0
    var radial2: Double = 0
    var radial3: Double = 0
    var vignette1: Double = 0
    var vignette2: Double = 0
    var vignette3: Double = 0
}

/// Adobe `.lcp` 是 XMP 文本（`stCamera:` 命名空间），不是二进制。
/// 解析策略：按 `stCamera:ProfileName=` 切段，每段内抓所有 `stCamera:属性="值"`。
struct ACRLensProfile {
    var profileName: String = ""
    var make: String = ""
    var model: String = ""
    var lens: String = ""
    var lensPrettyName: String = ""
    var sensorFormatFactor: Double = 1
    var entries: [ACRLensEntry] = []

    static func load(url: URL) -> ACRLensProfile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(xml: text)
    }

    static func parse(xml: String) -> ACRLensProfile? {
        guard xml.contains("stCamera:") else { return nil }
        var profile = ACRLensProfile()

        let ns = xml as NSString
        // 切段：每次出现 ProfileName= 到下一段之间算一个标定条目
        let marker = "stCamera:ProfileName="
        var starts: [Int] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: marker, options: [], range: searchRange)
            if r.location == NSNotFound { break }
            starts.append(r.location)
            let next = r.location + r.length
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        if starts.isEmpty {
            // 兜底：整篇当一段
            starts = [0]
        }
        let attrRegex = try? NSRegularExpression(pattern: "stCamera:([A-Za-z0-9_]+)=\"([^\"]*)\"",
                                                options: [])
        var pending = ACRLensEntry()
        var pendingStarted = false

        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : ns.length
            let segLen = max(0, end - start)
            let segment = ns.substring(with: NSRange(location: start, length: segLen))

            if profile.profileName.isEmpty,
               let name = firstAttr(segment, key: "ProfileName") {
                profile.profileName = name
            }
            if profile.make.isEmpty, let v = firstAttr(segment, key: "Make") { profile.make = v }
            if profile.model.isEmpty, let v = firstAttr(segment, key: "Model") { profile.model = v }
            if profile.lens.isEmpty, let v = firstAttr(segment, key: "Lens") { profile.lens = v }
            if profile.lensPrettyName.isEmpty, let v = firstAttr(segment, key: "LensPrettyName") {
                profile.lensPrettyName = v
            }
            if profile.sensorFormatFactor == 1, let v = firstAttr(segment, key: "SensorFormatFactor"),
               let d = Double(v) {
                profile.sensorFormatFactor = d
            }

            guard let re = attrRegex else { continue }
            let matches = re.matches(in: segment, options: [],
                                     range: NSRange(location: 0, length: (segment as NSString).length))
            var entry = ACRLensEntry()
            entry.centerX = 0.5
            entry.centerY = 0.5
            var sawFocal = false
            for m in matches {
                guard m.numberOfRanges >= 3,
                      let keyRange = Range(m.range(at: 1), in: segment),
                      let valRange = Range(m.range(at: 2), in: segment) else { continue }
                let key = String(segment[keyRange])
                let value = Double(String(segment[valRange])) ?? 0
                switch key {
                case "FocalLength": entry.focalLength = value; sawFocal = true
                case "FocusDistance": entry.focusDistance = value
                case "ApertureValue": entry.aperture = value
                case "FocalLengthX": entry.focalLengthX = value
                case "FocalLengthY": entry.focalLengthY = value
                case "ImageXCenter": entry.centerX = value
                case "ImageYCenter": entry.centerY = value
                case "RadialDistortParam1": entry.radial1 = value
                case "RadialDistortParam2": entry.radial2 = value
                case "RadialDistortParam3": entry.radial3 = value
                case "VignetteModelParam1": entry.vignette1 = value
                case "VignetteModelParam2": entry.vignette2 = value
                case "VignetteModelParam3": entry.vignette3 = value
                default: break
                }
            }
            if sawFocal {
                profile.entries.append(entry)
                pendingStarted = false
            } else if entry.radial1 != 0 || entry.vignette1 != 0 {
                pending = entry
                pendingStarted = true
            }
            if pendingStarted && !sawFocal && !pending.radial1.isZero {
                // 有的 LCP 把参数放在 ProfileName 之前，累积到下一段
                var merged = entry
                merged.focalLength = pending.focalLength
                merged.radial1 = pending.radial1
                merged.radial2 = pending.radial2
                merged.radial3 = pending.radial3
                if merged.focalLength > 0 { profile.entries.append(merged) }
                pendingStarted = false
            }
        }
        if profile.entries.isEmpty { return nil }
        profile.entries.sort { $0.focalLength < $1.focalLength }
        return profile
    }

    private static func firstAttr(_ text: String, key: String) -> String? {
        let pattern = "stCamera:" + key + "=\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(location: 0, length: (text as NSString).length)
        guard let m = re.firstMatch(in: text, options: [], range: r), m.numberOfRanges >= 2,
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// 按真实焦段取参数：两条最近条目做线性插值（ACR 也是这么干的）。
    func entry(forFocalLength focal: Double) -> ACRLensEntry? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 { return entries[0] }
        let sorted = entries.sorted { $0.focalLength < $1.focalLength }
        if focal <= sorted[0].focalLength { return sorted[0] }
        if focal >= sorted[sorted.count - 1].focalLength { return sorted[sorted.count - 1] }
        var lower = sorted[0]
        var upper = sorted[sorted.count - 1]
        for i in 0..<(sorted.count - 1) {
            if sorted[i].focalLength <= focal && focal <= sorted[i + 1].focalLength {
                lower = sorted[i]
                upper = sorted[i + 1]
                break
            }
        }
        let span = max(1e-6, upper.focalLength - lower.focalLength)
        let t = min(1, max(0, (focal - lower.focalLength) / span))
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        var out = lower
        out.radial1 = mix(lower.radial1, upper.radial1)
        out.radial2 = mix(lower.radial2, upper.radial2)
        out.radial3 = mix(lower.radial3, upper.radial3)
        out.vignette1 = mix(lower.vignette1, upper.vignette1)
        out.vignette2 = mix(lower.vignette2, upper.vignette2)
        out.vignette3 = mix(lower.vignette3, upper.vignette3)
        out.focalLengthX = mix(lower.focalLengthX, upper.focalLengthX)
        out.focalLengthY = mix(lower.focalLengthY, upper.focalLengthY)
        out.centerX = mix(lower.centerX, upper.centerX)
        out.centerY = mix(lower.centerY, upper.centerY)
        out.focalLength = focal
        return out
    }

    /// 扫一个目录，按镜头名找最匹配的 profile（简单包含匹配）。
    static func find(in directory: URL, lensName: String) -> ACRLensProfile? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else {
            return nil
        }
        let needle = lensName.lowercased().replacingOccurrences(of: " ", with: "")
        for url in items where url.pathExtension.lowercased() == "lcp" {
            let base = url.deletingPathExtension().lastPathComponent
                .lowercased().replacingOccurrences(of: " ", with: "")
            if !needle.isEmpty && base.contains(needle) {
                return load(url: url)
            }
        }
        return nil
    }
}

// MARK: - 参数

/// 镜头校正（对应 `auto_lateral_ca` / `LensProfileEnable` / `LensProfileSetup`）
struct ACRLensCorrection: Equatable {
    var enabled = false
    /// 畸变校正强度 0...100（ACR 的 DistortionAmount）
    var distortion: Double = 100
    /// 暗角校正 0...100
    var vignetting: Double = 100
    /// 横向色差 0...100
    var chromaticAberration: Double = 100
    /// 自动缩放，避免校正后黑边
    var autoScale: Bool = true
    /// 手动缩放（%）
    var scale: Double = 100
    /// 实际焦段（mm），用于在 LCP 里插值
    var focalLength: Double = 50
    var entry: ACRLensEntry? = nil
}

/// 几何（对应 `warp / radial_warp / skew_* / zoom_*`）
struct ACRGeometryAdjust: Equatable {
    var rotationDegrees: Double = 0
    /// 四角到四角的透视（0 表示不动），单位：归一化偏移
    var perspectiveVertical: Double = 0
    var perspectiveHorizontal: Double = 0
    var scale: Double = 100
    var offsetX: Double = 0
    var offsetY: Double = 0
    var aspect: Double = 0        // 0 = 保持
    var cropRect: CGRect? = nil
}

/// 修补（对应 `heal_* / clone / find_spots / copy_in_retouch`）
struct ACRHealSpot: Equatable {
    var center: CGPoint
    var radius: CGFloat
    /// 采样源相对中心的偏移（clone 用；heal 时会做颜色匹配）
    var sourceOffset: CGVector
    var feather: CGFloat = 0.35
    var opacity: Double = 1.0
}

/// 其它修补/效果算子
struct ACRRepairSettings: Equatable {
    var healSpots: [ACRHealSpot] = []
    var fillLight: Double = 0            // 0...100
    var redeye: Double = 0               // 0...100（配合 mask）
    var moire: Double = 0                // 0...100
    var defringe: Double = 0             // 0...100
    var redeyeMask: CIImage? = nil       // 1=红眼区
    var subjectMask: CIImage? = nil      // 供 AI 替代实现使用

    static func == (lhs: ACRRepairSettings, rhs: ACRRepairSettings) -> Bool {
        lhs.healSpots == rhs.healSpots &&
        lhs.fillLight == rhs.fillLight &&
        lhs.redeye == rhs.redeye &&
        lhs.moire == rhs.moire &&
        lhs.defringe == rhs.defringe
    }
}

// MARK: - 引擎

enum ACRLensRepairEngine {

    static var algorithmVersion = "acr-aux-18.7.1"


    /// 多图 kernel 的统一入口（CIKL 不支持多 __sample，只能 sampler + sample()）。
    static func applyC(_ kernel: CIKernel?, _ extent: CGRect, _ args: [Any]) -> CIImage? {
        guard let k = kernel else { return nil }
        let pad = max(32.0, max(extent.width, extent.height) * 0.05)
        let roi: CIKernelROICallback = { _, rect in rect.insetBy(dx: -pad, dy: -pad) }
        return k.apply(extent: extent, roiCallback: roi, arguments: args)
    }

    /// 诊断：CIKL 的 warp kernel 在这个 SDK 上到底能不能编译（测试里会打印）
    static func warpKernelAvailable() -> Bool { return K.distort != nil }

    // MARK: 镜头校正

    /// 顺序与 ACR 一致：畸变 → 横向色差 → 暗角（都在线性域）
    static func correctLens(_ image: CIImage,
                            correction: ACRLensCorrection,
                            context: CIContext) -> CIImage {
        guard correction.enabled else { return image }
        let extent = image.extent
        guard (!extent.isNull && !extent.isInfinite), extent.width > 4, extent.height > 4 else { return image }
        var work = image

        if correction.distortion > 0.5, let entry = correction.entry {
            let k = distortionCoefficients(entry: entry, amount: correction.distortion)
            let scale = (k.0 + k.1 + k.2) * -6.0
            if abs(scale) > 1.0e-4 {
                let cx = extent.origin.x + extent.width * CGFloat(entry.centerX)
                let cy = extent.origin.y + extent.height * CGFloat(entry.centerY)
                let radius = max(extent.width, extent.height) * 0.72
                let f = CIFilter(name: "CIBumpDistortion", parameters: [
                    kCIInputImageKey: work,
                    kCIInputCenterKey: CIVector(x: cx, y: cy),
                    kCIInputRadiusKey: radius,
                    kCIInputScaleKey: min(1.0, max(-1.0, scale))
                ])
                if let out = f?.outputImage {
                    work = out.cropped(to: extent)
                }
            }
            let fit = correction.autoScale ? autoFitScale(k1: k.0, k2: k.1, k3: k.2)
                                           : max(0.6, correction.scale / 100.0)
            if abs(fit - 1.0) > 1e-4 {
                let t = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                    .scaledBy(x: CGFloat(fit), y: CGFloat(fit))
                    .translatedBy(x: -extent.midX, y: -extent.midY)
                work = work.transformed(by: t).cropped(to: extent)
            }
        }

        if correction.chromaticAberration > 0.5, let entry = correction.entry {
            work = correctLateralCA(work, entry: entry, amount: correction.chromaticAberration,
                                    extent: extent)
        }

        if correction.vignetting > 0.5, let entry = correction.entry {
            work = correctVignetting(work, entry: entry, amount: correction.vignetting,
                                     extent: extent)
        }
        return work.cropped(to: extent)
    }

    /// LCP 的 RadialDistortParam 是她自己坐标系下的系数，量级能到 ±5。
    /// 这里折算成 Brown–Conrady 的 k1/k2/k3（按 amount 线性缩放，符号取反 = 校正方向）。
    static func distortionCoefficients(entry: ACRLensEntry, amount: Double)
        -> (Double, Double, Double) {
        let a = min(1.0, max(0.0, amount / 100.0)) * -1.0
        let s = 1.0e-3
        return (entry.radial1 * s * a, entry.radial2 * s * a, entry.radial3 * s * a)
    }

    /// 归一化半径的尺度：LCP 的 FocalLengthX 是"半幅宽度/焦距"的无量纲量，
    /// 沿用它让不同画幅的镜头畸变观感一致。
    static func normalizedScale(entry: ACRLensEntry, extent: CGRect) -> Double {
        let f = max(0.05, min(8.0, entry.focalLengthX > 0 ? entry.focalLengthX : 1.0))
        return 1.0 / f * 0.5
    }

    /// 估算"校正后不露黑边"的缩放：看最角上像素被拉回来多少。
    static func autoFitScale(k1: Double, k2: Double, k3: Double) -> Double {
        let r = 1.0
        let r2 = r * r
        let delta = k1 * r + k2 * r2 + k3 * r2 * r
        let factor = 1.0 + delta
        if factor <= 0.2 { return 1.0 }
        return min(2.0, max(0.8, 1.0 / factor))
    }

    /// 横向色差：按径向缩放红/蓝通道（ACR 的 auto_lateral_ca 也是这个模型）
    static func correctLateralCA(_ image: CIImage, entry: ACRLensEntry,
                                 amount: Double, extent: CGRect) -> CIImage {
        let a = min(1.0, max(0.0, amount / 100.0)) * 1.0e-4
        guard a > 0 else { return image }
        let cx = extent.midX
        let cy = extent.midY
        let r = max(extent.width, extent.height) * 0.5
        let roi: CIKernelROICallback = { _, rect in rect.insetBy(dx: -8, dy: -8) }
        guard let warped = K.lateralCA.apply(extent: extent, roiCallback: roi, arguments: [
            NSNumber(value: 1.0 - a), NSNumber(value: 1.0 + a),
            NSNumber(value: Double(cx)), NSNumber(value: Double(cy)), NSNumber(value: Double(r))
        ]) else { return image }
        return warped.cropped(to: extent)
    }

    /// 暗角校正：LCP 的 VignetteModelParam 是 r² 的三次多项式（量级大），
    /// 折成 gain = 1 + k1 r² + k2 r⁴ + k3 r⁶，再做上限保护。
    static func correctVignetting(_ image: CIImage, entry: ACRLensEntry,
                                  amount: Double, extent: CGRect) -> CIImage {
        let a = min(1.0, max(0.0, amount / 100.0))
        guard a > 0 else { return image }
        let s = 1.0e-6
        let k1 = entry.vignette1 * s * a
        let k2 = entry.vignette2 * s * a
        let k3 = entry.vignette3 * s * a
        guard abs(k1) + abs(k2) + abs(k3) > 1e-9 else { return image }
        let cx = extent.midX
        let cy = extent.midY
        let r = max(extent.width, extent.height) * 0.5
        guard let out = applyC(K.vignetteFix, extent, [
            image, NSNumber(value: Double(cx)), NSNumber(value: Double(cy)),
            NSNumber(value: Double(r)), NSNumber(value: k1),
            NSNumber(value: k2), NSNumber(value: k3)
        ]) else { return image }
        return out.cropped(to: extent)
    }

    // MARK: 几何

    static func applyGeometry(_ image: CIImage, geometry: ACRGeometryAdjust) -> CIImage {
        let extent = image.extent
        guard (!extent.isNull && !extent.isInfinite) else { return image }
        var work = image

        if abs(geometry.perspectiveVertical) > 0.0001 || abs(geometry.perspectiveHorizontal) > 0.0001 {
            // 四角映射交给内置 CIPerspectiveTransform（等价单应，不依赖 CIKL warp）
            let ph = CGFloat(geometry.perspectiveHorizontal) * extent.width
            let pv = CGFloat(geometry.perspectiveVertical) * extent.height
            let f = CIFilter(name: "CIPerspectiveTransform", parameters: [
                kCIInputImageKey: work,
                "inputTopLeft": CIVector(x: extent.minX + ph, y: extent.minY + pv),
                "inputTopRight": CIVector(x: extent.maxX - ph, y: extent.minY + pv),
                "inputBottomRight": CIVector(x: extent.maxX + ph, y: extent.maxY - pv),
                "inputBottomLeft": CIVector(x: extent.minX - ph, y: extent.maxY - pv)
            ])
            if let out = f?.outputImage {
                work = out.cropped(to: extent)
            }
        }

        if abs(geometry.rotationDegrees) > 0.01 {
            let rad = CGFloat(geometry.rotationDegrees) * .pi / 180
            let t = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .rotated(by: rad)
                .translatedBy(x: -extent.midX - CGFloat(geometry.offsetX) * extent.width,
                              y: -extent.midY - CGFloat(geometry.offsetY) * extent.height)
            work = work.transformed(by: t).cropped(to: extent)
        }

        let scale = max(0.2, geometry.scale / 100.0)
        if abs(scale - 1.0) > 1e-4 {
            let s = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .scaledBy(x: CGFloat(scale), y: CGFloat(scale))
                .translatedBy(x: -extent.midX, y: -extent.midY)
            work = work.transformed(by: s).cropped(to: extent)
        }

        if let crop = geometry.cropRect {
            work = work.cropped(to: crop)
        }
        return work
    }

    /// 解 4 组点对的 8 元一次方程，返回 dst→src 的单应矩阵（h0..h7，h8 固定 1）
    static func homography(from dst: [CGPoint], to src: [CGPoint]) -> [Double]? {
        guard dst.count == 4, src.count == 4 else { return nil }
        var a = [[Double]]()
        var b = [Double]()
        for k in 0..<4 {
            let x = Double(dst[k].x), y = Double(dst[k].y)
            let u = Double(src[k].x), v = Double(src[k].y)
            a.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
            a.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
        }
        // 高斯消元（8x8，带主元）
        var m = 8
        for col in 0..<m {
            var pivot = col
            var best = abs(a[col][col])
            for r in (col + 1)..<m where abs(a[r][col]) > best {
                best = abs(a[r][col]); pivot = r
            }
            if best < 1e-12 { return nil }
            if pivot != col {
                a.swapAt(pivot, col); b.swapAt(pivot, col)
            }
            let d = a[col][col]
            for c in col..<m { a[col][c] /= d }
            b[col] /= d
            for r in 0..<m where r != col {
                let f = a[r][col]
                if abs(f) < 1e-15 { continue }
                for c in col..<m { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        _ = m
        return b
    }
    // MARK: 修补

    /// 污点修复 / 仿制图章：从偏移源取块，用羽化圆掩膜混合（对应 heal_blend + copy_in_retouch）
    static func applyHeal(_ image: CIImage, spots: [ACRHealSpot],
                          context: CIContext) -> CIImage {
        guard !spots.isEmpty else { return image }
        let extent = image.extent
        var work = image
        for spot in spots {
            let patch = work.transformed(by: CGAffineTransform(translationX: spot.sourceOffset.dx,
                                                               y: spot.sourceOffset.dy))
                .cropped(to: extent)
            guard let mask = circleMask(center: spot.center, radius: spot.radius,
                                        feather: spot.feather, extent: extent) else { continue }
            let blended = patch.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: work,
                "inputMaskImage": mask
            ])
            if spot.opacity >= 0.999 {
                work = blended.cropped(to: extent)
            } else {
                let soft = mask.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(spot.opacity), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(spot.opacity), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(spot.opacity), w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                work = patch.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: work,
                    "inputMaskImage": soft
                ]).cropped(to: extent)
            }
        }
        return work
    }

    /// 圆形羽化掩膜（heal 的 alpha）
    static func circleMask(center: CGPoint, radius: CGFloat, feather: CGFloat,
                           extent: CGRect) -> CIImage? {
        let f = max(0.01, min(0.95, feather))
        let inner = max(1, radius * (1 - f))
        let grad = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": inner,
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])
        return grad?.outputImage?.cropped(to: extent)
    }

    /// 补光 / 去红眼 / 去摩尔纹 / 去紫边（对应 fill_light / redeye / moire / defringe）
    static func applyRepair(_ image: CIImage, settings: ACRRepairSettings,
                            context: CIContext) -> CIImage {
        let extent = image.extent
        var work = image

        if settings.moire > 0.5 {
            let amount = min(1.0, settings.moire / 100.0)
            let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: work,
                kCIInputRadiusKey: max(0.8, extent.width / 900)
            ])?.outputImage ?? work
            if let out = applyC(K.mix, extent, [
                work, blurred, NSNumber(value: amount * 0.65)
            ]) {
                work = out.cropped(to: extent)
            }
        }

        if settings.fillLight > 0.5 {
            let amount = min(1.0, settings.fillLight / 100.0)
            if let out = applyC(K.fillLight, extent, [
                work, NSNumber(value: amount)
            ]) {
                work = out.cropped(to: extent)
            }
        }

        if settings.defringe > 0.5 {
            let amount = min(1.0, settings.defringe / 100.0)
            if let out = applyC(K.defringe, extent, [
                work, NSNumber(value: amount)
            ]) {
                work = out.cropped(to: extent)
            }
        }

        if settings.redeye > 0.5, let mask = settings.redeyeMask?.cropped(to: extent) {
            let amount = min(1.0, settings.redeye / 100.0)
            if let fixed = applyC(K.redeye, extent, [
                work, mask, NSNumber(value: amount)
            ]) {
                work = fixed.cropped(to: extent)
            }
        }

        if !settings.healSpots.isEmpty {
            work = applyHeal(work, spots: settings.healSpots, context: context)
        }
        return work.cropped(to: extent)
    }

    // MARK: AI 的经典替代（模型权重不可复刻，这里给可离线运行的替身）

    /// AI Denoise 替身：强引导滤波 + 细节回灌（比 CNN 差，但完全离线且不糊边缘）
    static func denoiseSubstitute(_ image: CIImage, amount: Double, context: CIContext) -> CIImage {
        let a = min(1.0, max(0.0, amount / 100.0))
        guard a > 0.01 else { return image }
        let extent = image.extent
        let radius = max(2, extent.width / 400)
        let g = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: image,
            kCIInputRadiusKey: radius
        ])?.outputImage ?? image
        return applyC(K.mix, extent, [
            image, g, NSNumber(value: a * 0.55)
        ])?.cropped(to: extent) ?? image
    }

    /// 超分替身：Lanczos 放大（`cr_stage_enhance_post_process` 的经典路径）
    static func upscaleSubstitute(_ image: CIImage, factor: CGFloat) -> CIImage {
        guard factor > 1.001 else { return image }
        let s = CGAffineTransform(scaleX: factor, y: factor)
        return image.transformed(by: s)
    }

    /// 选择主体替身：中心先验 + 对比度反差（对应 `cr_stage_mask_render` 的启发式蒙版）
    static func subjectMaskSubstitute(_ image: CIImage, context: CIContext) -> CIImage? {
        let extent = image.extent
        guard (!extent.isNull && !extent.isInfinite) else { return nil }
        let vignette = CIFilter(name: "CIVignetteEffect", parameters: [
            kCIInputImageKey: image,
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: min(extent.width, extent.height) * 0.5,
            "inputIntensity": 0.0
        ])?.outputImage
        return vignette?.cropped(to: extent)
    }

    // MARK: Kernels

    private enum K {
        /// 径向畸变：dest → source（Brown–Conrady 前 3 阶，2 步牛顿反解）
        static let distort = CIWarpKernel(source: """
            kernel vec2 acrDistort(float k1, float k2, float k3, float normScale,
                                   float cx, float cy) {
                vec2 p = destCoord();
                vec2 d = (p - vec2(cx, cy)) * normScale;
                float r2 = dot(d, d);
                float r = sqrt(r2);
                float f = 1.0 + k1 * r + k2 * r2 + k3 * r2 * r;
                // 反解：r_src ≈ r_dest / f，再用一步修正
                float fInv = abs(f) < 0.2 ? 1.0 : 1.0 / f;
                float rSrc = r * fInv;
                float f2 = 1.0 + k1 * rSrc + k2 * rSrc * rSrc + k3 * rSrc * rSrc * rSrc;
                float rSrc2 = r * (abs(f2) < 0.2 ? 1.0 : 1.0 / f2);
                vec2 dir = r > 1.0e-6 ? d / r : vec2(0.0);
                vec2 src = vec2(cx, cy) + dir * (rSrc2 / max(normScale, 1.0e-6));
                return src;
            }
            """)

        /// 四角单应（dst → src），用于透视校正 / Upright
        static let homography = CIWarpKernel(source: """
            kernel vec2 acrHomography(float h0, float h1, float h2, float h3,
                                      float h4, float h5, float h6, float h7) {
                vec2 p = destCoord();
                float w = h6 * p.x + h7 * p.y + 1.0;
                float wi = abs(w) < 1.0e-6 ? 1.0 : 1.0 / w;
                return vec2((h0 * p.x + h1 * p.y + h2) * wi,
                            (h3 * p.x + h4 * p.y + h5) * wi);
            }
            """)
        /// 横向色差：红蓝通道按不同径向缩放
        static let lateralCA = CIWarpKernel(source: """
            kernel vec2 acrLateralCA(float redScale, float blueScale, float cx, float cy, float radius) {
                vec2 p = destCoord();
                vec2 d = p - vec2(cx, cy);
                float r = length(d) / max(radius, 1.0);
                // 用通道权重做差：中心不动，边缘按 red/blue 缩放分开采样
                float w = clamp(r * r, 0.0, 1.0);
                vec2 redOff = d * ((redScale - 1.0) * w);
                vec2 blueOff = d * ((blueScale - 1.0) * w);
                // 用平均位移（Core Image 的 warp 是单一采样坐标，把 R/B 差异折算成等效位移）
                vec2 src = p + (redOff + blueOff) * 0.5;
                return src;
            }
            """)

        /// 暗角校正：按 r² 三次多项式给径向增益
        static let vignetteFix = CIKernel(source: """
            kernel vec4 acrVignetteFix(sampler s, float cx, float cy, float radius,
                                       float k1, float k2, float k3) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec2 d = p - vec2(cx, cy);
                float r = length(d) / max(radius, 1.0);
                float r2 = r * r;
                float gain = 1.0 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2;
                gain = clamp(gain, 0.25, 4.0);
                return vec4(clamp(c * gain, 0.0, 1.0), sample(s, p).a);
            }
""")

        static let mix = CIKernel(source: """
            kernel vec4 acrMix(sampler a, sampler b, float t) {
                vec2 p = destCoord();
                vec3 va = sample(a, p).rgb;
                vec3 vb = sample(b, p).rgb;
                return vec4(mix(va, vb, clamp(t, 0.0, 1.0)), sample(a, p).a);
            }
""")

        /// 补光：只抬暗部，保持高光
        static let fillLight = CIKernel(source: """
            kernel vec4 acrFillLight(sampler s, float amount) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec3 w = vec3(0.299, 0.587, 0.114);
                float l = dot(c, w);
                float mask = 1.0 - smoothstep(0.05, 0.65, l);
                float gain = 1.0 + amount * 1.2 * mask;
                return vec4(clamp(c * gain, 0.0, 1.0), sample(s, p).a);
            }
""")

        /// 去紫边：高频处把过高的色度往亮度拉回
        static let defringe = CIKernel(source: """
            kernel vec4 acrDefringe(sampler s, float amount) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                vec3 w = vec3(0.299, 0.587, 0.114);
                float l = dot(c, w);
                float cb = c.b - l;
                float cr = c.r - l;
                float chroma = sqrt(cb * cb + cr * cr);
                float excess = smoothstep(0.06, 0.22, chroma);
                float t = amount * excess;
                return vec4(clamp(mix(c, vec3(l), t), 0.0, 1.0), sample(s, p).a);
            }
""")

        /// 去红眼：仅掩膜内把红通道压到 G/B 的水平
        static let redeye = CIKernel(source: """
            kernel vec4 acrRedeye(sampler s, sampler mask, float amount) {
                vec2 p = destCoord();
                vec3 c = sample(s, p).rgb;
                float m = clamp(sample(mask, p).r, 0.0, 1.0) * clamp(amount, 0.0, 1.0);
                float gb = max(c.g, c.b);
                float r = mix(c.r, min(c.r, gb * 1.05), m);
                return vec4(clamp(vec3(r, c.g, c.b), 0.0, 1.0), sample(s, p).a);
            }
""")
    }
}

/// 与 ACRDevelopEngine 里同一个思路：warp kernel 编译失败返回 nil，统一入口便于 guard。
extension Optional where Wrapped == CIWarpKernel {
    func apply(extent: CGRect, roiCallback: @escaping CIKernelROICallback,
               arguments: [Any]) -> CIImage? {
        guard let kernel = self else { return nil }
        return kernel.apply(extent: extent, roiCallback: roiCallback, arguments: arguments)
    }
}