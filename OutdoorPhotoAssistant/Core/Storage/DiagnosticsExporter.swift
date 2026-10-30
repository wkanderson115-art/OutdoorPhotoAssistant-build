import Foundation
import UIKit
import ImageIO

// MARK: - 快照值类型

/// 最近一次拍摄的诊断快照（纯值类型，便于 JSON 序列化）。
struct ShotDiagnostics: Codable, Equatable {
    var recordedAt: Date
    var exposure: Int
    var sharpness: Int
    var composition: Int
    var score: Int
    var scene: String
    var filter: String
    var zoom: Double
    /// 例如 "ISO 320 · 1/125s"
    var cameraTelemetry: String
    var directorSummary: String
    /// 每条 "domain|rule|observation|action"
    var directorEvidence: [String]
    var appVersion: String
    var buildNumber: String
}

/// 最近一次精修的诊断快照。
struct RetouchDiagnostics: Codable, Equatable {
    var recordedAt: Date
    var presetID: String
    var look: String
    var strength: Double
    var passed: Bool
    var metrics: [String: Double]
    var notes: [String]
    var lightroomCore: Bool
    var lightroomAmount: Double
    /// "4032x3024"
    var imageSize: String
}

// MARK: - 全局记录点

/// 拍摄页 / 精修页往里写，设置页导出时读。
///
/// 线程安全：拍摄流程会在后台队列写图片，因此所有状态读写都走同一把 `NSLock`；
/// 图片降采样放在独立的串行队列里做，导出前用 `flushPendingImages()` 收口。
final class DiagnosticsCenter {

    static let shared = DiagnosticsCenter()

    private init() {}

    private let lock = NSLock()
    /// 串行队列：保证降采样任务按提交顺序完成，导出侧 `sync` 一次即可全部收口。
    private let imageQueue = DispatchQueue(label: "com.outdoorphotoassistant.diagnostics.images", qos: .utility)
    private static let journalCapacity = 80

    // NSDateFormatter 在 iOS 7+ 对格式化操作是线程安全的。
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var shotStorage: ShotDiagnostics?
    private var originalJPEGStorage: Data?
    private var styledJPEGStorage: Data?
    private var retouchStorage: RetouchDiagnostics?
    private var journalStorage: [String] = []

    // MARK: 写入

    /// 记录最近一次拍摄。图片走后台降采样（长边 ≤1600、JPEG 0.7），不阻塞拍摄流程。
    func recordShot(_ shot: ShotDiagnostics, originalJPEG: Data?, styledJPEG: Data?) {
        lock.lock()
        shotStorage = shot
        originalJPEGStorage = nil
        styledJPEGStorage = nil
        lock.unlock()

        log("记录拍摄：分数 \(shot.score) · \(shot.scene) · \(shot.filter) · \(shot.cameraTelemetry)")

        guard originalJPEG != nil || styledJPEG != nil else { return }
        let original = originalJPEG
        let styled = styledJPEG
        imageQueue.async { [weak self] in
            let smallOriginal = DiagnosticsImageCodec.downscaledJPEG(from: original)
            let smallStyled = DiagnosticsImageCodec.downscaledJPEG(from: styled)
            guard let self = self else { return }
            self.lock.lock()
            self.originalJPEGStorage = smallOriginal
            self.styledJPEGStorage = smallStyled
            self.lock.unlock()
        }
    }

