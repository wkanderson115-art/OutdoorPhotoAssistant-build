import CoreImage
import Foundation

// MARK: - LightroomLook → ACRDevelopSettings 桥接
//
// 单独一个文件：`ACRDevelopEngine.swift` 保持零依赖，测试脚本可以只编译引擎本体；
// 这个文件依赖 App 里的 `LightroomLook`，只进 App target。

extension LightroomLook {

    /// 把 App 现有的 `LightroomLook` 翻成完整的 ACR 参数。
    /// 没在 `LightroomLook` 里的新参数（颜色分级 4 轮、降噪、锐化细节/边缘掩膜、
    /// 颗粒频率、暗角中点/羽化/圆度、白平衡）走这里的默认值。
    var acrSettings: ACRDevelopSettings {
        var s = ACRDevelopSettings()
        s.exposure = exposure
        s.contrast = contrast
        s.highlights = highlights
        s.shadows = shadows
        s.whites = whites
        s.blacks = blacks
        s.clarity = clarity
        s.texture = texture
        s.dehaze = dehaze
        s.vibrance = vibrance
        s.saturation = saturation

        s.parametricShadows = parametricShadows
        s.parametricDarks = parametricDarks
        s.parametricLights = parametricLights
        s.parametricHighlights = parametricHighlights

        s.curve = toneCurve.map { ACRCurvePoint(x: $0.input / 255.0, y: $0.output / 255.0) }
        s.curveRed = curveRed.map { ACRCurvePoint(x: $0.input / 255.0, y: $0.output / 255.0) }
        s.curveGreen = curveGreen.map { ACRCurvePoint(x: $0.input / 255.0, y: $0.output / 255.0) }
        s.curveBlue = curveBlue.map { ACRCurvePoint(x: $0.input / 255.0, y: $0.output / 255.0) }

        s.hslHue = hslHue
        s.hslSaturation = hslSaturation
        s.hslLuminance = hslLuminance

        // 旧字段（分离色调）落进颜色分级的阴影/高光两轮
        s.gradeShadowHue = shadowHue
        s.gradeShadowSaturation = shadowSaturation
        s.gradeHighlightHue = highlightHue
        s.gradeHighlightSaturation = highlightSaturation
        s.gradeBalance = -splitBalance

        s.sharpness = sharpness
        s.sharpenRadius = sharpenRadius
        s.sharpenMasking = sharpenMasking
        s.grain = grain
        s.grainSize = grainSize
        s.vignette = vignette

        return s
    }

    /// 用完整的 ACR 引擎渲染。App 侧仍然调 `apply(to:skinMask:context:)`，
    /// 那个方法现在直接转到这条路径上。
    func applyWithACREngine(to image: CIImage,
                            skinMask: CIImage? = nil,
                            profile: ACRDCPProfile? = nil,
                            context: CIContext) -> CIImage {
        return ACRDevelopEngine.render(image,
                                       settings: acrSettings,
                                       skinMask: skinMask,
                                       profile: profile,
                                       context: context)
    }

    /// 加载同名 `.dcp` 相机配置文件（App 的 Documents/ACRProfiles 目录）。
    static func loadDCPProfile(named name: String, in directory: URL) -> ACRDCPProfile? {
        let url = directory.appendingPathComponent(name).appendingPathExtension("dcp")
        return ACRDCPProfile.load(url: url)
    }
}

// MARK: - LightroomLook 桥接（镜头/几何/修补走独立入口）

extension LightroomLook {

    /// 完整管线：Develop（ACR 引擎）→ 镜头校正 → 几何 → 修补
    func applyFull(to image: CIImage,
                   skinMask: CIImage? = nil,
                   profile: ACRDCPProfile? = nil,
                   lens: ACRLensCorrection = ACRLensCorrection(),
                   geometry: ACRGeometryAdjust = ACRGeometryAdjust(),
                   repair: ACRRepairSettings = ACRRepairSettings(),
                   context: CIContext) -> CIImage {
        let developed = ACRDevelopEngine.render(image,
                                                settings: acrSettings,
                                                skinMask: skinMask,
                                                profile: profile,
                                                context: context)
        let de = developed.extent
        guard !de.isNull, !de.isInfinite, de.width >= 1, de.height >= 1 else {
            return apply(to: image, skinMask: skinMask, context: context)
        }
        var work = developed
        work = ACRLensRepairEngine.correctLens(work, correction: lens, context: context)
        work = ACRLensRepairEngine.applyGeometry(work, geometry: geometry)
        work = ACRLensRepairEngine.applyRepair(work, settings: repair, context: context)
        let e = work.extent
        if e.isNull || e.isInfinite || e.width < 1 || e.height < 1 { return developed }
        return work
    }
}

