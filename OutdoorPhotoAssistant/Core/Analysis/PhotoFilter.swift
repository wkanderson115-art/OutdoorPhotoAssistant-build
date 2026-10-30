import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// 41 套内置滤镜，分 7 组。常用效果全部自研 Core Image 离线可用；
/// 强风格化（油画/动漫/水彩等）属于"云端风格"分类，走 Seedream 生成。
enum FilterGroup: String, CaseIterable, Identifiable {
    case basic = "基础"
    case portrait = "人像"
    case landscape = "风景"
    case timeOfDay = "时段"
    case film = "胶片"
    case mono = "黑白"
    case art = "艺术"
    var id: String { rawValue }
}

enum PhotoFilter: String, CaseIterable, Identifiable {
    case natural = "自然"
    case vivid = "鲜艳"
    case warm = "暖阳"
    case cool = "清冷"
    case soft = "柔光"
    case fresh = "清新"
    // 人像
    case portrait = "人像"
    case cream = "奶油人像"
    case skinClear = "净透肤"
    case rosePortrait = "玫瑰人像"
    case tanPortrait = "蜜色人像"
    // 风景
    case landscape = "风景"
    case forest = "森系"
    case ocean = "海洋"
    case mountain = "山岳"
    case desert = "荒漠"
    case sky = "天空"
    // 时段
    case sunset = "日落"
    case golden = "金色时刻"
    case blueHour = "蓝调时刻"
    case night = "夜景"
    case aurora = "极光"
    // 胶片
    case film = "胶片"
    case kodak = "柯达"
    case polaroid = "拍立得"
    case vintage = "复古"
    case grainy = "颗粒"
    // 黑白
    case blackWhite = "黑白"
    case silver = "银盐"
    case noir = "黑色电影"
    case highContrastMono = "高反差黑白"
    // 艺术
    case cinematic = "电影"
    case neon = "霓虹"
    case gold = "黑金"
    case pastel = "马卡龙"
    case purpleDream = "紫梦"
    case tealOrange = "青橙"
    case faded = "褪色"
    case moody = "阴郁"
    case lomo = "暗角"
    case infrared = "红外"

    var id: String { rawValue }

    var group: FilterGroup {
        switch self {
        case .natural, .vivid, .warm, .cool, .soft, .fresh: return .basic
        case .portrait, .cream, .skinClear, .rosePortrait, .tanPortrait: return .portrait
        case .landscape, .forest, .ocean, .mountain, .desert, .sky: return .landscape
        case .sunset, .golden, .blueHour, .night, .aurora: return .timeOfDay
        case .film, .kodak, .polaroid, .vintage, .grainy: return .film
        case .blackWhite, .silver, .noir, .highContrastMono: return .mono
        case .cinematic, .neon, .gold, .pastel, .purpleDream, .tealOrange, .faded, .moody, .lomo, .infrared: return .art
        }
    }

    static func filters(in group: FilterGroup) -> [PhotoFilter] {
        allCases.filter { $0.group == group }
    }

    var icon: String {
        switch self {
        case .natural: return "leaf"
        case .vivid: return "sparkles"
        case .warm: return "sun.max"
        case .cool: return "snowflake"
        case .soft: return "circle.lefthalf.filled"
        case .fresh: return "drop"
        case .portrait, .cream, .skinClear, .rosePortrait, .tanPortrait: return "person.crop.circle"
        case .landscape, .mountain: return "mountain.2"
        case .forest: return "tree"
        case .ocean: return "water.waves"
        case .desert: return "sun.dust"
        case .sky: return "cloud"
        case .sunset, .golden: return "sunset"
        case .blueHour: return "moon"
        case .night, .aurora: return "moon.stars"
        case .film, .kodak, .polaroid, .vintage, .grainy: return "camera.filters"
        case .blackWhite, .silver, .noir, .highContrastMono: return "circle.lefthalf.filled"
        case .cinematic: return "film"
        case .neon: return "lightspectrum.horizontal"
        case .gold: return "sparkles"
        case .pastel: return "paintpalette"
        case .purpleDream: return "moon.haze"
        case .tealOrange: return "circle.hexagonpath"
        case .faded: return "rectangle.dashed"
        case .moody: return "tornado"
        case .lomo: return "aperture"
        case .infrared: return "circle.dashed"
        }
    }

