import Foundation
import CryptoKit
import Darwin

struct RetouchRevision: Codable, Identifiable {
    let id: UUID
    let job: UUID
    let kind: String
    let filename: String
    let sha256: String
    let createdAt: Date
    let needsHumanReview: Bool
}

/// Atomic manifest snapshots; source originals and completed revisions remain immutable.
final class RetouchRecovery {
    private let fm = FileManager.default
    private var root: URL { fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CommercialRetouch", isDirectory: true) }
    func hasReservedAICall(job: UUID) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(job.uuidString).appendingPathComponent("ai-call-reserved").path)
    }
    /// An exclusive, durable reservation. A failed or interrupted request is never retried automatically.
    func reserveAICall(job: UUID) throws -> Bool {
        let folder = root.appendingPathComponent(job.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: folder.appendingPathComponent("original.bin").path) else { throw RetouchFailure.invalidImage }
        let path = folder.appendingPathComponent("ai-call-reserved").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return true
    }
    func revisions(job: UUID) throws -> [RetouchRevision] {
        let file = root.appendingPathComponent(job.uuidString).appendingPathComponent("revisions.json")
        guard fm.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([RetouchRevision].self, from: Data(contentsOf: file))
    }
    @discardableResult func record(job: UUID, url: URL, kind: String, needsHumanReview: Bool) throws -> RetouchRevision {
        guard ["local", "seedream", "fusion"].contains(kind), url.deletingLastPathComponent().lastPathComponent == job.uuidString else { throw RetouchFailure.invalidExport }
        let bytes = try Data(contentsOf: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = RetouchRevision(id: UUID(), job: job, kind: kind, filename: url.lastPathComponent, sha256: digest, createdAt: Date(), needsHumanReview: needsHumanReview)
        var list = try revisions(job: job)
        list.append(revision)
        let manifest = url.deletingLastPathComponent().appendingPathComponent("revisions.json")
        try JSONEncoder().encode(list).write(to: manifest, options: .atomic)
        return revision
    }
    func validRevisions(job: UUID) throws -> [RetouchRevision] {
        try revisions(job: job).filter { entry in
            let file = root.appendingPathComponent(job.uuidString).appendingPathComponent(entry.filename)
            guard let data = try? Data(contentsOf: file) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256
        }
    }
    func jobs() -> [UUID] {
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }
}
