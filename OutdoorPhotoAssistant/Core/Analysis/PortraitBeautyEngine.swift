import Foundation
import AVFoundation
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// 精修强度模式。自然模式封顶保留真实纹理（不会塑料脸）；进阶模式放开上限到
/// 醒图级，由用户自负其美。上限表在 PortraitBeautyEngine.limits(for:) 里集中维护。
enum PortraitBeautyMode: String, CaseIterable, Equatable {
    case natural = "自然"
    case commercialNatural = "商业自然"
    case advanced = "进阶"
}

/// 每个参数都是 0...1 的归一化强度；引擎按当前模式的上限再 clamp。
/// 新增参数相对醒图的对应关系：
///   eyeEnlarge   大眼     eyeLift     眼神提亮
///   noseStraighten 挺鼻   faceSlim    瘦脸
///   lipEnhance   唇形     faceDepth   面部立体
///   skinWhiten   美白     skin        磨皮
///   faceBrighten 面部提亮 environmentBlend 人景融合
struct PortraitBeautySettings: Equatable {
    var mode: PortraitBeautyMode = .natural
    var skin: Double = 0.10
    var clarity: Double = 0.08
    var faceDepth: Double = 0
    var faceSlim: Double = 0
    var eyeLift: Double = 0.04
    var eyeEnlarge: Double = 0
    var noseStraighten: Double = 0
    var lipEnhance: Double = 0
    var skinWhiten: Double = 0
    var faceBrighten: Double = 0
    var environmentBlend: Double = 0.16
    var eyeshadow: Double = 0
    var eyeliner: Double = 0
    var doubleEyelid: Double = 0

    /// Snapshot of the "natural" defaults, used to reset in advanced mode too.
    static let naturalDefaults = PortraitBeautySettings()
}

/// 轻量、离线的人像优化。只有检测到人脸时才生效，否则返回 nil（调用方直接使用原图）。
final class PortraitBeautyEngine {
    static let shared = PortraitBeautyEngine()

    private let context = ImagePipeline.context

    /// Per-mode strength ceiling. `natural` keeps texture (no plastic skin);
    /// `advanced` opens up to Xingtu-grade, user takes responsibility.
    struct ModeLimits { let zero: Double; let ceiling: Double }
    static func limits(for mode: PortraitBeautyMode) -> ModeLimits {
        switch mode {
        case .natural, .commercialNatural: return ModeLimits(zero: 0, ceiling: 0.30)   // 磨皮≤0.30、瘦脸≤0.025 等
        case .advanced: return ModeLimits(zero: 0, ceiling: 1.0)     // 0-1 全开
        }
    }

    func process(_ image: UIImage, settings: PortraitBeautySettings = PortraitBeautySettings()) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let exif = PhotoPostProcessor.exifOrientation(image.imageOrientation)
        let ci = CIImage(cgImage: cg).oriented(exif)