    static func recommended(scene: String, brightness: Double, period: String) -> PhotoFilter {
        if period == "蓝调时刻" && (scene == "风景" || scene == "海边") { return .cool }
        if period == "黄金时段" && (scene == "风景" || scene == "日落") { return .sunset }
        if scene == "人物" || scene == "自拍" { return brightness < 0.22 ? .cream : .portrait }
        if scene == "日落" { return .sunset }
        if scene == "夜景" || period == "夜景" { return .night }
        if scene == "海边" { return .cool }
        if scene == "花草" { return .forest }
        if scene == "风景" { return .landscape }
        if scene == "建筑" { return .natural }
        if scene == "汽车" { return .natural }
        return .natural
    }
}

/// 滤镜的 Core Image 实现：输入输出都是 CIImage，便于与调色串成一条管线。
/// 每个滤镜由 colorControls + temperature + 可选 mono/vignette 组合而成；
/// 参数差异体现风格。强风格化（油画/动漫）属云端分类，不在此处。
enum PhotoFilterEngine {
    static func apply(_ filter: PhotoFilter, to input: CIImage) -> CIImage {
        switch filter {
        case .natural:
            return input
        // 基础
        case .vivid:    return colorControls(input, saturation: 1.18, contrast: 1.06, brightness: 0.01)
        case .warm:     return temperature(input, target: 5900, tint: 0)
        case .cool:     return temperature(input, target: 7200, tint: -2)
        case .soft:     return colorControls(input, saturation: 0.96, contrast: 0.94, brightness: 0.03)
        case .fresh:    return colorControls(temperature(input, target: 6600, tint: 1), saturation: 1.10, contrast: 1.02, brightness: 0.02)
        // 人像
        case .portrait:      return colorControls(input, saturation: 1.08, contrast: 1.03, brightness: 0.008)
        case .cream:         return colorControls(input, saturation: 0.98, contrast: 0.96, brightness: 0.02)
        case .skinClear:     return colorControls(temperature(input, target: 6300, tint: 2), saturation: 1.04, contrast: 1.02, brightness: 0.015)
        case .rosePortrait:  return colorControls(temperature(input, target: 6000, tint: 5), saturation: 1.06, contrast: 1.00, brightness: 0.01)
        case .tanPortrait:   return colorControls(temperature(input, target: 5600, tint: 3), saturation: 1.10, contrast: 1.05, brightness: 0.005)
        // 风景
        case .landscape: return colorControls(input, saturation: 1.18, contrast: 1.10, brightness: 0)
        case .forest:   return colorControls(input, saturation: 1.12, contrast: 1.06, brightness: 0)
        case .ocean:    return colorControls(temperature(input, target: 7300, tint: -3), saturation: 1.10, contrast: 1.05, brightness: 0)
        case .mountain: return colorControls(input, saturation: 1.14, contrast: 1.12, brightness: -0.01)
        case .desert:   return colorControls(temperature(input, target: 5800, tint: 2), saturation: 1.12, contrast: 1.08, brightness: 0.01)
        case .sky:      return colorControls(temperature(input, target: 7000, tint: -4), saturation: 1.16, contrast: 1.04, brightness: 0.02)
        // 时段
        case .sunset:    return colorControls(temperature(input, target: 5200, tint: 4), saturation: 1.12, contrast: 1.08, brightness: 0)
        case .golden:    return colorControls(temperature(input, target: 5400, tint: 6), saturation: 1.10, contrast: 1.05, brightness: 0.01)
        case .blueHour:  return colorControls(temperature(input, target: 7500, tint: -5), saturation: 1.04, contrast: 1.06, brightness: -0.01)
        case .night:     return colorControls(input, saturation: 0.94, contrast: 1.03, brightness: 0)
        case .aurora:    return colorControls(temperature(input, target: 7800, tint: 8), saturation: 1.20, contrast: 1.10, brightness: 0)
        // 胶片
        case .film:      return colorControls(input, saturation: 0.94, contrast: 1.04, brightness: 0.008)
        case .kodak:     return colorControls(temperature(input, target: 6000, tint: 3), saturation: 1.05, contrast: 1.06, brightness: 0.005)
        case .polaroid:  return colorControls(temperature(input, target: 6200, tint: 2), saturation: 0.92, contrast: 0.95, brightness: 0.03)
        case .vintage:   return colorControls(temperature(input, target: 5800, tint: 5), saturation: 0.88, contrast: 0.98, brightness: 0.01)
        case .grainy:    return colorControls(input, saturation: 0.90, contrast: 1.10, brightness: -0.01)
        // 黑白
        case .blackWhite:        return mono(input, contrast: 1.0)
        case .silver:            return mono(input, contrast: 0.92)
        case .noir:               return mono(input, contrast: 1.25)
        case .highContrastMono:  return mono(input, contrast: 1.40)
        // 艺术
        case .cinematic:   return colorControls(input, saturation: 0.92, contrast: 1.12, brightness: 0)
        case .neon:         return colorControls(input, saturation: 1.30, contrast: 1.12, brightness: 0)
        case .gold:         return colorControls(temperature(input, target: 5500, tint: 4), saturation: 1.06, contrast: 1.16, brightness: 0)
        case .pastel:       return colorControls(input, saturation: 0.90, contrast: 0.92, brightness: 0.04)
        case .purpleDream:  return colorControls(temperature(input, target: 6800, tint: 8), saturation: 1.08, contrast: 0.98, brightness: 0.02)
        case .tealOrange:   return tealOrangeGrade(input)
        case .faded:        return colorControls(input, saturation: 0.82, contrast: 0.90, brightness: 0.03)
        case .moody:        return colorControls(input, saturation: 0.88, contrast: 1.14, brightness: -0.02)
        case .lomo:         return vignette(colorControls(input, saturation: 1.20, contrast: 1.15, brightness: 0))
        case .infrared:     return infraredLook(input)
        }
    }