    /// 记录最近一次拍摄（成片直接传 UIImage 的重载）。
    ///
    /// 拍摄页 `finish()` 里那张 12MP 成片如果先编码成 JPEG 再传进来，会在主线程
    /// 多付一次 100–250 ms 的全尺寸编码；这个重载把「缩到 1600 + 编码」整段放到
    /// 内部串行队列上，主线程只做一次赋值。
    func recordShot(_ shot: ShotDiagnostics, originalJPEG: Data?, styledImage: UIImage?) {
        lock.lock()
        shotStorage = shot
        originalJPEGStorage = nil
        styledJPEGStorage = nil
        lock.unlock()

        log("记录拍摄：分数 \(shot.score) · \(shot.scene) · \(shot.filter) · \(shot.cameraTelemetry)")

        guard originalJPEG != nil || styledImage != nil else { return }
        let original = originalJPEG
        let styled = styledImage
        imageQueue.async { [weak self] in
            let smallOriginal = DiagnosticsImageCodec.downscaledJPEG(from: original)
            let smallStyled = DiagnosticsImageCodec.downscaledJPEG(from: styled)
            guard let self = self else { return }
            self.lock.lock()
            self.originalJPEGStorage = smallOriginal
            self.styledJPEGStorage = smallStyled
            self.lock.unlock()
        }
    }

    /// 记录最近一次精修。
    func recordRetouch(_ retouch: RetouchDiagnostics) {        lock.lock()
        retouchStorage = retouch
        lock.unlock()

        let verdict = retouch.passed ? "通过" : "未通过"
        log("记录精修：\(retouch.look) · 强度 \(String(format: "%.2f", retouch.strength)) · 质检\(verdict) · \(retouch.imageSize)")
    }

    /// 环形日志，最多保留 80 条，供导出时附上事件时间线。
    /// 每条已经带 "HH:mm:ss" 前缀，`journal.txt` 直接逐行写出即可。
    func log(_ message: String) {
        let line = Self.clockFormatter.string(from: Date()) + "  " + message
        lock.lock()
        journalStorage.append(line)
        if journalStorage.count > Self.journalCapacity {
            journalStorage.removeFirst(journalStorage.count - Self.journalCapacity)
        }
        lock.unlock()
    }

    // MARK: 读取

    var lastShot: ShotDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        return shotStorage
    }

    var lastRetouch: RetouchDiagnostics? {
        lock.lock()
        defer { lock.unlock() }
        return retouchStorage
    }

    var journal: [String] {
        lock.lock()
        defer { lock.unlock() }
        return journalStorage
    }

    // MARK: 供导出器使用（仅本模块）

    /// 等后台降采样收尾。只在导出时（主线程）调用，不要从 `imageQueue` 内部调用。
    func flushPendingImages() {
        imageQueue.sync { }
    }

    /// 降采样后的原片 JPEG（≤1600、0.7）。
    var originalImageData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return originalJPEGStorage
    }

    /// 降采样后的成片 JPEG（≤1600、0.7）。
    var styledImageData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return styledJPEGStorage
    }
}

// MARK: - 错误

enum DiagnosticsError: LocalizedError {
    /// 还没有任何一次拍摄或精修记录
    case nothingToExport
    /// 落盘 / 序列化失败，附带中文原因
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .nothingToExport:
            return "还没有可导出的诊断数据：先拍一张照片，或跑一次本地精修。"
        case .storage(let reason):
            return reason
        }
    }
}

// MARK: - 导出器

/// 把最近一次拍摄 + 最近一次精修打包成 zip，写到临时目录，交给调用方用 ShareLink 分享。
final class DiagnosticsExporter {

    static let shared = DiagnosticsExporter()

    private init() {}

    /// 文件名时间戳（纯 ASCII，避免 zip 条目名乱码）。
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// 白名单：只导出这些 UserDefaults 键（都是有诊断价值、且与账号无关的数值/开关）。
    private static let settingsWhitelist: [String] = [
        // 精修 / Lightroom 核心
        "lightroomCore", "lightroomAmount", "lightroomImportedPresetID", "presetID",
        // 拍摄与风格
        "autoDirector", "directorFraming", "directorComposition", "quietDirector",
        "autoScene", "manualScene", "autoFilter", "manualFilter", "compositionStyle",
        "filterStrength", "autoComposition", "autoZoom", "autoCapture",
        // 画面效果
        "realtimeEffects", "liveBeauty", "liveBeautyStrength", "directorBlur", "portraitDepth",
        // 画质与保存
        "highQuality", "exportToSystemAlbum", "saveBoth", "showGrid",
        // 色谱（各色饱和度）
        "spectrum_red", "spectrum_orange", "spectrum_yellow", "spectrum_green",
        "spectrum_cyan", "spectrum_blue", "spectrum_purple",
        // 最近一次拍摄的指标（拍摄页写入）
        "lastShotExposure", "lastShotSharpness", "lastShotComposition", "lastShotDate"
    ]

