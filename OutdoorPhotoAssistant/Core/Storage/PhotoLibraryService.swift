import Combine
import Foundation
import ImageIO
import Photos
import UIKit

/// The in-app gallery contains only this app's captures and their local/cloud versions.
/// It never requires permission to read the user's entire system photo library.
final class PhotoLibraryService: ObservableObject {
    @Published private(set) var records: [AppPhotoRecord] = []
    @Published var lastSaveError: String?
    @Published var lastExportError: String?
    let store = AppPhotoStore()
    private var didLoad = false

    init() { load(recoverInterrupted: true) }
    func loadIfNeeded() { if !didLoad { load() } }
    func load(recoverInterrupted: Bool = false) {
        didLoad = true
        Task {
            do {
                let items = try await store.records(recoverInterrupted: recoverInterrupted)
                await MainActor.run { items.forEach { self.publish($0) }; self.lastSaveError = nil }
            } catch {
                await MainActor.run { self.lastSaveError = "无法读取本机图库：" + error.localizedDescription }
            }
        }
    }
    @MainActor private func publish(_ record: AppPhotoRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            guard records[i].revision <= record.revision else { return }
            records[i] = record
        }
        else { records.append(record) }
        records.sort { $0.capturedAt > $1.capturedAt }
    }
    /// The original is always retained locally; keepOriginal only controls optional system export.
    func saveShot(originalData: Data, styledImage: UIImage, keepOriginal: Bool = true,
                  photoID: UUID? = nil, completion: ((Bool) -> Void)? = nil) {
        let id = photoID ?? UUID()
        let exports = UserDefaults.standard.bool(forKey: "exportToSystemAlbum")
        Task {
            do {
                let encoded = await Task.detached(priority: .utility) {
                    PhotoImagePreparation.efficientEncode(styledImage, quality: 0.85)
                }.value
                let record = try await store.saveCapture(id: id, originalData: originalData, localData: encoded.data, localExtension: encoded.ext)
                await MainActor.run { self.publish(record); self.lastSaveError = nil; completion?(true) }
                if exports {
                    do {
                        let data = keepOriginal ? [originalData, encoded.data] : [encoded.data]
                        try await Self.exportData(data.map { ExportImage(data: $0, fallbackDate: record.capturedAt) })
                        await MainActor.run { self.lastExportError = nil }
                    } catch {
                        await MainActor.run { self.lastExportError = "图库已保存，系统相册导出失败：" + error.localizedDescription }
                    }
                }
            } catch {
                await MainActor.run { self.lastSaveError = "本机图库保存失败：" + error.localizedDescription; completion?(false) }
            }
        }
    }
    func saveAdvice(photoID: UUID, value: StoredAdvice) async throws {
        let record = try await store.addAdvice(photoID: photoID, value: value)
        await MainActor.run { self.publish(record) }
    }
    func saveGenerated(photoID: UUID, sourceAssetID: String, data: Data, prompt: String, model: String, cloudJobID: UUID? = nil) async throws -> PhotoVersion {
        let record = try await store.addGenerated(photoID: photoID, sourceAssetID: sourceAssetID, data: data, prompt: prompt, model: model, cloudJobID: cloudJobID)
        await MainActor.run { self.publish(record) }
        guard let version = cloudJobID.flatMap({ id in record.versions.first(where: { $0.cloudJobID == id }) }) ?? record.versions.last else { throw CloudAPIError.invalidResponse }
        return version
    }
    func beginJob(photoID: UUID, provider: String, sourceAssetID: String, prompt: String? = nil, model: String? = nil) async throws -> UUID {
        let (record, id) = try await store.beginJob(photoID: photoID, provider: provider, sourceAssetID: sourceAssetID, prompt: prompt, model: model)
        await MainActor.run { self.publish(record) }
        return id
    }
    func saveJobResult(photoID: UUID, jobID: UUID, url: String, requestID: String?) async throws {
        let record = try await store.saveJobResult(photoID: photoID, jobID: jobID, url: url, requestID: requestID)
        await MainActor.run { self.publish(record) }
    }
    func resumeDownload(photoID: UUID, jobID: UUID) async throws {
        let record = try await store.resumeDownload(photoID: photoID, jobID: jobID)
        await MainActor.run { self.publish(record) }
    }
    func finishJob(photoID: UUID, jobID: UUID, state: String, message: String? = nil) async {
        do {
            let record = try await store.finishJob(photoID: photoID, jobID: jobID, state: state, message: message)
            await MainActor.run { self.publish(record) }
        } catch {
            await MainActor.run { self.lastSaveError = "任务结果已处理，但任务记录写入失败：" + error.localizedDescription }
        }
    }
    @MainActor func deletePhoto(_ id: UUID) async throws {
        try await store.deletePhoto(id)
        records.removeAll { $0.id == id }
    }
    func export(photoID: UUID, assetID: String) async throws {
        let payload = try await store.preparedExport(photoID: photoID, assetID: assetID)
        try await Self.exportData([ExportImage(data: payload.data, fallbackDate: payload.capturedAt)])
    }
    private struct ExportImage {
        let data: Data
        let fallbackDate: Date?
    }
    private static func exportData(_ images: [ExportImage]) async throws {
        let status: PHAuthorizationStatus = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "PhotoExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "未获得系统相册写入权限；App图库中的照片仍然保留。"])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for image in images {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    if let source = CGImageSourceCreateWithData(image.data as CFData, nil), let type = CGImageSourceGetType(source) {
                        options.uniformTypeIdentifier = type as String
                    }
                    // Photos otherwise assigns the export moment to generated
                    // images. Prefer embedded EXIF and fall back to the gallery's
                    // original capture date so AI/fusion outputs stay on the same
                    // point in the user's timeline.
                    request.creationDate = PhotoImagePreparation.captureDate(image.data) ?? image.fallbackDate
                    request.addResource(with: .photo, data: image.data, options: options)
                }
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? CloudAPIError.invalidImage) }
            }
        }
    }
}