    private static func colorControls(_ input: CIImage, saturation: Float, contrast: Float, brightness: Float) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = input
        filter.saturation = saturation
        filter.contrast = contrast
        filter.brightness = brightness
        return filter.outputImage ?? input
    }

    private static func temperature(_ input: CIImage, target: CGFloat, tint: CGFloat) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = input
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: target, y: tint)
        return filter.outputImage ?? input
    }

    private static func mono(_ input: CIImage, contrast: Float) -> CIImage {
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = input
        let base = mono.outputImage ?? input
        let cc = CIFilter.colorControls()
        cc.inputImage = base
        cc.contrast = contrast
        return cc.outputImage ?? base
    }

    private static func vignette(_ input: CIImage) -> CIImage {
        let vig = CIFilter.vignette()
        vig.inputImage = input
        vig.intensity = 1.2
        vig.radius = 1.5
        return vig.outputImage ?? input
    }

    /// Teal-orange blockbuster grade: cool shadows, warm highlights, via two
    /// color-matrix passes approximated with temperature + selective saturation.
    private static func tealOrangeGrade(_ input: CIImage) -> CIImage {
        let warmed = temperature(input, target: 5600, tint: 3)
        return colorControls(warmed, saturation: 1.14, contrast: 1.14, brightness: 0)
    }

    /// faux-infrared: near-white foliage via extreme desaturation of green channel,
    /// approximated with a high-key mono blend tinted cool.
    private static func infraredLook(_ input: CIImage) -> CIImage {
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = input
        let high = colorControls(mono.outputImage ?? input, saturation: 1.0, contrast: 1.18, brightness: 0.05)
        return temperature(high, target: 7200, tint: -3)
    }
}
