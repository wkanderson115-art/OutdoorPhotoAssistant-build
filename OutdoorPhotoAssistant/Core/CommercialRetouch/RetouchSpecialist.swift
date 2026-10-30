import Foundation
import UIKit
import CoreImage
import Vision

/// Category-specific conservative parameters, not a learned blemish removal model.
enum RetouchSpecialist {
    struct Profile { let sharpen: Double; let noise: Double }
    static func profile(for preset: RetouchPreset) -> Profile {
        switch preset.category {
        case "人像摄影", "婚纱与情侣", "家庭与儿童", "时尚与穿搭": return Profile(sharpen: 0.15, noise: 0.035)
        case "宠物与野生动物", "微距与植物": return Profile(sharpen: 0.48, noise: 0.025)
        case "星空与天文": return Profile(sharpen: 0.12, noise: 0.075)
        case "建筑与室内", "商品摄影", "文档与翻拍": return Profile(sharpen: 0.42, noise: 0.015)
        default: return Profile(sharpen: 0.28, noise: 0.025)
        }
    }
    /// Conservative, deterministic per-scene finishing. No generative pixels or face geometry edits.
    static func finish(_ image: CIImage, preset: RetouchPreset) -> CIImage {
        let profile = profile(for: preset)
        let isPortrait = ["人像摄影", "婚纱与情侣", "家庭与儿童", "时尚与穿搭"].contains(preset.category)
        let isDocument = preset.category == "文档与翻拍"
        let isNight = ["星空与天文", "演出与活动"].contains(preset.category) || preset.name.contains("夜景")
        let isAnimal = preset.category == "宠物与野生动物"
        let isProduct = ["商品摄影", "汽车与机车"].contains(preset.category)
        let noise = CIFilter.noiseReduction()
        noise.inputImage = image
        noise.noiseLevel = Float(isNight ? 0.065 : (isPortrait ? 0.025 : profile.noise))
        noise.sharpness = Float(isPortrait ? 0.22 : 0.3)
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = noise.outputImage
        sharpen.sharpness = Float(isPortrait ? 0.12 : (isAnimal ? 0.36 : (isDocument ? 0.38 : profile.sharpen)))
        // Only restore detail around genuine luminance transitions. Smooth skin and sky
        // retain the denoised base instead of receiving global sharpening halos.
        let detail = selectiveDetail(base: noise.outputImage ?? image,
                                     sharpened: sharpen.outputImage ?? image,
                                     strength: isPortrait ? 0.34 : (isAnimal ? 0.72 : (isNight ? 0.28 : 0.62)))
        let controls = CIFilter.colorControls()
        controls.inputImage = detail
        // Preserve product colors and skin tones; do not apply creative saturation to documents.
        controls.saturation = Float(isDocument ? 1.0 : (isPortrait ? min(preset.parameters.saturation, 1.035) : (isProduct ? min(preset.parameters.saturation, 1.02) : preset.parameters.saturation)))
        controls.contrast = Float(isPortrait ? min(preset.parameters.contrast, 1.06) : preset.parameters.contrast)
        return (controls.outputImage ?? image).cropped(to: image.extent)
    }

    /// Edge-guided, non-generative detail enhancement. The mask comes from the
    /// denoised luminance image, never from an AI-generated replacement.
    /// This intentionally does not claim to reconstruct missing fur or skin texture.
    static func selectiveDetail(base: CIImage, sharpened: CIImage, strength: CGFloat) -> CIImage {
        let extent = base.extent
        guard extent.width > 0, extent.height > 0, strength > 0 else { return base }
        let edges = CIFilter.edges()
        edges.inputImage = base
        edges.intensity = 1.0
        guard let edgeImage = edges.outputImage else { return base }
        let grayscale = CIFilter.colorControls()
        grayscale.inputImage = edgeImage
        grayscale.saturation = 0
        grayscale.contrast = 1.45
        let opacity = CIFilter.colorMatrix()
        opacity.inputImage = grayscale.outputImage
        // Limit local contrast reinforcement even for strong edges.
        let gain = min(max(strength, 0), 0.8)
        opacity.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        opacity.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        opacity.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        // The mask must be opaque: blendWithMask reads luminance, not the source alpha.
        opacity.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        opacity.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = sharpened
        blend.backgroundImage = base
        blend.maskImage = opacity.outputImage
        return (blend.outputImage ?? base).cropped(to: extent)
    }

