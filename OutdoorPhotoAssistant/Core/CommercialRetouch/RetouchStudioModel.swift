import Foundation
import UIKit
import CoreImage
import Combine

// MARK: - Per-photo adjustments

/// Everything the studio can change on one photo on top of its preset.
/// All values are neutral at their defaults, so `RetouchAdjustments()` is a
/// no-op and a batch can be re-run with one photo's overrides applied to all.
struct RetouchAdjustments: Codable, Equatable {
    var strength: Double = 1.0              // 0.4 ... 1.3
    var presetID: String = "p25"
    var reshape: ReshapeParameters = .neutral
    var background: BackgroundOptions = .keep
    var idPhoto: IDPhotoSpec? = nil
    var cropToIDPhoto: Bool = false

    var isNeutral: Bool {
        strength == 1.0 && reshape.isNeutral && background.isKeep && !cropToIDPhoto
    }
}

// MARK: - Shoot anchor (batch consistency)

/// One anchor per shoot: every frame is normalised to the same skin tone,
/// exposure and white balance so a delivered set looks like one set, not like
/// twenty independent auto-corrections.
struct ShootAnchor: Codable, Equatable {
    var skinLabMedian: SIMD3<Double>
    var exposure: Double
    var whiteBalance: SIMD3<Double>
    var frameCount: Int
    /// Maximum correction the anchor may apply, so one badly detected frame
    /// cannot drag the whole set. Matches the commercial "±0.5 EV, ±12 % WB" rule.
    var maxEV: Double = 0.75
    var maxWB: Double = 0.12

    /// Per-channel gain + exposure that moves `analysis` onto this anchor.
    ///
    /// The target/frame ratio is measured on the median skin colour in *linear*
    /// light (the same maths as `tools/retouch_lab/studio.py::correction`) and then
    /// split: the luminance part becomes an EV correction capped at `maxEV`, and the
    /// remaining per-channel ratio becomes a white-balance trim capped at `maxWB`.
    /// One clamped gain trying to do both is what makes a delivered set drift.
    func correction(for analysis: SkinAnalysis) -> (gains: SIMD3<Double>, ev: Double) {
        let target = PixelKit.labToRGB(SIMD3<Float>(Float(skinLabMedian.x),
                                                     Float(skinLabMedian.y),
                                                     Float(skinLabMedian.z)))
        let frame = PixelKit.labToRGB(SIMD3<Float>(Float(analysis.skinLabMedian.x),
                                                    Float(analysis.skinLabMedian.y),
                                                    Float(analysis.skinLabMedian.z)))
        let tl = SIMD3<Double>(Double(PixelKit.srgbToLinear(target.x)),
                               Double(PixelKit.srgbToLinear(target.y)),
                               Double(PixelKit.srgbToLinear(target.z)))
        let fl = SIMD3<Double>(Double(PixelKit.srgbToLinear(frame.x)),
                               Double(PixelKit.srgbToLinear(frame.y)),
                               Double(PixelKit.srgbToLinear(frame.z)))
        let ratio = SIMD3<Double>(max(tl.x, 1e-4) / max(fl.x, 1e-4),
                                  max(tl.y, 1e-4) / max(fl.y, 1e-4),
                                  max(tl.z, 1e-4) / max(fl.z, 1e-4))
        let luminance = pow(max(ratio.x * ratio.y * ratio.z, 1e-8), 1.0 / 3.0)
        let ev = min(maxEV, max(-maxEV, log2(max(luminance, 1e-4))))
        let base = pow(2.0, ev)
        func trim(_ r: Double) -> Double {
            min(1.0 + maxWB, max(1.0 - maxWB, r / base))
        }
        return (SIMD3(trim(ratio.x), trim(ratio.y), trim(ratio.z)), ev)
    }

    /// Robust anchor from a shoot: median of the per-frame medians, dropping
    /// frames whose metadata clearly disagrees (eyes closed, heavy makeup, ...).
    static func build(from analyses: [SkinAnalysis]) -> ShootAnchor? {
        let valid = analyses.filter { $0.exposure > 0.02 && $0.longEdge > 0 }
        guard valid.count >= 1 else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let l = median(valid.map { Double($0.skinLabMedian.x) })
        let a = median(valid.map { Double($0.skinLabMedian.y) })
        let b = median(valid.map { Double($0.skinLabMedian.z) })
        let exposure = median(valid.map { $0.exposure })
        let wb = SIMD3(
            median(valid.map { $0.whiteBalance.x }),
            median(valid.map { $0.whiteBalance.y }),
            median(valid.map { $0.whiteBalance.z })
        )
        return ShootAnchor(skinLabMedian: SIMD3(l, a, b), exposure: exposure,
                           whiteBalance: wb, frameCount: valid.count)
    }
}

// MARK: - Liquify (parametric reshape)

