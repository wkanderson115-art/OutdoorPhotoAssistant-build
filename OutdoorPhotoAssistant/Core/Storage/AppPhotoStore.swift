import Foundation
import ImageIO
import UIKit

struct PhotoVersion: Codable, Identifiable, Equatable {
    let id: UUID
    var cloudJobID: UUID? = nil
    let kind: String // local / seedream
    let fileName: String
    let thumbnailName: String
    let createdAt: Date
    let sourceAssetID: String?
    let prompt: String?
    let model: String?
    var outputKey: String? = nil
    var title: String { kind == "seedream" ? "AI修图 · " + createdAt.formatted(date: .omitted, time: .shortened) : "本地成片 · " + createdAt.formatted(date: .omitted, time: .shortened) }
}
struct StoredAdvice: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceAssetID: String
    let userInstruction: String
    var policyVersion: String? = nil
    let advice: PhotoAdvice
    let createdAt: Date
    let model: String
    let usage: APIUsage
}
struct PhotoCloudJob: Codable, Identifiable, Equatable {
    let id: UUID
    let provider: String
    var transport: String? = nil // direct-v1; nil denotes an older version
    let sourceAssetID: String
    let startedAt: Date
    var prompt: String? = nil
    var model: String? = nil
    var resultURL: String? = nil
    var requestID: String? = nil
    var outputKey: String? = nil
    var state: String // running / completed / failed / interrupted
    var message: String?
    var stateTitle: String {
        switch state {
        case "running": return "进行中"
        case "completed": return "已完成"
        case "interrupted": return "上次中断"
        default: return "未完成"
        }
    }
}
struct AppPhotoRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    let originalName: String
    let originalThumbnail: String
    var revision: Int = 0
    var updatedAt: Date
    var versions: [PhotoVersion]
    var advice: [StoredAdvice]
    var jobs: [PhotoCloudJob]
    var preferredAssetID: String { versions.last?.id.uuidString ?? "original" }
    func fileName(for assetID: String) -> String? {
        assetID == "original" ? originalName : versions.first(where: { $0.id.uuidString == assetID })?.fileName
    }
    func thumbnailName(for assetID: String) -> String? {
        assetID == "original" ? originalThumbnail : versions.first(where: { $0.id.uuidString == assetID })?.thumbnailName
    }
}

enum PhotoImagePreparation {
    /// ImageIO applies orientation and decodes only the requested size. JPEG encoding
    /// from the thumbnail strips GPS/EXIF from the upload while the local original stays intact.
    static func jpeg(from url: URL, maximumDimension: Int, quality: CGFloat) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw CloudAPIError.invalidImage }
        return try jpeg(source: source, maximumDimension: maximumDimension, quality: quality)
    }
    static func thumbnail(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw CloudAPIError.invalidImage }
        return try jpeg(source: source, maximumDimension: 512, quality: 0.82)
    }
    /// Encode a still as HEIC (~half the size of JPEG at equal quality) and
    /// fall back to JPEG on any failure. The caller picks the extension that
    /// matches the returned bytes so the on-disk name never lies.
    static func efficientEncode(_ image: UIImage, quality: CGFloat = 0.85) -> (data: Data, ext: String) {
        if let heic = heic(image, quality: quality) {
            return (heic, ".heic")
        }
        if let jpg = image.jpegData(compressionQuality: min(0.95, max(0.7, quality))) {
            return (jpg, ".jpg")
        }
        return (Data(), ".jpg")
    }
    private static func heic(_ image: UIImage, quality: CGFloat) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let container = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(container, "public.heic" as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        props[kCGImagePropertyOrientation] = PhotoPostProcessor.exifOrientation(image.imageOrientation)
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (container as Data) : nil
    }
    private static func jpeg(source: CGImageSource, maximumDimension: Int, quality: CGFloat) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: quality) else { throw CloudAPIError.invalidImage }
        return data
    }
    static func validateGenerated(_ data: Data) throws {
        guard data.count <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 24_000_000 else { throw CloudAPIError.invalidImage }
    }

    /// Original capture date used for gallery sorting and Photos export. Reading
    /// only EXIF/TIFF time fields avoids carrying GPS into generated versions.
    static func captureDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

