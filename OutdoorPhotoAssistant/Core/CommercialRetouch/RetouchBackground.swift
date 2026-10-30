import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Errors

enum RetouchBackgroundError: LocalizedError {
    case segmentationUnavailable
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .segmentationUnavailable:
            return "主体分割不可用，已保留原背景"
        case .renderFailed:
            return "背景合成失败"
        }
    }
}

// MARK: - Engine

/// Background replacement (keep / clean / solid / gradient), ID-photo framing and
/// the 6-inch print sheet for the commercial retouch studio.
///
/// Everything is a Core Image built-in graph: no custom `CIKernel`, no CPU canvas,
/// no per-pixel loop at full resolution. The Vision matte is upscaled by an affine
/// transform and refined with two filters (feather + edge restore), and the old
/// background's fringe is removed by pulling the transition band toward the *new*
/// background before the final composite, which is what kills the white outline.
///
/// Coordinate conventions:
///   * `FaceGeometry` is normalised, origin top-left, y down (project convention).
///   * Core Image is bottom-left, y up. Conversions happen only at the edges of
///     this file, and only through `CGRect` maths.
final class RetouchBackgroundEngine {

    // MARK: - Tuning (the numbers the studio validates against print specs)

    /// Print resolution used whenever a caller passes a non-positive dpi.
    static let defaultDPI: Double = 300
    /// Vision's face box stops at the forehead; the print spec measures crown to
    /// chin, so the head box is grown by 8 % before the ratio is fitted.
    static let hairAllowance: Double = 1.08
    /// Eye line of an ID photo, measured from the top of the frame.
    static let eyeLineRatio: CGFloat = 0.44
    /// Soft-matte feather, in full-resolution pixels.
    static let minFeatherPx: CGFloat = 1.5
    static let maxFeatherPx: CGFloat = 2.5
    /// Crop marks on the print sheet.
    static let cropMarkMillimeters: Double = 3.0
    static let cropMarkThicknessMillimeters: Double = 0.15
    /// Hard ceiling for any generated canvas, so a bogus request cannot allocate
    /// a gigapixel image.
    static let maxRenderEdge: CGFloat = 16384
    /// Long edge handed to Vision. Segmentation is scale tolerant; the full
    /// resolution image never leaves the GPU.
    static let segmentationEdge: CGFloat = 1600

    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    // MARK: - Subject mask

    /// Subject alpha (1 = subject). Vision person segmentation, falling back to the
    /// iOS 17 foreground instance mask, falling back to nil so the caller keeps the
    /// original image. The returned pixel buffer is scaled to the image extent with
    /// Core Image (no CPU pass) and then refined into a soft matte.
    func subjectMask(for image: CIImage, geometry: FaceGeometry?, context: CIContext) -> CIImage? {
        let extent = image.extent
        guard Self.isUsable(extent), max(extent.width, extent.height) >= 8 else { return nil }
        guard let source = Self.visionProxy(image, maximumEdge: Self.segmentationEdge, context: context) else {
            return nil
        }
        guard let buffer = Self.personSegmentationBuffer(source) ?? Self.foregroundSegmentationBuffer(source) else {
            return nil
        }
        let raw = CIImage(cvPixelBuffer: buffer)
        guard let aligned = Self.aligned(raw, to: extent) else { return nil }
        // The matte follows the face scale: hair wisps need a slightly wider band
        // on a close-up than on a half body frame, but never outside 1.5-2.5 px.
        let feather = Self.featherRadius(for: geometry, extent: extent)
        return Self.refine(aligned, feather: feather, extent: extent)
    }