/// Studio liquify is parametric, never a free brush: every slider is a
/// deterministic warp with a hard cap, edge locking and a before/after preview.
struct ReshapeParameters: Codable, Equatable {
    var faceWidth: Double = 0      // 瘦脸 0...1
    var jawline: Double = 0        // 下颌收紧
    var chin: Double = 0           // 下巴拉长/收
    var eyeSize: Double = 0        // 大眼
    var noseWidth: Double = 0      // 鼻翼收
    var neckThin: Double = 0
    var waist: Double = 0          // 收腰（半身/全身）
    var armThin: Double = 0
    var edgeLock: Double = 0.85    // 画框边缘锁定，防止背景被拉出
    var maxDisplacement: Double = 0.06   // 以长边为单位的位移上限

    static let neutral = ReshapeParameters()

    var isNeutral: Bool {
        faceWidth == 0 && jawline == 0 && chin == 0 && eyeSize == 0 &&
        noseWidth == 0 && neckThin == 0 && waist == 0 && armThin == 0
    }

    /// Clamps every slider to the commercial safety range and to the sum cap
    /// (a face can take 0.6 of total reshape before it stops looking like a person).
    func clamped() -> ReshapeParameters {
        var p = self
        func clamp(_ v: Double) -> Double { min(1.0, max(0.0, v)) }
        p.faceWidth = clamp(faceWidth); p.jawline = clamp(jawline); p.chin = clamp(chin)
        p.eyeSize = clamp(eyeSize) * 0.6; p.noseWidth = clamp(noseWidth) * 0.5
        p.neckThin = clamp(neckThin); p.waist = clamp(waist); p.armThin = clamp(armThin)
        let faceTotal = p.faceWidth + p.jawline + p.chin + p.eyeSize + p.noseWidth
        if faceTotal > 0.6 {
            let k = 0.6 / faceTotal
            p.faceWidth *= k; p.jawline *= k; p.chin *= k; p.eyeSize *= k; p.noseWidth *= k
        }
        p.edgeLock = min(1.0, max(0.4, edgeLock))
        p.maxDisplacement = min(0.08, max(0.01, maxDisplacement))
        return p
    }
}

// MARK: - Background

struct BackgroundOptions: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case keep      // 保留原背景
        case clean     // 只清理（去褶皱/杂物），不换底
        case solid     // 纯色底
        case gradient  // 渐变底
    }
    var kind: Kind = .keep
    var color: SIMD3<Double> = SIMD3(1, 1, 1)            // 白底默认
    var colorBottom: SIMD3<Double> = SIMD3(0.86, 0.89, 0.95)
    var cleanupAmount: Double = 0.5     // 背景平滑/杂物淡化 0...1
    var edgeCleanup: Double = 0.6       // 发丝边缘清理 0...1
    var featherPx: Double = 2.0

    static let keep = BackgroundOptions()
    static let white = BackgroundOptions(kind: .solid, color: SIMD3(1, 1, 1), colorBottom: SIMD3(1, 1, 1))
    static let studioBlue = BackgroundOptions(kind: .gradient,
                                              color: SIMD3(0.36, 0.55, 0.78),
                                              colorBottom: SIMD3(0.58, 0.72, 0.88))
    static let studioGray = BackgroundOptions(kind: .gradient,
                                              color: SIMD3(0.58, 0.58, 0.60),
                                              colorBottom: SIMD3(0.74, 0.74, 0.76))

    var isKeep: Bool { kind == .keep }
    var needsSegmentation: Bool { kind != .keep }
}

// MARK: - ID photo specs

enum IDPhotoSpec: String, Codable, CaseIterable, Identifiable {
    case oneInch        // 一寸 25×35mm
    case smallOneInch   // 小一寸 22×32mm
    case twoInch        // 二寸 35×49mm
    case smallTwoInch   // 小二寸 35×45mm
    case passport       // 护照 33×48mm
    case visaUS         // 美签 51×51mm
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneInch: return "一寸 25×35"
        case .smallOneInch: return "小一寸 22×32"
        case .twoInch: return "二寸 35×49"
        case .smallTwoInch: return "小二寸 35×45"
        case .passport: return "护照 33×48"
        case .visaUS: return "美签 51×51"
        case .custom: return "自定义"
        }
    }

    /// Millimetres, portrait orientation.
    var millimeters: CGSize {
        switch self {
        case .oneInch: return CGSize(width: 25, height: 35)
        case .smallOneInch: return CGSize(width: 22, height: 32)
        case .twoInch: return CGSize(width: 35, height: 49)
        case .smallTwoInch: return CGSize(width: 35, height: 45)
        case .passport: return CGSize(width: 33, height: 48)
        case .visaUS: return CGSize(width: 51, height: 51)
        case .custom: return CGSize(width: 25, height: 35)
        }
    }

    /// Pixel size at a given print resolution (300 dpi by default).
    func pixelSize(dpi: Double = 300) -> CGSize {
        let mm = millimeters
        return CGSize(width: (mm.width / 25.4 * dpi).rounded(),
                      height: (mm.height / 25.4 * dpi).rounded())
    }

    /// Head-height ratio required by ID photo standards (head from crown to chin).
    var headHeightRatio: Double {
        switch self {
        case .passport: return 0.72
        case .visaUS: return 0.69
        default: return 0.66
        }
    }
}

