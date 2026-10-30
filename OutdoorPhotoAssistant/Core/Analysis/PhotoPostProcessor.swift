import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// 全 App 共享一个 CIContext：CIContext 是线程安全的昂贵对象，不要每张图新建（上一版每次都 new，代价很大）。
enum ImagePipeline {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
}

/// 一次成片的渲染参数：滤镜 + 调色 + 构图风格 + 可选美颜。
struct PhotoRenderOptions {
    var filter: PhotoFilter = .natural
    var grade: ColorGrade = ColorGrade()
    var style: String = "自然"
    var beauty: PortraitBeautySettings? = nil
    var outputAspect: Double = 0
    var filterStrength: Double = 0.55
    var backgroundBlur: Double = 0
    var directorContext: DirectorLearningContext? = nil
    var directorEvidence: [DirectorEvidence] = []
}

/// 统一的后处理入口：原片 → （美颜）→ 滤镜 → 调色 → 一次渲染。
/// 全部步骤都在 Core Image 里串成一条管线，只在最后 createCGImage 一次。
enum PhotoPostProcessor {
    static func render(original: UIImage, options: PhotoRenderOptions) -> UIImage? {
        var base = original
        if let beauty = options.beauty, let beautified = PortraitBeautyEngine.shared.process(original, settings: beauty) {
            base = beautified
        }
        guard let cg = base.cgImage else { return nil }

        var ci = CIImage(cgImage: cg).oriented(exifOrientation(base.imageOrientation))
        ci = applyColor(to: ci, options: options)
        ci = DirectorVision.backgroundBlur(ci, strength: options.backgroundBlur)
        guard let output = ImagePipeline.context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }

    static func applyColor(to input: CIImage, options: PhotoRenderOptions) -> CIImage {
        // 滤镜单独按 filterStrength 混合，调色/曲线全额生效不被稀释。
        let filtered = PhotoFilterEngine.apply(options.filter, to: input)
        let filterMix = CIFilter.dissolveTransition()
        filterMix.inputImage = input; filterMix.targetImage = filtered
        filterMix.time = Float(max(0, min(1, options.filterStrength)))
        let filteredResult = (filterMix.outputImage ?? input).cropped(to: input.extent)
        // grade/curve 全额生效
        let graded = ColorGradeEngine.apply(options.grade.applyingStyle(options.style), to: filteredResult)
        let result = graded.cropped(to: input.extent)
        guard options.outputAspect > 0 else { return result }
        let aspect = CGFloat(options.outputAspect)
        var rect = result.extent
        if rect.width / rect.height > aspect {
            let width = rect.height * aspect
            rect.origin.x += (rect.width - width) / 2; rect.size.width = width
        } else {
            let height = rect.width / aspect
            rect.origin.y += (rect.height - height) / 2; rect.size.height = height
        }
        return result.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// 保存用的 JPEG 数据（质量 0.95）。
    static func jpegData(_ image: UIImage, quality: CGFloat = 0.95) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    static func exifOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/// 单一"美颜度"总控：一个滑杆映射到完整美颜参数集，实时预览与拍后共用同一套预设。
struct BeautyPreset: Codable, Equatable {
    var intensity: Double = 0.16
    func settings(mode: PortraitBeautyMode) -> PortraitBeautySettings {
        var s = PortraitBeautySettings()
        s.mode = mode
        let i = intensity
        s.skin = mode == .commercialNatural ? min(0.14, i * 0.6) : min(0.30, i)
        s.skinWhiten = mode == .commercialNatural ? 0 : i * 0.6
        s.faceBrighten = i * 0.5
        s.eyeLift = i * 0.4
        s.environmentBlend = i
        s.faceSlim = mode == .commercialNatural ? 0 : i * 0.5
        s.clarity = 0.08
        return s
    }
}