    /// Person segmentation is the primary path: `.accurate` keeps the hairline that
    /// `.balanced` trims away, and OneComponent8 is exactly the matte we want.
    private static func personSegmentationBuffer(_ source: CGImage) -> CVPixelBuffer? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        guard let observation = request.results?.first else { return nil }
        let buffer = observation.pixelBuffer
        guard CVPixelBufferGetWidth(buffer) >= 1, CVPixelBufferGetHeight(buffer) >= 1 else { return nil }
        return buffer
    }

    /// iOS 17 foreground instances cover animals and products, where the person
    /// segmenter returns an empty mask. All instances are unioned into one matte.
    private static func foregroundSegmentationBuffer(_ source: CGImage) -> CVPixelBuffer? {
        if #available(iOS 17.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: source, options: [:])
            guard (try? handler.perform([request])) != nil else { return nil }
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            guard let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances,
                                                                      from: handler) else { return nil }
            guard CVPixelBufferGetWidth(buffer) >= 1, CVPixelBufferGetHeight(buffer) >= 1 else { return nil }
            return buffer
        } else {
            return nil
        }
    }

    /// Long edge at most `maximumEdge`; the proxy only feeds Vision, the returned
    /// mask is scaled back up in Core Image.
    static func visionProxy(_ image: CIImage, maximumEdge: CGFloat, context: CIContext) -> CGImage? {
        let extent = image.extent
        guard isUsable(extent), maximumEdge > 1 else { return nil }
        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > maximumEdge ? maximumEdge / longEdge : 1
        let proxy = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return PixelKit.cgImage(proxy, context: context)
    }

    /// Aligns a mask of any size/origin onto `extent` with one affine transform.
    static func aligned(_ mask: CIImage, to extent: CGRect) -> CIImage? {
        let maskExtent = mask.extent
        guard isUsable(maskExtent), isUsable(extent) else { return nil }
        let scaleX = extent.width / maskExtent.width
        let scaleY = extent.height / maskExtent.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        let transform = CGAffineTransform(translationX: -maskExtent.minX, y: -maskExtent.minY)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return mask.transformed(by: transform).cropped(to: extent)
    }

    /// Soft matte: feather (1.5-2.5 px) then an edge-aware restore.
    ///
    /// The Gaussian alone would either keep Vision's stair-stepped alpha (hard hair
    /// cut) or melt the whole silhouette; the unsharp pass re-raises the edge
    /// contrast *after* the blur, so the transition band stays wide over hair and
    /// crisp over a shoulder. Filter count is constant (2), no CPU pass.
    static func refine(_ mask: CIImage, feather: CGFloat, extent: CGRect) -> CIImage {
        let radius = min(max(feather.isFinite ? feather : 2.0, minFeatherPx), maxFeatherPx)
        let soft = blurred(mask, radius: radius, extent: extent)
        let sharpener = CIFilter.unsharpMask()
        sharpener.inputImage = soft
        sharpener.radius = Float(radius * 2.0)
        sharpener.intensity = 0.55
        return (sharpener.outputImage ?? soft).cropped(to: extent)
    }

    /// Feather width for this frame, in full-resolution pixels.
    static func featherRadius(for geometry: FaceGeometry?, extent: CGRect) -> CGFloat {
        guard let geometry, geometry.box.width > 0, extent.width > 0, extent.width.isFinite else {
            return 2.0
        }
        let faceWidthPx = geometry.box.width * extent.width
        let scaled = faceWidthPx * 0.004
        guard scaled.isFinite else { return 2.0 }
        return min(max(scaled, minFeatherPx), maxFeatherPx)
    }

    // MARK: - Background application

    /// Background cleanup / solid / gradient replacement. Returns the input untouched
    /// when `options.kind == .keep` or when the mask is missing/unusable.
    func apply(_ image: CIImage, subjectMask: CIImage?, options: BackgroundOptions) -> CIImage {
        let extent = image.extent
        guard Self.isUsable(extent) else { return image }
        guard options.kind != .keep else { return image }
        guard let mask = subjectMask, let aligned = Self.aligned(mask, to: extent) else { return image }
        let matte = Self.refine(aligned, feather: CGFloat(options.featherPx), extent: extent)
        switch options.kind {
        case .clean:
            return Self.cleanBackground(image, matte: matte, amount: options.cleanupAmount, extent: extent)
        case .solid, .gradient:
            let background = Self.backgroundImage(options: options, extent: extent)
            return Self.composite(subject: image, matte: matte, background: background,
                                  edgeCleanup: options.edgeCleanup, extent: extent)
        case .keep:
            return image
        }
    }

    /// `.clean` keeps the original background, it just flattens it: studio cloth
    /// wrinkles are mid frequencies, clutter is high frequency, so a two-scale blur
    /// (heavy + smooth) replaces the background region only. The subject keeps its
    /// own pixels, so nothing moves.
    static func cleanBackground(_ image: CIImage, matte: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let strength = min(max(amount.isFinite ? CGFloat(amount) : 0.5, 0), 1)
        guard strength > 0.001 else { return image }
        let longEdge = max(extent.width, extent.height)
        let heavyRadius = max(8, longEdge * 0.02)
        let heavy = blurred(image, radius: heavyRadius, extent: extent)
        let smooth = blurred(image, radius: heavyRadius * 0.25, extent: extent)
        // Two-scale average: the heavy pass removes clutter, the smooth pass keeps
        // the falloff readable instead of a dead flat wall.
        let flatten = PixelKit.blend(smooth, over: heavy,
                                     mask: PixelKit.constantMask(luma: 0.5, extent: extent))
        let backgroundOnly = scaled(complement(matte, extent: extent), gain: strength, extent: extent)
        return PixelKit.blend(flatten, over: image, mask: backgroundOnly).cropped(to: extent)
    }

    /// Subject over the new background through the refined matte.
    ///
    /// Decontamination: the old background's colour is baked into the transition
    /// band (that is the white/blue fringe around hair). Eroding the matte gives the
    /// subject core; the complement of that core *is* the band, and pulling it toward
    /// the new background by `edgeCleanup` removes the fringe while the final blend
    /// keeps the band's alpha. Constant filter count, no loops.
    static func composite(subject: CIImage, matte: CIImage, background: CIImage,
                          edgeCleanup: Double, extent: CGRect) -> CIImage {
        let cleanup = min(max(edgeCleanup.isFinite ? CGFloat(edgeCleanup) : 0.6, 0), 1)
        var edgeSource = subject
        if cleanup > 0.001, let core = eroded(matte, radius: 2.0, extent: extent) {
            let band = scaled(complement(core, extent: extent), gain: cleanup, extent: extent)
            edgeSource = PixelKit.blend(background, over: subject, mask: band)
        }
        return PixelKit.blend(edgeSource, over: background, mask: matte).cropped(to: extent)
    }

    /// Solid or top-to-bottom gradient background, generated at the image extent.
    static func backgroundImage(options: BackgroundOptions, extent: CGRect) -> CIImage {
        switch options.kind {
        case .gradient:
            let endpoints = gradientEndpoints(in: extent)
            let gradient = CIFilter.linearGradient()
            gradient.point0 = endpoints.top
            gradient.point1 = endpoints.bottom
            gradient.color0 = ciColor(options.color)
            gradient.color1 = ciColor(options.colorBottom)
            return (gradient.outputImage ?? solidColor(options.color, extent: extent)).cropped(to: extent)
        default:
            return solidColor(options.color, extent: extent)
        }
    }

    /// A studio gradient runs from the top of the frame down: in Core Image that is
    /// point0 at `y = height` (top) and point1 at `y = 0` (bottom).
    static func gradientEndpoints(in extent: CGRect) -> (top: CGPoint, bottom: CGPoint) {
        (CGPoint(x: extent.minX, y: extent.maxY), CGPoint(x: extent.minX, y: extent.minY))
    }

    static func solidColor(_ color: SIMD3<Double>, extent: CGRect) -> CIImage {
        let fill = ciColor(color)
        return CIImage(color: fill).cropped(to: extent)
    }

    static func ciColor(_ value: SIMD3<Double>) -> CIColor {
        func channel(_ raw: Double) -> CGFloat {
            guard raw.isFinite else { return 0 }
            return CGFloat(min(max(raw, 0.0), 1.0))
        }
        return CIColor(red: channel(value.x), green: channel(value.y), blue: channel(value.z), alpha: 1)
    }

    // MARK: - ID photo

    /// Crops to an ID-photo spec: head height (crown to chin, with the 8 % crown
    /// allowance) equals `spec.headHeightRatio`, the eye line sits at 0.44 of the
    /// photo height, the face is centred horizontally, then the background is
    /// applied at the spec's pixel size.
    ///
    /// The crop is clamped inside the frame when the head sits near an edge; nil is
    /// returned only when the framing is genuinely impossible (no geometry, a zero
    /// size face box, a crop larger than the source, a degenerate output size).
    func idPhoto(_ image: CIImage, geometry: FaceGeometry?, spec: IDPhotoSpec,
                 background: BackgroundOptions,
                 dpi: Double = RetouchBackgroundEngine.defaultDPI) -> CIImage? {
        guard let geometry else { return nil }
        let extent = image.extent
        guard Self.isUsable(extent), max(extent.width, extent.height) >= 16 else { return nil }
        let output = Self.pixelSize(of: spec, dpi: dpi)
        guard output.width >= 1, output.height >= 1 else { return nil }
        let eyeLine = Self.eyeLine(for: geometry)
        guard let crop = Self.idPhotoCrop(faceBox: geometry.box, eyeLine: eyeLine,
                                          sourceSize: extent.size, outputSize: output,
                                          headHeightRatio: spec.headHeightRatio) else { return nil }
        let cropWidth = crop.width * extent.width
        let cropHeight = crop.height * extent.height
        guard cropWidth.isFinite, cropHeight.isFinite, cropWidth >= 2, cropHeight >= 2,
              cropWidth <= extent.width, cropHeight <= extent.height else { return nil }
        // FaceGeometry is top-left y-down; Core Image is bottom-left y-up.
        let leftRaw = extent.minX + crop.minX * extent.width
        let bottomRaw = extent.maxY - (crop.minY + crop.height) * extent.height
        let left = min(max(leftRaw, extent.minX), extent.maxX - cropWidth)
        let bottom = min(max(bottomRaw, extent.minY), extent.maxY - cropHeight)
        guard left.isFinite, bottom.isFinite else { return nil }
        let cropRect = CGRect(x: left, y: bottom, width: cropWidth, height: cropHeight)
        let transform = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
            .concatenating(CGAffineTransform(scaleX: output.width / cropRect.width,
                                             y: output.height / cropRect.height))
        let frame = CGRect(origin: .zero, size: output)
        let framed = image.cropped(to: cropRect).transformed(by: transform).cropped(to: frame)
        guard framed.extent.width >= output.width - 1, framed.extent.height >= output.height - 1 else {
            return nil
        }
        var mask: CIImage?
        if background.needsSegmentation,
           let full = subjectMask(for: image, geometry: geometry, context: context) {
            mask = full.cropped(to: cropRect).transformed(by: transform).cropped(to: frame)
        }
        return apply(framed, subjectMask: mask, options: background).cropped(to: frame)
    }

    /// The eye line of the head, in the normalised top-left space of `FaceGeometry`:
    /// detected eye rects when Vision found them, otherwise the 42 % fallback that
    /// `FaceGeometry.derivedEyes()` documents.
    static func eyeLine(for geometry: FaceGeometry) -> CGFloat {
        let (left, right) = geometry.derivedEyes()
        let value = (left.midY + right.midY) / 2.0
        guard value.isFinite else { return eyeLineRatio }
        return min(max(value, 0.0), 1.0)
    }

    /// Pure framing maths, in normalised top-left coordinates (y down), so it can be
    /// unit tested without Core Image, Vision or a GPU.
    ///
    /// `faceBox.height` is chin-to-forehead; it is grown by `hairAllowance` to reach
    /// crown-to-chin, then scaled so the head occupies `headHeightRatio` of the output
    /// height. The crop is centred on the face's `midX` and the eye line is placed at
    /// `eyeLineRatio` from the top of the crop.
    static func idPhotoCrop(faceBox: CGRect, eyeLine: CGFloat, sourceSize: CGSize,
                            outputSize: CGSize, headHeightRatio: Double,
                            hairAllowance: Double = RetouchBackgroundEngine.hairAllowance) -> CGRect? {
        guard faceBox.width > 0, faceBox.height > 0,
              faceBox.origin.x.isFinite, faceBox.origin.y.isFinite,
              eyeLine.isFinite,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 1, sourceSize.height > 1,
              outputSize.width.isFinite, outputSize.height.isFinite,
              outputSize.width > 1, outputSize.height > 1,
              headHeightRatio.isFinite, headHeightRatio > 0.2, headHeightRatio < 1.5,
              hairAllowance.isFinite, hairAllowance >= 1.0 else { return nil }
        let headSourcePx = Double(faceBox.height) * Double(sourceSize.height) * hairAllowance
        let headTargetPx = headHeightRatio * Double(outputSize.height)
        guard headSourcePx > 0.5, headTargetPx > 0.5 else { return nil }
        let scale = headTargetPx / headSourcePx            // output px per source px
        guard scale.isFinite, scale > 0 else { return nil }
        let cropWidthPx = Double(outputSize.width) / scale
        let cropHeightPx = Double(outputSize.height) / scale
        guard cropWidthPx.isFinite, cropHeightPx.isFinite, cropWidthPx > 0.5, cropHeightPx > 0.5 else {
            return nil
        }
        let cropWidth = cropWidthPx / Double(sourceSize.width)
        let cropHeight = cropHeightPx / Double(sourceSize.height)
        let top = Double(eyeLine) - Double(eyeLineRatio) * cropHeight
        let left = Double(faceBox.midX) - cropWidth / 2.0
        guard top.isFinite, left.isFinite else { return nil }
        return CGRect(x: CGFloat(left), y: CGFloat(top),
                      width: CGFloat(cropWidth), height: CGFloat(cropHeight))
    }

    // MARK: - Print sheet

    /// Lays as many copies of a finished ID photo on a photo paper sheet as fit.
    /// `paper` is in millimetres (6-inch paper = 152 x 102 mm), `gapMillimeters` is
    /// the white gutter between cells. 3 mm crop marks are drawn as thin constant
    /// colour bars at every cell corner, because the GPU path avoids CGContext
    /// canvases. Returns nil when not a single copy fits.
    func printSheet(_ photo: CIImage, spec: IDPhotoSpec, dpi: Double = RetouchBackgroundEngine.defaultDPI,
                    paper: CGSize = CGSize(width: 152, height: 102),
                    gapMillimeters: Double = 2.0) -> CIImage? {
        let photoSize = Self.pixelSize(of: spec, dpi: dpi)
        guard photoSize.width >= 2, photoSize.height >= 2 else { return nil }
        guard paper.width.isFinite, paper.height.isFinite, paper.width > 0, paper.height > 0 else {
            return nil
        }
        let paperPixels = Self.pixelSize(millimeters: paper, dpi: dpi)
        guard paperPixels.width >= photoSize.width, paperPixels.height >= photoSize.height,
              paperPixels.width <= Self.maxRenderEdge, paperPixels.height <= Self.maxRenderEdge else {
            return nil
        }
        let gap = Self.pixels(millimeters: gapMillimeters, dpi: dpi)
        guard let grid = Self.printSheetGrid(photoSize: photoSize, paperPixels: paperPixels,
                                             gapPixels: gap) else { return nil }
        let photoExtent = photo.extent
        guard Self.isUsable(photoExtent) else { return nil }
        let scaleX = photoSize.width / photoExtent.width
        let scaleY = photoSize.height / photoExtent.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        let cellTransform = CGAffineTransform(translationX: -photoExtent.minX, y: -photoExtent.minY)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
        let cellPhoto = photo.transformed(by: cellTransform)
            .cropped(to: CGRect(origin: .zero, size: photoSize))
        let extent = CGRect(origin: .zero, size: paperPixels)
        var sheet = Self.solidColor(SIMD3<Double>(1, 1, 1), extent: extent)
        let markLength = Self.pixels(millimeters: Self.cropMarkMillimeters, dpi: dpi)
        let markThickness = max(1, Self.pixels(millimeters: Self.cropMarkThicknessMillimeters, dpi: dpi))
        let markColor = CIColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1)
        var row = 0
        while row < grid.rows {
            var column = 0
            while column < grid.columns {
                let origin = CGPoint(x: CGFloat(column) * (photoSize.width + gap),
                                     y: CGFloat(row) * (photoSize.height + gap))
                let cell = CGRect(x: origin.x, y: origin.y,
                                  width: photoSize.width, height: photoSize.height)
                let placed = cellPhoto.transformed(by: CGAffineTransform(translationX: cell.minX,
                                                                         y: cell.minY))
                sheet = placed.composited(over: sheet)
                if let marks = Self.cropMarks(around: cell, length: markLength,
                                              thickness: markThickness, color: markColor,
                                              bounds: extent) {
                    sheet = marks.composited(over: sheet)
                }
                column += 1
            }
            row += 1
        }
        return sheet.cropped(to: extent)
    }

    /// Pure grid maths: how many whole cells fit on the sheet with the gutter
    /// between cells but not before the first or after the last one.
    static func printSheetGrid(photoSize: CGSize, paperPixels: CGSize,
                               gapPixels: CGFloat) -> (columns: Int, rows: Int, count: Int)? {
        guard photoSize.width.isFinite, photoSize.height.isFinite,
              photoSize.width >= 1, photoSize.height >= 1,
              paperPixels.width.isFinite, paperPixels.height.isFinite,
              paperPixels.width >= 1, paperPixels.height >= 1 else { return nil }
        let gap = gapPixels.isFinite ? max(0, gapPixels) : 0
        let columns = Int(((paperPixels.width + gap) / (photoSize.width + gap)).rounded(.down))
        let rows = Int(((paperPixels.height + gap) / (photoSize.height + gap)).rounded(.down))
        guard columns >= 1, rows >= 1 else { return nil }
        return (columns, rows, columns * rows)
    }

    /// L-shaped 3 mm marks at the four corners of one cell, built from small
    /// constant-colour images and clipped to the sheet.
    static func cropMarks(around cell: CGRect, length: CGFloat, thickness: CGFloat,
                          color: CIColor, bounds: CGRect) -> CIImage? {
        guard length.isFinite, length > 0.5, thickness.isFinite, thickness > 0.2,
              isUsable(bounds), cell.width > 1, cell.height > 1 else { return nil }
        let bars: [CGRect] = [
            // top-left
            CGRect(x: cell.minX - length, y: cell.maxY, width: length, height: thickness),
            CGRect(x: cell.minX, y: cell.maxY, width: thickness, height: length),
            // top-right
            CGRect(x: cell.maxX, y: cell.maxY, width: length, height: thickness),
            CGRect(x: cell.maxX - thickness, y: cell.maxY, width: thickness, height: length),
            // bottom-left
            CGRect(x: cell.minX - length, y: cell.minY - thickness, width: length, height: thickness),
            CGRect(x: cell.minX, y: cell.minY - length, width: thickness, height: length),
            // bottom-right
            CGRect(x: cell.maxX, y: cell.minY - thickness, width: length, height: thickness),
            CGRect(x: cell.maxX - thickness, y: cell.minY - length, width: thickness, height: length),
        ]
        var marks: CIImage?
        for bar in bars {
            guard bar.width.isFinite, bar.height.isFinite else { continue }
            let clipped = bar.intersection(bounds)
            guard !clipped.isNull, clipped.width >= 0.5, clipped.height >= 0.5 else { continue }
            let piece = CIImage(color: color).cropped(to: clipped)
            marks = marks.map { piece.composited(over: $0) } ?? piece
        }
        return marks?.cropped(to: bounds)
    }

    // MARK: - Units

    /// dpi <= 0, NaN or absurd values fall back to the 300 dpi print standard.
    static func sanitizedDPI(_ dpi: Double) -> Double {
        guard dpi.isFinite, dpi > 1, dpi <= 2400 else { return defaultDPI }
        return dpi
    }

    /// Spec pixel size at `dpi`, clamped to at least 1 px, integral.
    static func pixelSize(of spec: IDPhotoSpec, dpi: Double) -> CGSize {
        let size = spec.pixelSize(dpi: sanitizedDPI(dpi))
        return CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }

    static func pixels(millimeters: Double, dpi: Double) -> CGFloat {
        guard millimeters.isFinite else { return 0 }
        return CGFloat(max(0, millimeters) / 25.4 * sanitizedDPI(dpi))
    }

    static func pixelSize(millimeters: CGSize, dpi: Double) -> CGSize {
        let resolution = sanitizedDPI(dpi)
        let width = Double(millimeters.width)
        let height = Double(millimeters.height)
        guard width.isFinite, height.isFinite else { return .zero }
        return CGSize(width: CGFloat(max(0, width) / 25.4 * resolution),
                      height: CGFloat(max(0, height) / 25.4 * resolution))
    }

    // MARK: - Private helpers

    static func isUsable(_ extent: CGRect) -> Bool {
        guard !extent.isInfinite, !extent.isNull else { return false }
        guard extent.width.isFinite, extent.height.isFinite else { return false }
        return extent.width >= 1 && extent.height >= 1
    }

    /// Gaussian blur that reads edge-clamped pixels, so the frame border never
    /// picks up transparency, and is cropped back to the source extent.
    static func blurred(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let fallback = image.cropped(to: extent)
        guard radius.isFinite, radius > 0.3 else { return fallback }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage else { return fallback }
        return output.cropped(to: extent)
    }

    /// Erodes the matte: everything the erosion removed is the transition band.
    static func eroded(_ mask: CIImage, radius: CGFloat, extent: CGRect) -> CIImage? {
        let filter = CIFilter.morphologyMinimum()
        filter.inputImage = mask
        filter.radius = Float(max(1, radius))
        guard let output = filter.outputImage else { return nil }
        return output.cropped(to: extent)
    }

    /// Luminance complement of a matte, cropped to the working extent.
    static func complement(_ mask: CIImage, extent: CGRect) -> CIImage {
        let invert = CIFilter.colorInvert()
        invert.inputImage = mask
        return (invert.outputImage ?? mask).cropped(to: extent)
    }

    /// Scales a matte's luminance by `gain`, keeping it opaque (blendWithMask reads
    /// luminance, and an opaque mask avoids premultiplication surprises).
    static func scaled(_ image: CIImage, gain: CGFloat, extent: CGRect) -> CIImage {
        let value = min(max(gain, 0), 1)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (matrix.outputImage ?? image).cropped(to: extent)
    }
}