        guard let result = processCI(ci, settings: settings),
              let out = context.createCGImage(result, from: ci.extent) else { return nil }
        return UIImage(cgImage: out, scale: 1, orientation: .up)
    }

    /// Same native pipeline for live preview and full-resolution stills.
    func processCI(_ ci: CIImage, settings: PortraitBeautySettings) -> CIImage? {
        processCI(ci, settings: settings, faces: nil)
    }

    /// Detect faces once and return the sorted observations. The live preview
    /// calls this at ~5Hz and feeds the result back into `processCI` for the
    /// intermediate frames, so a 15fps preview no longer runs VNDetect at
    /// 15 times per second.
    static func detectFaces(in ci: CIImage) -> [VNFaceObservation]? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: ci, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        return request.results?.sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }
    }

    /// `faces` lets the caller reuse a recent detection. Pass nil to detect.
    func processCI(_ ci: CIImage, settings: PortraitBeautySettings, faces: [VNFaceObservation]?) -> CIImage? {
        // Mode-driven ceiling: natural caps hard to keep texture; advanced opens up.
        var settings = settings
        let limits = Self.limits(for: settings.mode)
        func clamp(_ value: Double, _ key: WritableKeyPath<PortraitBeautySettings, Double>) -> Double {
            max(limits.zero, min(limits.ceiling, settings[keyPath: key]))
        }
        settings.skin = clamp(settings.skin, \.skin)
        settings.faceDepth = clamp(settings.faceDepth, \.faceDepth)
        settings.faceSlim = clamp(settings.faceSlim, \.faceSlim)
        settings.eyeLift = clamp(settings.eyeLift, \.eyeLift)
        settings.eyeEnlarge = clamp(settings.eyeEnlarge, \.eyeEnlarge)
        settings.noseStraighten = clamp(settings.noseStraighten, \.noseStraighten)
        settings.lipEnhance = clamp(settings.lipEnhance, \.lipEnhance)
        settings.skinWhiten = clamp(settings.skinWhiten, \.skinWhiten)
        settings.faceBrighten = clamp(settings.faceBrighten, \.faceBrighten)
        settings.eyeshadow = clamp(settings.eyeshadow, \.eyeshadow)
        settings.eyeliner = clamp(settings.eyeliner, \.eyeliner)
        settings.doubleEyelid = clamp(settings.doubleEyelid, \.doubleEyelid)

        let resolvedFaces: [VNFaceObservation]
        if let faces {
            resolvedFaces = faces
        } else {
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(ciImage: ci, orientation: .up, options: [:])
            do { try handler.perform([request]) } catch { return nil }
            resolvedFaces = (request.results ?? []).sorted {
                ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }
        }
        guard let face = resolvedFaces.first else { return nil }

        let extent = ci.extent
        let faceRect = visionRect(face.boundingBox, in: extent)
        guard faceRect.width > 4, faceRect.height > 4 else { return nil }

        var result = ci

        // Commercial Natural: conservative, offline, non-generative skin-tone
        // balancing. This is NOT a trained acne/spot detector. Protect eyes/lips,
        // retain original high-frequency detail, and never alter facial geometry.
        if settings.mode == .commercialNatural {
            let low = ci.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(3, min(16, extent.width / 180))])
                .cropped(to: extent)
            let corrected = low.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.97,
                kCIInputBrightnessKey: 0.006,
                kCIInputContrastKey: 1.015
            ]).cropped(to: extent)
            // Blend only a small amount of the corrected low frequency layer;
            // the original remains dominant, avoiding a plastic-skin appearance.
            let mixed = corrected.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: ci, kCIInputTimeKey: 0.84
            ]).cropped(to: extent)
            for detectedFace in resolvedFaces.prefix(6) {
                if let mask = skinMask(face: detectedFace, extent: extent) {
                    result = mixed.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: result,
                        kCIInputMaskImageKey: mask
                    ]).cropped(to: extent)
                }
            }
        }

        // 1) 只对皮肤区域柔和处理，眼睛与嘴唇从遮罩里扣除。
        if settings.skin > 0.001 {
            let radius = max(1, min(24, extent.width / 300))
            let blurred = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
            // CainCamera's high-pass + detail-dependent blend, ported from GLSL to Core Image.
            // Face landmark masks further protect eyes, eyebrows and lips. No Face++ SDK.
            let smoothed = CainBeautyKernels.apply(source: ci, blurred: blurred, intensity: min(0.30, max(0, settings.skin)))
            for face in resolvedFaces.prefix(6) {
                guard let mask = skinMask(face: face, extent: extent) else { continue }
                result = smoothed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask]).cropped(to: extent)
            }
        }

        // 2) 面部立体：非常小的中心鼓起。
        if settings.faceDepth > 0.001 {
            let warp = CIFilter.bumpDistortion()
            warp.inputImage = result
            warp.center = CGPoint(x: faceRect.midX, y: faceRect.midY + faceRect.height * 0.04)
            warp.radius = Float(min(faceRect.width, faceRect.height) * 0.40)
            warp.scale = Float(min(0.015, max(0, settings.faceDepth) * 0.045))
            if let output = warp.outputImage?.cropped(to: extent) { result = output }
        }

        // 3) 轮廓微调：小幅 inward warp，强度严格封顶。
        if settings.faceSlim > 0.001 {
            let warp = CIFilter.bumpDistortion()
            warp.inputImage = result
            warp.center = CGPoint(x: faceRect.midX, y: faceRect.midY)
            warp.radius = Float(min(faceRect.width, faceRect.height) * 0.58)
            warp.scale = Float(-min(0.025, max(0, settings.faceSlim) * 0.075))
            if let output = warp.outputImage?.cropped(to: extent) { result = output }
        }

        // 4) 眼神提亮（不是放大眼睛）。
        if settings.eyeLift > 0.001, let landmarks = face.landmarks {
            let eyes = [landmarks.leftEye, landmarks.rightEye].compactMap { $0 }
            for eye in eyes {
                guard let eyeMask = regionMask(eye, face: face, extent: extent) else { continue }
                let bright = CIFilter.colorControls()
                bright.inputImage = result
                bright.brightness = Float(min(0.045, max(0, settings.eyeLift) * 0.20))
                bright.contrast = Float(1.0 + min(0.03, max(0, settings.eyeLift) * 0.08))
                if let output = bright.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = output
                    blend.backgroundImage = result
                    blend.maskImage = eyeMask
                    if let eyeResult = blend.outputImage { result = eyeResult.cropped(to: extent) }
                }
            }
        }

        // 5) 大眼：对每个眼睛区域做局部径向鼓起。进阶模式上限更高。
        if settings.eyeEnlarge > 0.001, let landmarks = face.landmarks {
            for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                let box = regionBoundingBox(eye, face: face, extent: extent)
                guard box.width > 2, box.height > 2 else { continue }
                let warp = CIFilter.bumpDistortion()
                warp.inputImage = result
                warp.center = CGPoint(x: box.midX, y: box.midY)
                warp.radius = Float(max(box.width, box.height) * 0.65)
                warp.scale = Float(min(0.35, max(0, settings.eyeEnlarge) * 0.35))
                if let output = warp.outputImage?.cropped(to: extent) { result = output }
            }
        }

        // 6) 挺鼻：鼻梁区域小幅竖向拉伸 + 两侧收窄。
        if settings.noseStraighten > 0.001, let nose = face.landmarks?.nose {
            let box = regionBoundingBox(nose, face: face, extent: extent)
            if box.width > 2, box.height > 4 {
                // 收窄：以鼻梁中心为锚的负向 bump（向内凹）。
                let narrow = CIFilter.bumpDistortion()
                narrow.inputImage = result
                narrow.center = CGPoint(x: box.midX, y: box.midY)
                narrow.radius = Float(box.width * 0.9)
                narrow.scale = Float(-min(0.18, max(0, settings.noseStraighten) * 0.18))
                if let output = narrow.outputImage?.cropped(to: extent) { result = output }
            }
        }

        // 7) 唇形：嘴唇区域提升红润与饱和，让唇色更鲜明。
        if settings.lipEnhance > 0.001, let lips = face.landmarks?.outerLips {
            if let lipMask = regionMask(lips, face: face, extent: extent) {
                let cc = CIFilter.colorControls()
                cc.inputImage = result
                cc.saturation = Float(1.0 + min(0.35, max(0, settings.lipEnhance) * 0.35))
                cc.brightness = Float(min(0.04, max(0, settings.lipEnhance) * 0.04))
                if let output = cc.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = output
                    blend.backgroundImage = result
                    blend.maskImage = lipMask
                    if let lipResult = blend.outputImage { result = lipResult.cropped(to: extent) }
                }
            }
        }

        // 7b) 眼影：上眼睑上方带状区域色彩加深，柔和羽化。
        if settings.eyeshadow > 0.001, let landmarks = face.landmarks {
            let a = min(1, max(0, settings.eyeshadow))
            for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                guard let mask = eyeshadowMask(eye, face: face, extent: extent) else { continue }
                let tint = CIFilter.colorControls()
                tint.inputImage = result
                tint.saturation = Float(1.0 + 0.22 * a)
                tint.brightness = Float(-0.05 * a)
                tint.contrast = Float(1.0 + 0.08 * a)
                if let tinted = tint.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = tinted
                    blend.backgroundImage = result
                    blend.maskImage = mask
                    if let out = blend.outputImage { result = out.cropped(to: extent) }
                }
            }
        }

        // 7c) 双眼皮：上眼睑上方窄带，上暗下亮微对比。
        if settings.doubleEyelid > 0.001, let landmarks = face.landmarks {
            let a = min(1, max(0, settings.doubleEyelid))
            for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                guard let (darkMask, lightMask) = eyelidBands(eye, face: face, extent: extent) else { continue }
                let darken = CIFilter.colorControls()
                darken.inputImage = result
                darken.brightness = Float(-0.06 * a)
                if let darkOut = darken.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = darkOut; blend.backgroundImage = result; blend.maskImage = darkMask
                    if let out = blend.outputImage { result = out.cropped(to: extent) }
                }
                let lighten = CIFilter.colorControls()
                lighten.inputImage = result
                lighten.brightness = Float(0.04 * a)
                if let lightOut = lighten.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = lightOut; blend.backgroundImage = result; blend.maskImage = lightMask
                    if let out = blend.outputImage { result = out.cropped(to: extent) }
                }
            }
        }

        // 7d) 眼线：上眼睑折线描边加深，不做模糊。
        if settings.eyeliner > 0.001, let landmarks = face.landmarks {
            let a = min(1, max(0, settings.eyeliner))
            for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                guard let mask = eyelinerMask(eye, face: face, extent: extent) else { continue }
                let darken = CIFilter.colorControls()
                darken.inputImage = result
                darken.brightness = Float(-0.15 * a)
                darken.contrast = Float(1.0 + 0.06 * a)
                if let darkOut = darken.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = darkOut; blend.backgroundImage = result; blend.maskImage = mask
                    if let out = blend.outputImage { result = out.cropped(to: extent) }
                }
            }
        }

        // 8) 美白：皮肤区域提亮 + 轻度降饱和，避免"惨白"，保留血色。
        if settings.skinWhiten > 0.001 {
            for face in resolvedFaces.prefix(6) {
                guard let mask = skinMask(face: face, extent: extent) else { continue }
                let cc = CIFilter.colorControls()
                cc.inputImage = result
                cc.brightness = Float(min(0.18, max(0, settings.skinWhiten) * 0.18))
                cc.saturation = Float(1.0 - min(0.10, max(0, settings.skinWhiten) * 0.10))
                if let output = cc.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = output
                    blend.backgroundImage = result
                    blend.maskImage = mask
                    if let whitened = blend.outputImage { result = whitened.cropped(to: extent) }
                }
            }
        }

        // 9) 面部提亮：整张脸区域柔和提亮，作用在五官几何调整之后。
        if settings.faceBrighten > 0.001 {
            let faceMask = ellipseMask(in: faceRect.insetBy(dx: -faceRect.width * 0.05, dy: -faceRect.height * 0.05),
                                       size: CGSize(width: extent.width, height: extent.height))
            let cc = CIFilter.colorControls()
            cc.inputImage = result
            cc.brightness = Float(min(0.12, max(0, settings.faceBrighten) * 0.12))
            if let output = cc.outputImage {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = output
                blend.backgroundImage = result
                blend.maskImage = faceMask
                if let brightened = blend.outputImage { result = brightened.cropped(to: extent) }
            }
        }

        result = colorFinish(result, settings: settings)
        return result.cropped(to: extent)
    }

    // MARK: - 基础画面微调

    private func colorFinish(_ image: CIImage, settings: PortraitBeautySettings) -> CIImage {
        let color = CIFilter.colorControls()
        color.inputImage = image
        color.saturation = Float(1.0 + min(0.04, max(0, settings.environmentBlend) * 0.08))
        color.contrast = Float(1.0 + min(0.04, max(0, settings.clarity) * 0.10))
        color.brightness = 0
        return color.outputImage ?? image
    }

    // MARK: - 遮罩
    //
    // 关键修正：画布尺寸必须与图像宽高比一致。
    // 上一版用 512×512 方形画布 + 等比缩放居中裁切，导致 3:4 照片里的
    // 人脸/眼睛遮罩被横向压缩并整体偏移，磨皮和瘦脸会作用到错误区域。

    private func skinMask(face: VNFaceObservation, extent: CGRect) -> CIImage? {
        let size = canvasSize(for: extent)
        guard let ctx = makeGrayContext(size) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))

        let b = face.boundingBox
        let rect = CGRect(x: b.minX * size.width,
                          y: b.minY * size.height,
                          width: b.width * size.width,
                          height: b.height * size.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: rect.insetBy(dx: -rect.width * 0.06, dy: -rect.height * 0.04))

        if let landmarks = face.landmarks {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for region in [landmarks.leftEye, landmarks.rightEye, landmarks.leftEyebrow, landmarks.rightEyebrow, landmarks.outerLips].compactMap({ $0 }) {
                let points = region.normalizedPoints.map { p in
                    CGPoint(x: (b.minX + p.x * b.width) * size.width,
                            y: (b.minY + p.y * b.height) * size.height)
                }
                drawPolygon(points, in: ctx)
            }
        }
        return finishMask(ctx, size: size, extent: extent)
    }

    private func regionMask(_ region: VNFaceLandmarkRegion2D, face: VNFaceObservation, extent: CGRect) -> CIImage? {
        let size = canvasSize(for: extent)
        guard let ctx = makeGrayContext(size) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let b = face.boundingBox
        let points = region.normalizedPoints.map { p in
            CGPoint(x: (b.minX + p.x * b.width) * size.width,
                    y: (b.minY + p.y * b.height) * size.height)
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        drawPolygon(points, in: ctx)
        return finishMask(ctx, size: size, extent: extent)
    }

    // MARK: - 眼妆遮罩

    private func eyeshadowMask(_ eye: VNFaceLandmarkRegion2D, face: VNFaceObservation, extent: CGRect) -> CIImage? {
        let size = canvasSize(for: extent)
        guard let ctx = makeGrayContext(size) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let b = face.boundingBox
        let pts = eye.normalizedPoints.map { p in
            CGPoint(x: (b.minX + p.x * b.width) * size.width,
                    y: (b.minY + p.y * b.height) * size.height)
        }
        guard !pts.isEmpty else { return nil }
        let ys = pts.map { $0.y }
        guard let minY = ys.min(), let maxY = ys.max() else { return nil }
        let eyeHeight = max(1, maxY - minY)
        let shift = eyeHeight * 0.45
        var upper = pts.map { CGPoint(x: $0.x * 1.10 + (size.width * 0.5 - size.width * 0.5), y: $0.y + shift) }
        // Clamp x within canvas
        upper = upper.map { CGPoint(x: max(0, min(size.width, $0.x)), y: max(0, min(size.height, $0.y))) }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        drawPolygon(upper, in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let mask = fitExact(CIImage(cgImage: cg), to: extent)
        let radius = Float(max(3, extent.width * 0.006))
        return mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
    }

    private func eyelidBands(_ eye: VNFaceLandmarkRegion2D, face: VNFaceObservation, extent: CGRect) -> (CIImage, CIImage)? {
        let size = canvasSize(for: extent)
        guard let darkCtx = makeGrayContext(size), let lightCtx = makeGrayContext(size) else { return nil }
        let b = face.boundingBox
        let pts = eye.normalizedPoints.map { p in
            CGPoint(x: (b.minX + p.x * b.width) * size.width,
                    y: (b.minY + p.y * b.height) * size.height)
        }
        guard !pts.isEmpty else { return nil }
        let ys = pts.map { $0.y }
        guard let minY = ys.min(), let maxY = ys.max() else { return nil }
        let eyeHeight = max(1, maxY - minY)
        // Dark band: 0.18*eyeHeight above eye
        let darkShift = eyeHeight * 0.18
        let dark = pts.map { CGPoint(x: $0.x, y: $0.y + darkShift) }
        // Light band: 0.06*eyeHeight above eye (closer to lid)
        let lightShift = eyeHeight * 0.06
        let light = pts.map { CGPoint(x: $0.x, y: $0.y + lightShift) }

        for ctx in [darkCtx, lightCtx] {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        darkCtx.setFillColor(CGColor(gray: 1, alpha: 1))
        drawPolygon(dark, in: darkCtx)
        lightCtx.setFillColor(CGColor(gray: 1, alpha: 1))
        drawPolygon(light, in: lightCtx)

        let radius = Float(max(2, extent.width * 0.003))
        func makeMask(_ ctx: CGContext) -> CIImage? {
            guard let cg = ctx.makeImage() else { return nil }
            let mask = fitExact(CIImage(cgImage: cg), to: extent)
            return mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        guard let darkMask = makeMask(darkCtx), let lightMask = makeMask(lightCtx) else { return nil }
        return (darkMask, lightMask)
    }

    private func eyelinerMask(_ eye: VNFaceLandmarkRegion2D, face: VNFaceObservation, extent: CGRect) -> CIImage? {
        let size = canvasSize(for: extent)
        guard let ctx = makeGrayContext(size) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let b = face.boundingBox
        let pts = eye.normalizedPoints.map { p in
            CGPoint(x: (b.minX + p.x * b.width) * size.width,
                    y: (b.minY + p.y * b.height) * size.height)
        }
        guard !pts.isEmpty else { return nil }
        let ys = pts.map { $0.y }
        guard let minY = ys.min(), let maxY = ys.max() else { return nil }
        let eyeHeight = max(1, maxY - minY)
        let shift = eyeHeight * 0.02
        let line = pts.map { CGPoint(x: $0.x, y: $0.y + shift) }
        let lineWidth = max(1.2, size.width * 0.003)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        drawStrokedPath(line, in: ctx, lineWidth: lineWidth)
        guard let cg = ctx.makeImage() else { return nil }
        let mask = fitExact(CIImage(cgImage: cg), to: extent)
        return mask.cropped(to: extent)
    }

    private func drawStrokedPath(_ points: [CGPoint], in ctx: CGContext, lineWidth: CGFloat, closed: Bool = false) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawPolygon(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    private func finishMask(_ ctx: CGContext, size: CGSize, extent: CGRect) -> CIImage? {
        guard let cg = ctx.makeImage() else { return nil }
        let mask = fitExact(CIImage(cgImage: cg), to: extent)
        let radius = Float(max(2, extent.width * 0.004))
        return mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
    }

    private func canvasSize(for extent: CGRect) -> CGSize {
        let longSide: CGFloat = 512
        guard extent.width > 0, extent.height > 0 else { return CGSize(width: 512, height: 512) }
        let aspect = extent.height / extent.width
        if aspect >= 1 {
            return CGSize(width: max(64, (longSide / aspect).rounded()), height: longSide)
        }
        return CGSize(width: longSide, height: max(64, (longSide * aspect).rounded()))
    }

    private func makeGrayContext(_ size: CGSize) -> CGContext? {
        CGContext(data: nil,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    private func fitExact(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        return image
            .transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width,
                                               y: extent.height / image.extent.height))
            .cropped(to: extent)
    }

    private func visionRect(_ box: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + box.minX * extent.width,
               y: extent.minY + box.minY * extent.height,
               width: box.width * extent.width,
               height: box.height * extent.height)
    }

    /// Bounding box of a face-landmark region in image coordinates. Vision
    /// gives points in normalized face-space (0..1 of the face box), so they
    /// must be scaled by both the face box and the image extent.
    private func regionBoundingBox(_ region: VNFaceLandmarkRegion2D, face: VNFaceObservation, extent: CGRect) -> CGRect {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return .zero }
        let xs = points.map { (face.boundingBox.minX + $0.x * face.boundingBox.width) * extent.width }
        let ys = points.map { (face.boundingBox.minY + $0.y * face.boundingBox.height) * extent.height }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(), maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Soft elliptical mask covering a rect, faded at the edges. Used for
    /// whole-face adjustments where a hard rect would show a visible boundary.
    private func ellipseMask(in rect: CGRect, size: CGSize) -> CIImage? {
        let canvas = CGSize(width: max(64, size.width), height: max(64, size.height))
        guard let ctx = makeGrayContext(canvas) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))
        let center = CGPoint(x: (rect.midX / size.width) * canvas.width,
                             y: (rect.midY / size.height) * canvas.height)
        let radiusX = (rect.width / size.width) * canvas.width * 0.5
        let radiusY = (rect.height / size.height) * canvas.height * 0.5
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - radiusX, y: center.y - radiusY, width: radiusX * 2, height: radiusY * 2))
        return finishMask(ctx, size: canvas, extent: CGRect(origin: .zero, size: size))
    }

    private func blendOpacity(foreground: CIImage, background: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let gray = CIColor(red: CGFloat(amount), green: CGFloat(amount), blue: CGFloat(amount), alpha: 1)
        let mask = CIImage(color: gray).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage ?? foreground
    }
}

