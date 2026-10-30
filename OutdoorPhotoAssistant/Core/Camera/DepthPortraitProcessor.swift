import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// 把 Portrait Effects Matte 转成景深人像（背景虚化、人物保留）和可拖拽视差用的遮罩。
/// 关键修正：底图与遮罩必须在同一个"正立坐标系"里再对齐，否则 3:4 照片会明显错位。
enum DepthPortraitProcessor {
    static func makePortrait(image: UIImage, matte: AVPortraitEffectsMatte) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let exif = PhotoPostProcessor.exifOrientation(image.imageOrientation)
        let base = CIImage(cgImage: cg).oriented(exif)
        let mask = fitExact(CIImage(cvPixelBuffer: matte.mattingImage).oriented(exif), to: base.extent)

        guard let outCG = ImagePipeline.context.createCGImage(mask, from: base.extent) else { return nil }
        return apply(image: image, mask: UIImage(cgImage: outCG), strength: 0.18)
    }

    /// A conservative matte-based effect, not a metric depth reconstruction.
    /// No geometry scaling or displacement; foreground and background share one extent.
    static func apply(image: UIImage, mask: UIImage?, strength: Double) -> UIImage? {
        guard strength > 0.001, let mask, let cg = image.cgImage, let maskCG = mask.cgImage else { return image }
        let base = CIImage(cgImage: cg).oriented(PhotoPostProcessor.exifOrientation(image.imageOrientation))
        let extent = base.extent
        let fitted = fitExact(CIImage(cgImage: maskCG), to: extent)
        // Protect fine foreground edges and avoid dark/transparent borders.
        let protectedMask = fitted.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": max(1, extent.width * 0.0005)])
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(0.5, extent.width * 0.00025)]).cropped(to: extent)
        let radius = min(12, extent.width * 0.003) * min(1, max(0, strength))
        let blurred = base.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: extent)
        let output = base.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: protectedMask]).cropped(to: extent)
        guard let out = ImagePipeline.context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: out, scale: 1, orientation: .up)
    }

    static func makePortraitMask(image: UIImage, matte: AVPortraitEffectsMatte) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let exif = PhotoPostProcessor.exifOrientation(image.imageOrientation)
        let base = CIImage(cgImage: cg).oriented(exif)
        let mask = fitExact(CIImage(cvPixelBuffer: matte.mattingImage).oriented(exif), to: base.extent)
        guard let outCG = ImagePipeline.context.createCGImage(mask, from: base.extent) else { return nil }
        return UIImage(cgImage: outCG, scale: 1, orientation: .up)
    }

    private static func fitExact(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        return image
            .transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width,
                                               y: extent.height / image.extent.height))
            .cropped(to: extent)
    }
}