/// All filesystem operations are serialized; each photo is a directory with atomic metadata.
/// Partial/orphan files never appear as new gallery records without committed metadata.
final class AppPhotoStore {
    let root: URL
    private let queue = DispatchQueue(label: "opa.app-gallery.disk", qos: .utility)
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OutdoorPhotoAssistant/Gallery", isDirectory: true)
    }
    func fileURL(photoID: UUID, name: String) -> URL {
        root.appendingPathComponent(photoID.uuidString, isDirectory: true).appendingPathComponent(name)
    }
    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
    private func read(_ id: UUID) throws -> AppPhotoRecord {
        try JSONDecoder().decode(AppPhotoRecord.self, from: Data(contentsOf: fileURL(photoID: id, name: "record.json")))
    }
    private func commit(_ record: inout AppPhotoRecord) throws {
        record.revision += 1
        try JSONEncoder().encode(record).write(to: fileURL(photoID: record.id, name: "record.json"), options: .atomic)
    }
    func deletePhoto(_ id: UUID) async throws {
        try await run {
            let record = try self.read(id)
            guard !record.jobs.contains(where: { $0.state == "running" }) else {
                throw NSError(domain: "Gallery", code: 1, userInfo: [NSLocalizedDescriptionKey: "请等待当前图片任务结束后再删除。"])
            }
            try FileManager.default.removeItem(at: self.root.appendingPathComponent(id.uuidString, isDirectory: true))
        }
    }
    func records(recoverInterrupted: Bool = false) async throws -> [AppPhotoRecord] {
        try await run {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let dirs = try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)
            var result: [AppPhotoRecord] = []
            for dir in dirs {
                guard let id = UUID(uuidString: dir.lastPathComponent), var record = try? self.read(id) else { continue }
                if recoverInterrupted {
                    var changed = false
                    for i in record.jobs.indices where record.jobs[i].state == "running" {
                        record.jobs[i].state = "interrupted"
                        record.jobs[i].message = record.jobs[i].transport == "direct-v1" && record.jobs[i].resultURL != nil ? "已有图片链接，可仅重试下载；不会再次生成。" : "上次任务被中断，平台可能已计费；直连版不会自动重发，也不能查询旧后端任务。"
                        changed = true
                    }
                    if changed { try self.commit(&record) }
                }
                result.append(record)
            }
            return result.sorted { $0.capturedAt > $1.capturedAt }
        }
    }
    func saveCapture(id: UUID, originalData: Data, localData: Data, localExtension: String = ".jpg") async throws -> AppPhotoRecord {
        try await run {
            let folder = self.root.appendingPathComponent(id.uuidString, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: self.fileURL(photoID: id, name: "record.json").path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var newFiles: [URL] = []
            do {
                var record: AppPhotoRecord
                if exists { record = try self.read(id) }
                else {
                    let original = self.fileURL(photoID: id, name: "original.data")
                    try originalData.write(to: original, options: .atomic); newFiles.append(original)
                    let thumb = self.fileURL(photoID: id, name: "original-thumb.jpg")
                    try PhotoImagePreparation.thumbnail(originalData).write(to: thumb, options: .atomic); newFiles.append(thumb)
                    record = AppPhotoRecord(id: id, capturedAt: PhotoImagePreparation.captureDate(originalData) ?? Date(), originalName: "original.data", originalThumbnail: "original-thumb.jpg",
                                            updatedAt: Date(), versions: [], advice: [], jobs: [])
                }
                let version = PhotoVersion(id: UUID(), kind: "local", fileName: UUID().uuidString + localExtension, thumbnailName: UUID().uuidString + "-thumb.jpg",
                                           createdAt: Date(), sourceAssetID: "original", prompt: nil, model: nil)
                for (name, bytes) in [(version.fileName, localData), (version.thumbnailName, try PhotoImagePreparation.thumbnail(localData))] {
                    let url = self.fileURL(photoID: id, name: name)
                    try bytes.write(to: url, options: .atomic); newFiles.append(url)
                }
                record.versions.append(version); record.updatedAt = Date()
                try self.commit(&record)
                return record
            } catch {
                newFiles.forEach { try? FileManager.default.removeItem(at: $0) }
                if !exists { try? FileManager.default.removeItem(at: folder) }
                throw error
            }
        }
    }
    func preparedUpload(photoID: UUID, assetID: String, maximumDimension: Int) async throws -> Data {
        try await run {
            let record = try self.read(photoID)
            guard let name = record.fileName(for: assetID) else { throw CloudAPIError.invalidImage }
            let data = try PhotoImagePreparation.jpeg(from: self.fileURL(photoID: photoID, name: name), maximumDimension: maximumDimension, quality: 0.9)
            guard data.count <= 15 * 1024 * 1024 else { throw CloudAPIError.oversized }
            return data
        }
    }
    func preparedExport(photoID: UUID, assetID: String) async throws -> (data: Data, capturedAt: Date) {
        try await run {
            let record = try self.read(photoID)
            guard let name = record.fileName(for: assetID) else { throw CloudAPIError.invalidImage }
            return (try Data(contentsOf: self.fileURL(photoID: photoID, name: name)), record.capturedAt)
        }
    }
    func addAdvice(photoID: UUID, value: StoredAdvice) async throws -> AppPhotoRecord {
        try await run {
            var record = try self.read(photoID)
            guard record.fileName(for: value.sourceAssetID) != nil else { throw CloudAPIError.invalidImage }
            record.advice.append(value); record.updatedAt = Date(); try self.commit(&record)
            return record
        }
    }
    func addGenerated(photoID: UUID, sourceAssetID: String, data: Data, prompt: String, model: String, cloudJobID: UUID? = nil) async throws -> AppPhotoRecord {
        try await run {
            try PhotoImagePreparation.validateGenerated(data)
            var record = try self.read(photoID)
            guard record.fileName(for: sourceAssetID) != nil else { throw CloudAPIError.invalidImage }
            if let cloudJobID, record.versions.contains(where: { $0.cloudJobID == cloudJobID }) { return record }
            let version = PhotoVersion(id: UUID(), cloudJobID: cloudJobID, kind: "seedream", fileName: UUID().uuidString + ".image", thumbnailName: UUID().uuidString + "-thumb.jpg",
                                       createdAt: Date(), sourceAssetID: sourceAssetID, prompt: prompt, model: model)
            let imageURL = self.fileURL(photoID: photoID, name: version.fileName)
            let thumbURL = self.fileURL(photoID: photoID, name: version.thumbnailName)
            do {
                try data.write(to: imageURL, options: .atomic)
                try PhotoImagePreparation.thumbnail(data).write(to: thumbURL, options: .atomic)
                record.versions.append(version); record.updatedAt = Date(); try self.commit(&record)
                return record
            } catch {
                try? FileManager.default.removeItem(at: imageURL); try? FileManager.default.removeItem(at: thumbURL)
                throw error
            }
        }
    }
    func beginJob(photoID: UUID, provider: String, sourceAssetID: String, prompt: String? = nil, model: String? = nil) async throws -> (AppPhotoRecord, UUID) {
        try await run {
            var record = try self.read(photoID)
            guard !record.jobs.contains(where: { $0.state == "running" }) else {
                throw NSError(domain: "CloudJob", code: 1, userInfo: [NSLocalizedDescriptionKey: "这张照片已有任务进行中，请等待完成。"])
            }
            let job = PhotoCloudJob(id: UUID(), provider: provider, transport: "direct-v1", sourceAssetID: sourceAssetID, startedAt: Date(), prompt: prompt, model: model, state: "running", message: nil)
            record.jobs.append(job); record.updatedAt = Date(); try self.commit(&record)
            return (record, job.id)
        }
    }
    func saveJobResult(photoID: UUID, jobID: UUID, url: String, requestID: String?) async throws -> AppPhotoRecord {
        try await run {
            _ = try CloudHTTP.safeImageURL(url)
            var record = try self.read(photoID)
            guard let i = record.jobs.firstIndex(where: { $0.id == jobID }) else { throw CloudAPIError.invalidResponse }
            record.jobs[i].resultURL = url; record.jobs[i].requestID = requestID
            record.updatedAt = Date(); try self.commit(&record)
            return record
        }
    }
    func resumeDownload(photoID: UUID, jobID: UUID) async throws -> AppPhotoRecord {
        try await run {
            var record = try self.read(photoID)
            guard !record.jobs.contains(where: { $0.state == "running" }),
                  let i = record.jobs.firstIndex(where: { $0.id == jobID }),
                  record.jobs[i].resultURL != nil else { throw CloudAPIError.invalidResponse }
            record.jobs[i].state = "running"; record.jobs[i].message = "仅下载已有图片链接，没有新模型请求。"
            record.updatedAt = Date(); try self.commit(&record)
            return record
        }
    }
    func finishJob(photoID: UUID, jobID: UUID, state: String, message: String?) async throws -> AppPhotoRecord {
        try await run {
            var record = try self.read(photoID)
            if let index = record.jobs.firstIndex(where: { $0.id == jobID }) {
                record.jobs[index].state = state; record.jobs[index].message = message
            }
            record.updatedAt = Date(); try self.commit(&record)
            return record
        }
    }
}