/// Modified 2026-10-24: Swift/Core Image port of CainCamera high-pass and adjust GLSL.
/// Copyright 2018 cain.huang@outlook.com. Apache-2.0; full license in app Settings and ThirdParty.
enum CainBeautyKernels {
    private static let highPass = CIColorKernel(source: """
        kernel vec4 highPass(__sample source, __sample blur) {
            vec3 delta = source.rgb - blur.rgb;
            return vec4(clamp(48.0 * delta * delta, 0.0, 1.0), 1.0);
        }
        """)
    private static let adjust = CIColorKernel(source: """
        kernel vec4 adjust(__sample source, __sample blur, __sample detail, float intensity) {
            float value = clamp((min(source.b, blur.b) - 0.2) * 5.0, 0.0, 1.0);
            float maximum = max(max(detail.r, detail.g), detail.b);
            float amount = (1.0 - maximum / (maximum + 0.2)) * value * intensity;
            return vec4(mix(source.rgb, blur.rgb, amount), source.a);
        }
        """)
    static func apply(source: CIImage, blurred: CIImage, intensity: Double) -> CIImage {
        guard let high = highPass?.apply(extent: source.extent, arguments: [source, blurred]) else { return source.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": blurred, "inputTime": min(0.30, max(0, intensity))]) }
        let detail = high.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, source.extent.width / 600)]).cropped(to: source.extent)
        return adjust?.apply(extent: source.extent, arguments: [source, blurred, detail, intensity]) ?? source
    }
    static let licenseText = """
                                     Apache License
                               Version 2.0, January 2004
                            http://www.apache.org/licenses/
    
       TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION
    
       1. Definitions.
    
          "License" shall mean the terms and conditions for use, reproduction,
          and distribution as defined by Sections 1 through 9 of this document.
    
          "Licensor" shall mean the copyright owner or entity authorized by
          the copyright owner that is granting the License.
    
          "Legal Entity" shall mean the union of the acting entity and all
          other entities that control, are controlled by, or are under common
          control with that entity. For the purposes of this definition,
          "control" means (i) the power, direct or indirect, to cause the
          direction or management of such entity, whether by contract or
          otherwise, or (ii) ownership of fifty percent (50%) or more of the
          outstanding shares, or (iii) beneficial ownership of such entity.
    
          "You" (or "Your") shall mean an individual or Legal Entity
          exercising permissions granted by this License.
    
          "Source" form shall mean the preferred form for making modifications,
          including but not limited to software source code, documentation
          source, and configuration files.
    
          "Object" form shall mean any form resulting from mechanical
          transformation or translation of a Source form, including but
          not limited to compiled object code, generated documentation,
          and conversions to other media types.
    
          "Work" shall mean the work of authorship, whether in Source or
          Object form, made available under the License, as indicated by a
          copyright notice that is included in or attached to the work
          (an example is provided in the Appendix below).
    
          "Derivative Works" shall mean any work, whether in Source or Object
          form, that is based on (or derived from) the Work and for which the
          editorial revisions, annotations, elaborations, or other modifications
          represent, as a whole, an original work of authorship. For the purposes
          of this License, Derivative Works shall not include works that remain
          separable from, or merely link (or bind by name) to the interfaces of,
          the Work and Derivative Works thereof.
    
          "Contribution" shall mean any work of authorship, including
          the original version of the Work and any modifications or additions
          to that Work or Derivative Works thereof, that is intentionally
          submitted to Licensor for inclusion in the Work by the copyright owner
          or by an individual or Legal Entity authorized to submit on behalf of
          the copyright owner. For the purposes of this definition, "submitted"
          means any form of electronic, verbal, or written communication sent
          to the Licensor or its representatives, including but not limited to
          communication on electronic mailing lists, source code control systems,
          and issue tracking systems that are managed by, or on behalf of, the
          Licensor for the purpose of discussing and improving the Work, but
          excluding communication that is conspicuously marked or otherwise
          designated in writing by the copyright owner as "Not a Contribution."
    
          "Contributor" shall mean Licensor and any individual or Legal Entity
          on behalf of whom a Contribution has been received by Licensor and
          subsequently incorporated within the Work.
    
       2. Grant of Copyright License. Subject to the terms and conditions of
          this License, each Contributor hereby grants to You a perpetual,
          worldwide, non-exclusive, no-charge, royalty-free, irrevocable
          copyright license to reproduce, prepare Derivative Works of,
          publicly display, publicly perform, sublicense, and distribute the
          Work and such Derivative Works in Source or Object form.
    
       3. Grant of Patent License. Subject to the terms and conditions of
          this License, each Contributor hereby grants to You a perpetual,
          worldwide, non-exclusive, no-charge, royalty-free, irrevocable
          (except as stated in this section) patent license to make, have made,
          use, offer to sell, sell, import, and otherwise transfer the Work,
          where such license applies only to those patent claims licensable
          by such Contributor that are necessarily infringed by their
          Contribution(s) alone or by combination of their Contribution(s)
          with the Work to which such Contribution(s) was submitted. If You
          institute patent litigation against any entity (including a
          cross-claim or counterclaim in a lawsuit) alleging that the Work
          or a Contribution incorporated within the Work constitutes direct
          or contributory patent infringement, then any patent licenses
          granted to You under this License for that Work shall terminate
          as of the date such litigation is filed.
    
       4. Redistribution. You may reproduce and distribute copies of the
          Work or Derivative Works thereof in any medium, with or without
          modifications, and in Source or Object form, provided that You
          meet the following conditions:
    
          (a) You must give any other recipients of the Work or
              Derivative Works a copy of this License; and
    
          (b) You must cause any modified files to carry prominent notices
              stating that You changed the files; and
    
          (c) You must retain, in the Source form of any Derivative Works
              that You distribute, all copyright, patent, trademark, and
              attribution notices from the Source form of the Work,
              excluding those notices that do not pertain to any part of
              the Derivative Works; and
    
          (d) If the Work includes a "NOTICE" text file as part of its
              distribution, then any Derivative Works that You distribute must
              include a readable copy of the attribution notices contained
              within such NOTICE file, excluding those notices that do not
              pertain to any part of the Derivative Works, in at least one
              of the following places: within a NOTICE text file distributed
              as part of the Derivative Works; within the Source form or
              documentation, if provided along with the Derivative Works; or,
              within a display generated by the Derivative Works, if and
              wherever such third-party notices normally appear. The contents
              of the NOTICE file are for informational purposes only and
              do not modify the License. You may add Your own attribution
              notices within Derivative Works that You distribute, alongside
              or as an addendum to the NOTICE text from the Work, provided
              that such additional attribution notices cannot be construed
              as modifying the License.
    
          You may add Your own copyright statement to Your modifications and
          may provide additional or different license terms and conditions
          for use, reproduction, or distribution of Your modifications, or
          for any such Derivative Works as a whole, provided Your use,
          reproduction, and distribution of the Work otherwise complies with
          the conditions stated in this License.
    
       5. Submission of Contributions. Unless You explicitly state otherwise,
          any Contribution intentionally submitted for inclusion in the Work
          by You to the Licensor shall be under the terms and conditions of
          this License, without any additional terms or conditions.
          Notwithstanding the above, nothing herein shall supersede or modify
          the terms of any separate license agreement you may have executed
          with Licensor regarding such Contributions.
    
       6. Trademarks. This License does not grant permission to use the trade
          names, trademarks, service marks, or product names of the Licensor,
          except as required for reasonable and customary use in describing the
          origin of the Work and reproducing the content of the NOTICE file.
    
       7. Disclaimer of Warranty. Unless required by applicable law or
          agreed to in writing, Licensor provides the Work (and each
          Contributor provides its Contributions) on an "AS IS" BASIS,
          WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
          implied, including, without limitation, any warranties or conditions
          of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
          PARTICULAR PURPOSE. You are solely responsible for determining the
          appropriateness of using or redistributing the Work and assume any
          risks associated with Your exercise of permissions under this License.
    
       8. Limitation of Liability. In no event and under no legal theory,
          whether in tort (including negligence), contract, or otherwise,
          unless required by applicable law (such as deliberate and grossly
          negligent acts) or agreed to in writing, shall any Contributor be
          liable to You for damages, including any direct, indirect, special,
          incidental, or consequential damages of any character arising as a
          result of this License or out of the use or inability to use the
          Work (including but not limited to damages for loss of goodwill,
          work stoppage, computer failure or malfunction, or any and all
          other commercial damages or losses), even if such Contributor
          has been advised of the possibility of such damages.
    
       9. Accepting Warranty or Additional Liability. While redistributing
          the Work or Derivative Works thereof, You may choose to offer,
          and charge a fee for, acceptance of support, warranty, indemnity,
          or other liability obligations and/or rights consistent with this
          License. However, in accepting such obligations, You may act only
          on Your own behalf and on Your sole responsibility, not on behalf
          of any other Contributor, and only if You agree to indemnify,
          defend, and hold each Contributor harmless for any liability
          incurred by, or claims asserted against, such Contributor by reason
          of your accepting any such warranty or additional liability.
    
       END OF TERMS AND CONDITIONS
    
       APPENDIX: How to apply the Apache License to your work.
    
          To apply the Apache License to your work, attach the following
          boilerplate notice, with the fields enclosed by brackets "[]"
          replaced with your own identifying information. (Don't include
          the brackets!)  The text should be enclosed in the appropriate
          comment syntax for the file format. We also recommend that a
          file or class name and description of purpose be included on the
          same "printed page" as the copyright notice for easier
          identification within third-party archives.
    
       Copyright [yyyy] [name of copyright owner]
    
       Licensed under the Apache License, Version 2.0 (the "License");
       you may not use this file except in compliance with the License.
       You may obtain a copy of the License at
    
           http://www.apache.org/licenses/LICENSE-2.0
    
       Unless required by applicable law or agreed to in writing, software
       distributed under the License is distributed on an "AS IS" BASIS,
       WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
       See the License for the specific language governing permissions and
       limitations under the License.
    
    """
}