// MARK: - Delivery

struct DeliveryOptions: Codable, Equatable {
    enum ColorSpace: String, Codable, CaseIterable {
        case sRGB
        case displayP3
        var label: String { self == .sRGB ? "sRGB（网页/常规冲印）" : "Display P3（广色域印刷）" }
    }
    enum Format: String, Codable, CaseIterable {
        case jpeg
        case heic
        case tiff
        var label: String {
            switch self { case .jpeg: return "JPEG"; case .heic: return "HEIC"; case .tiff: return "TIFF" }
        }
        var fileExtension: String {
            switch self { case .jpeg: return "jpg"; case .heic: return "heic"; case .tiff: return "tif" }
        }
    }

    var webLongEdge: Int = 2048
    var webQuality: Double = 0.92
    var webFormat: Format = .jpeg
    var includeFullResolution: Bool = true
    var printFormat: Format = .jpeg
    var printQuality: Double = 0.98
    var colorSpace: ColorSpace = .sRGB
    var watermarkText: String? = nil
    var watermarkOpacity: Double = 0.35
    var watermarkCorner: WatermarkCorner = .bottomRight
    var filePrefix: String = "OPA"
    var keepMetadata: Bool = true
    var includeManifest: Bool = true
    var includeProofingPage: Bool = true
    var idPhotoSheet: Bool = false          // 六寸相纸排版（多张证件照拼一张）

    enum WatermarkCorner: String, Codable, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft
    }
}

struct DeliveryManifestEntry: Codable, Equatable {
    var sourceName: String
    var fileName: String
    var kind: String          // web / full / id
    var width: Int
    var height: Int
    var bytes: Int
    var checksum: String      // CRC32 hex
}

struct DeliveryManifest: Codable, Equatable {
    var jobName: String
    var createdAt: Date
    var presetID: String
    var look: String
    var entries: [DeliveryManifestEntry]
    var anchorFrameCount: Int
    var appVersion: String
}

// MARK: - Batch model

enum BatchPhotoStatus: String, Codable {
    case pending
    case analysing
    case processed      // 机器初修完成，待人审
    case approved       // 人审通过，可交付
    case rejected       // 人审淘汰（闭眼/糊片）
    case failed

    var label: String {
        switch self {
        case .pending: return "待处理"
        case .analysing: return "分析中"
        case .processed: return "待审核"
        case .approved: return "已通过"
        case .rejected: return "已淘汰"
        case .failed: return "失败"
        }
    }
}

/// One photo inside a batch. The original bytes are never modified; the result
/// and every manual revision live next to them (same scheme as RetouchVersionStore).
final class BatchPhoto: ObservableObject, Identifiable {
    let id = UUID()
    let fileName: String
    let originalData: Data
    @Published var status: BatchPhotoStatus = .pending
    @Published var adjustments = RetouchAdjustments()
    @Published var resultURL: URL?
    @Published var thumbnail: UIImage?
    @Published var report: RetouchQualityReport?
    @Published var spotsFound: Int = 0
    @Published var spotsRemaining: Int = 0
    @Published var errorMessage: String?
    @Published var processingSeconds: Double = 0
    /// 本地精修完成后由 `AIEditAdvisor` 产出的 AI 修图建议；未精修或未补算时为 nil。
    @Published var advice: AIEditAdvice?

    init(fileName: String, originalData: Data) {
        self.fileName = fileName
        self.originalData = originalData
    }

    /// 有未合规项 → 这张建议再做一轮 AI 修图。
    var needsAI: Bool { (advice?.failureCount ?? 0) > 0 }

    var originalImage: UIImage? { UIImage(data: originalData) }
    var displayImage: UIImage? {
        if let resultURL, let image = UIImage(contentsOfFile: resultURL.path) { return image }
        return thumbnail ?? originalImage
    }
}

/// One shoot = one batch. `anchor` is computed once from all frames and then
/// applied to every photo so the delivered set is colour-consistent.
final class BatchJob: ObservableObject, Identifiable {
    let id = UUID()
    @Published var name: String
    @Published var photos: [BatchPhoto]
    @Published var anchor: ShootAnchor?
    @Published var isRunning: Bool = false
    @Published var progress: Double = 0
    @Published var lastError: String?

    init(name: String, photos: [BatchPhoto]) {
        self.name = name
        self.photos = photos
    }

    var processedCount: Int { photos.filter { $0.status == .processed || $0.status == .approved }.count }
    var approvedCount: Int { photos.filter { $0.status == .approved }.count }
    var failedCount: Int { photos.filter { $0.status == .failed }.count }
    var pendingCount: Int { photos.filter { $0.status == .pending }.count }

    var canDeliver: Bool { approvedCount > 0 }
}