    /// 敏感片段：键名里出现任何一个就绝不导出（纵深防御，将来误加白名单也能拦住）。
    /// 覆盖 API Key / token / secret / 口令 / 凭据 / 会话类键。
    private static let forbiddenFragments = [
        "key", "token", "secret", "password", "passwd", "credential", "auth", "cookie", "session"
    ]

    /// 条目写入顺序（manifest.json 恒在第一位，其余按此顺序，缺失的跳过）。
    private static let fileOrder = [
        "shot.json", "retouch.json", "journal.txt", "settings.json",
        "shot_original.jpg", "shot_styled.jpg"
    ]

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: 导出

    /// 生成 zip 到临时目录，返回文件 URL；调用方负责用 ShareLink 分享。
    @discardableResult
    func export() throws -> URL {
        let center = DiagnosticsCenter.shared
        // 先收口后台降采样，保证这次导出能带上图。
        center.flushPendingImages()

        guard center.lastShot != nil || center.lastRetouch != nil else {
            throw DiagnosticsError.nothingToExport
        }
        center.log("开始生成诊断包")

        let appVersion = Self.bundleValue("CFBundleShortVersionString")
        let buildNumber = Self.bundleValue("CFBundleVersion")

        var files: [String: Data] = [:]
        // 没有记录时写占位对象，导出本身不报错。
        files["shot.json"] = try jsonData(for: center.lastShot, missingMessage: "尚未拍摄")
        files["retouch.json"] = try jsonData(for: center.lastRetouch, missingMessage: "尚未精修")
        files["journal.txt"] = Data(journalText(from: center.journal).utf8)
        files["settings.json"] = try settingsJSON()
        if let original = center.originalImageData { files["shot_original.jpg"] = original }
        if let styled = center.styledImageData { files["shot_styled.jpg"] = styled }

        let manifest = Manifest(generatedAt: Date(),
                                appVersion: appVersion,
                                buildNumber: buildNumber,
                                device: Self.deviceSummary(),
                                items: ["manifest.json"] + Self.fileOrder.filter { files[$0] != nil })

        var builder = ZipArchiveBuilder()
        do {
            builder.addFile(name: "manifest.json", data: try encoder.encode(manifest))
        } catch {
            throw DiagnosticsError.storage("生成 manifest.json 失败：\(error.localizedDescription)")
        }
        for name in Self.fileOrder {
            if let data = files[name] {
                builder.addFile(name: name, data: data)
            }
        }
        let zipData = builder.finalize()

        let fileName = "opa-diagnostics-\(Self.stampFormatter.string(from: Date())).zip"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try zipData.write(to: url, options: .atomic)
        } catch {
            throw DiagnosticsError.storage("写入诊断包失败：\(error.localizedDescription)")
        }