/// One in-flight preview frame; expensive Vision/CI work stays off capture and main queues.
/// Inspired by CainCamera's staged pipeline. Preview resolution is independent of still capture.
final class RealtimePreviewProcessor {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "opa.preview.effects", qos: .userInitiated)
    private var options = PhotoRenderOptions()
    private var enabled = false
    private var sink: ((CGImage?) -> Void)?
    private var inFlight = false
    private var lastFrame = 0.0
    private var generation = 0
    /// Live-preview throttling state. The two heavy Vision requests no longer
    /// run on every preview frame: face landmarks cap at ~5Hz and reuse the
    /// last result in between; segmentation runs through BackgroundBlurProcessor.
    private var cachedFaces: [VNFaceObservation]?
    private var lastFaceDetect = -Double.infinity
    private let backgroundBlur = BackgroundBlurProcessor()
    /// Adaptive frame pacing: instead of a fixed 15fps/8fps, the processor
    /// measures how long each frame actually takes and lowers its own cadence
    /// when the device cannot keep up. This is the runtime safety net for the
    /// case where the chosen throttle thresholds were never validated on a
    /// given iPhone — the device tells us, we don't have to guess.
    private var adaptiveFps: Double = 15.0
    private var recentDurations: [Double] = []

    func configure(options: PhotoRenderOptions, enabled: Bool, sink: @escaping (CGImage?) -> Void) {
        lock.lock()
        let changed = self.enabled != enabled || self.options.filter != options.filter || self.options.grade != options.grade || self.options.style != options.style || self.options.beauty != options.beauty || self.options.filterStrength != options.filterStrength || self.options.backgroundBlur != options.backgroundBlur || self.options.outputAspect != options.outputAspect
        self.options = options; self.enabled = enabled; self.sink = sink
        if changed { generation += 1 }
        lock.unlock()
        if !enabled { sink(nil) }
    }
    func detach() {
        lock.lock(); sink = nil; enabled = false; generation += 1; lock.unlock()
    }
    func consume(_ sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // Thermal state is a hard ceiling; adaptive pacing sits below it.
        let thermalCap = ProcessInfo.processInfo.thermalState == .serious
            || ProcessInfo.processInfo.thermalState == .critical ? 8.0 : 15.0
        let fps = min(adaptiveFps, thermalCap)
        guard enabled, sink != nil, !inFlight, now - lastFrame >= 1 / fps,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { lock.unlock(); return }
        inFlight = true; lastFrame = now
        let options = self.options
        let generation = self.generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let frameStart = ProcessInfo.processInfo.systemUptime
            let result: CGImage? = autoreleasepool {
                var image = CIImage(cvPixelBuffer: buffer) // camera output is portrait, unmirrored
                let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let beauty = options.beauty {
                    // Face landmarks are detected at ~5Hz and reused between frames;
                    // a 15fps preview therefore runs VNDetect ~5 times, not 15.
                    let now = ProcessInfo.processInfo.systemUptime
                    let faces: [VNFaceObservation]?
                    if now - self.lastFaceDetect >= 0.2 {
                        faces = PortraitBeautyEngine.detectFaces(in: image)
                        self.cachedFaces = faces
                        self.lastFaceDetect = now
                    } else {
                        faces = self.cachedFaces
                    }
                    image = PortraitBeautyEngine.shared.processCI(image, settings: beauty, faces: faces) ?? image
                }
                image = PhotoPostProcessor.applyColor(to: image, options: options)
                image = self.backgroundBlur.process(image, strength: options.backgroundBlur)
                return ImagePipeline.context.createCGImage(image, from: image.extent)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - frameStart
            DispatchQueue.main.async {
                self.lock.lock()
                let deliver = self.generation == generation && self.enabled ? self.sink : nil
                self.inFlight = false
                // Adaptive pacing: average the last few frame durations and
                // nudge the target fps so a frame that overran its budget
                // slows the next one, while sustained headroom speeds back up.
                self.recentDurations.append(elapsed)
                if self.recentDurations.count > 8 { self.recentDurations.removeFirst() }
                let avg = self.recentDurations.reduce(0, +) / Double(self.recentDurations.count)
                let budget = 1.0 / self.adaptiveFps
                if avg > budget * 0.6 {
                    self.adaptiveFps = max(6, self.adaptiveFps - 1.5)
                } else if avg < budget * 0.3 && self.adaptiveFps < 15 {
                    self.adaptiveFps = min(15, self.adaptiveFps + 0.5)
                }
                self.lock.unlock()
                deliver?(result)
            }
        }
    }
}