    /// Retain near-clipped highlights from the input; no hallucinated highlight recovery.
    static func preserveHighlights(original: CIImage, processed: CIImage) -> CIImage {
        let mono = CIFilter.colorControls()
        mono.inputImage = original
        mono.saturation = 0
        let polynomial = CIFilter.colorPolynomial()
        polynomial.inputImage = mono.outputImage
        // Luminance cubed: suppress influence in midtones, emphasize very bright pixels.
        polynomial.redCoefficients = CIVector(x: 0, y: 0, z: 0, w: 1)
        polynomial.greenCoefficients = CIVector(x: 0, y: 0, z: 0, w: 1)
        polynomial.blueCoefficients = CIVector(x: 0, y: 0, z: 0, w: 1)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = original
        blend.backgroundImage = processed
        blend.maskImage = polynomial.outputImage
        return (blend.outputImage ?? processed).cropped(to: original.extent)
    }

    /// Low-strength, face-local noise reduction. Landmark regions stay on the untouched path.
    static func protectPortraitDetail(_ image: CIImage, source: CGImage, category: String) -> CIImage {
        guard ["人像摄影", "婚纱与情侣", "家庭与儿童", "时尚与穿搭"].contains(category) else { return image }
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: source).perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return image }
        let width = image.extent.width, height = image.extent.height
        let extent = image.extent
        var mask = CIImage(color: .black).cropped(to: extent)
        for face in faces {
            guard face.confidence >= 0.65, face.landmarks != nil else { continue }
            let box = CGRect(x: extent.minX + face.boundingBox.minX * width,
                             y: extent.minY + face.boundingBox.minY * height,
                             width: face.boundingBox.width * width,
                             height: face.boundingBox.height * height)
            let inset = box.insetBy(dx: box.width * 0.14, dy: box.height * 0.12)
            let field = CIFilter.radialGradient()
            field.center = CGPoint(x: inset.midX, y: inset.midY)
            field.radius0 = Float(min(inset.width, inset.height) * 0.25)
            field.radius1 = Float(min(inset.width, inset.height) * 0.48)
            field.color0 = CIColor(red: 0.17, green: 0.17, blue: 0.17, alpha: 1)
            field.color1 = .black
            guard let spot = field.outputImage?.cropped(to: inset) else { continue }
            mask = spot.composited(over: mask)
            // Exclude every detected facial feature, with a margin for detection error.
            let features = [face.landmarks?.leftEye, face.landmarks?.rightEye,
                            face.landmarks?.leftEyebrow, face.landmarks?.rightEyebrow,
                            face.landmarks?.nose, face.landmarks?.noseCrest,
                            face.landmarks?.outerLips, face.landmarks?.innerLips]
            for feature in features.compactMap({ $0 }) {
                let points = feature.normalizedPoints
                guard !points.isEmpty else { continue }
                let xs = points.map { box.minX + CGFloat($0.x) * box.width }
                let ys = points.map { box.minY + CGFloat($0.y) * box.height }
                let region = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    .insetBy(dx: -box.width * 0.055, dy: -box.height * 0.045).intersection(extent)
                guard !region.isNull, region.width > 0, region.height > 0 else { continue }
                // Compositing opaque black over the mask removes the protected feature.
                // Use a softly feathered cutout to avoid visible retouch boundaries.
                let center = CGPoint(x: region.midX, y: region.midY)
                let gradient = CIFilter.radialGradient()
                gradient.center = center
                gradient.radius0 = Float(max(region.width, region.height) * 0.38)
                gradient.radius1 = Float(max(region.width, region.height) * 0.70)
                gradient.color0 = .white
                gradient.color1 = .black
                let cutout = CIFilter.blendWithMask()
                cutout.inputImage = CIImage(color: .black).cropped(to: extent)
                cutout.backgroundImage = mask
                cutout.maskImage = gradient.outputImage?.cropped(to: extent)
                mask = (cutout.outputImage ?? mask).cropped(to: extent)
            }
        }
        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = image
        denoise.noiseLevel = 0.035
        denoise.sharpness = 0.35
        let blend = CIFilter.blendWithMask()
        blend.inputImage = denoise.outputImage
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }
    /// Apple Vision person mask: protects the entire person while denoising the
    /// background. If segmentation fails, the unmodified image is returned.
    /// The Vision mask is low-resolution and is scaled in Core Image, not on CPU.
    static func protectPersonFromBackgroundNoise(_ image: CIImage, source: CGImage) -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
            guard let observation = request.results?.first else { return image }
            let buffer = observation.pixelBuffer
            let rawMask = CIImage(cvPixelBuffer: buffer)
            let maskExtent = rawMask.extent
            guard maskExtent.width > 0, maskExtent.height > 0 else { return image }
            let scaled = rawMask.transformed(by: CGAffineTransform(scaleX: image.extent.width / maskExtent.width,
                                                                    y: image.extent.height / maskExtent.height))
                .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            let feather = CIFilter.gaussianBlur()
            feather.inputImage = scaled.clampedToExtent()
            feather.radius = 3
            let denoise = CIFilter.noiseReduction()
            denoise.inputImage = image
            denoise.noiseLevel = 0.035
            denoise.sharpness = 0.30
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image // Person stays on the original local-retouch path.
            blend.backgroundImage = denoise.outputImage
            blend.maskImage = feather.outputImage?.cropped(to: image.extent)
            return (blend.outputImage ?? image).cropped(to: image.extent)
        } catch { return image }
    }

    /// Vision foreground instance mask for animals/objects (iOS 17+). A failed
    /// segmentation never substitutes a synthetic subject or changes the original.
    static func protectForegroundDetail(_ image: CIImage, source: CGImage) -> CIImage {
        guard #available(iOS 17.0, *) else { return image }
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return image }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances,
                                                                 from: VNImageRequestHandler(cgImage: source, options: [:]))
            let mask = CIImage(cvPixelBuffer: buffer)
            let transform = CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY)
                .scaledBy(x: image.extent.width / mask.extent.width, y: image.extent.height / mask.extent.height)
            let aligned = mask.transformed(by: transform).cropped(to: image.extent)
            let feather = CIFilter.gaussianBlur()
            feather.inputImage = aligned.clampedToExtent()
            feather.radius = 2.0
            let background = CIFilter.noiseReduction()
            background.inputImage = image
            background.noiseLevel = 0.035
            background.sharpness = 0.20
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image
            blend.backgroundImage = background.outputImage
            blend.maskImage = feather.outputImage?.cropped(to: image.extent)
            return (blend.outputImage ?? image).cropped(to: image.extent)
        } catch { return image }
    }

    /// Keep the subject image at full resolution; downsample only the raster used
    /// by Vision. The full-resolution Core Image processing stays GPU-backed.
    static func visionProxy(_ input: CIImage, context: CIContext, maximumEdge: CGFloat = 1600) -> CGImage? {
        let edge = max(input.extent.width, input.extent.height)
        guard edge > 0 else { return nil }
        let scale = min(1, maximumEdge / edge)
        let proxy = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(proxy, from: proxy.extent)
    }

    static func exifOrientation(_ orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up: return 1
        case .down: return 3
        case .left: return 8
        case .right: return 6
        case .upMirrored: return 2
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .rightMirrored: return 7
        @unknown default: return 1
        }
    }
}