        center.log("诊断包已生成：\(fileName) · \(zipData.count) 字节")
        return url
    }

    // MARK: 各部分内容

    private struct Manifest: Codable {
        var generatedAt: Date
        var appVersion: String
        var buildNumber: String
        var device: String
        var items: [String]
    }

    /// 快照缺失时的占位对象（例如 `{"missing": "尚未拍摄"}`）。
    private struct MissingSection: Codable {
        var missing: String
    }

    private func jsonData<T: Encodable>(for value: T?, missingMessage: String) throws -> Data {
        do {
            if let value = value {
                return try encoder.encode(value)
            }
            return try encoder.encode(MissingSection(missing: missingMessage))
        } catch {
            throw DiagnosticsError.storage("生成 JSON 失败：\(error.localizedDescription)")
        }
    }

    private func journalText(from lines: [String]) -> String {
        guard !lines.isEmpty else { return "（暂无事件记录）\n" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 设置快照：白名单 + 敏感键拦截，只收 Bool / Double / Int / String 四种标量。
    private func settingsJSON() throws -> Data {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in Self.settingsWhitelist {
            guard !Self.isSensitive(key) else { continue }
            guard let stored = defaults.object(forKey: key) else { continue }
            if let value = stored as? Bool {
                snapshot[key] = value
            } else if let value = stored as? Double {
                snapshot[key] = value
            } else if let value = stored as? Int {
                snapshot[key] = value
            } else if let value = stored as? String {
                snapshot[key] = value
            }
            // 其它类型（Data / URL / 数组 / 字典）一律不导，避免把凭据类对象带出去。
        }
        do {
            return try JSONSerialization.data(withJSONObject: snapshot,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw DiagnosticsError.storage("生成 settings.json 失败：\(error.localizedDescription)")
        }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return forbiddenFragments.contains { lowered.contains($0) }
    }

    private static func bundleValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "-"
    }

    private static func deviceSummary() -> String {
        let device = UIDevice.current
        return "\(device.model) · \(device.systemName) \(device.systemVersion)"
    }
}

// MARK: - 图片降采样

/// 原图 / 成片统一缩到长边 ≤1600 再压 JPEG 0.7，避免诊断包过大（目标 <3MB）。
///
/// 优先走 ImageIO 的缩略图接口：不整图解码 12MP，内存占用最省；
/// 缩略图失败时退回 UIKit 重绘兜底，全程不出现强制解包。
enum DiagnosticsImageCodec {

    static let maxLongEdge: CGFloat = 1600
    static let compressionQuality: CGFloat = 0.7

    static func downscaledJPEG(from data: Data?) -> Data? {
        guard let data = data, !data.isEmpty else { return nil }
        // UIImage(data:) 只解析文件头拿尺寸，不整图解码；JPEG 的 scale 为 1，size 即像素尺寸。
        guard let probe = UIImage(data: data) else { return nil }
        let pixelWidth = probe.size.width
        let pixelHeight = probe.size.height
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        if max(pixelWidth, pixelHeight) > maxLongEdge {
            if let thumbnail = thumbnailJPEG(from: data) {
                return thumbnail
            }
            // 兜底：缩略图接口失败时按比例重绘（会整图解码，但保证一定出图）
            return resizedJPEG(probe)
        }
        return probe.jpegData(compressionQuality: compressionQuality)
    }

    /// 从已解码的 UIImage 直接降采样编码。
    ///
    /// 为什么需要它：拍摄页 `finish()` 手上已经有一张 12MP 的成片 UIImage，
    /// 如果先 `jpegData(quality: 0.9)`（100–250 ms，主线程）再交给这里缩到 1600，
    /// 等于把同一张图编码两次。直接传图进来，编码只发生一次，而且发生在内部串行队列上。
    static func downscaledJPEG(from image: UIImage?) -> Data? {
        guard let image = image else { return nil }
        return resizedJPEG(image)
    }

    /// ImageIO 缩略图：不整图解码 12MP，内存占用最省。
    private static func thumbnailJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        // 走 UIKit 的 JPEG 编码器（内部同样是 ImageIO），避免手写 CGImageDestination 的数据桥接。
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: compressionQuality)
    }

    private static func resizedJPEG(_ image: UIImage) -> Data? {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return nil }
        let longEdge = max(width, height)
        let scale = longEdge > maxLongEdge ? maxLongEdge / longEdge : 1
        let target = CGSize(width: max(1, (width * scale).rounded()),
                            height: max(1, (height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: compressionQuality)
    }
}
