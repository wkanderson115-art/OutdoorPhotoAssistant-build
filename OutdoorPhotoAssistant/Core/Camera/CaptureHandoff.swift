import Foundation
import UIKit
import ImageIO

/// Capture -> retouch handoff (V18, additive).
///
/// Two problems this solves, both found in the capture audit:
/// 1. the saved JPEG is already beauty-graded and colour-graded, so running the
///    retouch engine on it double-processes skin and tone;
/// 2. the capture side knows the scene, exposure and white balance, but the
///    retouch side re-derives everything, so a shoot's frames are not anchored to
///    each other.
///
/// This file writes a flat (ungraded) companion file plus a sidecar JSON. Nothing
/// existing changes: to switch it on, call `CaptureHandoff.write(...)` right after
/// the graded photo is saved, and make the studio batch importer prefer
/// `flatURL(for:)` when it exists (one guard in `importSelection`).
enum CaptureHandoff {
    static let flatSuffix = "_flat"
    static let sidecarExtension = "opa.json"

    struct Sidecar: Codable, Equatable {
        var originalFileName: String
        var flatFileName: String?
        var sceneLabel: String?
        var sceneConfidence: Double?
        var presetID: String?
        var exposure: Double?
        var whiteBalance: [Double]?
        var anchorHint: Bool
        var capturedAt: Date
        var appVersion: String
    }

    /// Writes `<name>_flat.jpg` (no grade, no beauty) next to the graded file and
    /// `<name>.opa.json` describing the frame. Best effort: every failure returns
    /// nil and leaves the caller's graded path untouched.
    @discardableResult
    static func write(flatImage: UIImage?, fileName: String, directory: URL,
                      sidecar: Sidecar) -> URL? {
        let fm = FileManager.default
        var flatURL: URL?
        if let flatImage, let data = flatImage.jpegData(compressionQuality: 0.98) {
            let candidate = directory.appendingPathComponent(baseName(fileName) + flatSuffix + ".jpg")
            do {
                try data.write(to: candidate, options: .atomic)
                flatURL = candidate
            } catch {
                flatURL = nil
            }
        }
        var record = sidecar
        record.flatFileName = flatURL?.lastPathComponent
        let jsonURL = directory.appendingPathComponent(baseName(fileName) + "." + sidecarExtension)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            try data.write(to: jsonURL, options: .atomic)
            _ = fm
            return jsonURL
        } catch {
            return nil
        }
    }

    /// Sidecar for a saved photo, if the capture side wrote one.
    static func sidecar(for fileName: String, in directory: URL) -> Sidecar? {
        let url = directory.appendingPathComponent(baseName(fileName) + "." + sidecarExtension)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Sidecar.self, from: data)
    }

    /// The flat companion that the retouch engine should consume, when present.
    static func flatURL(for fileName: String, in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(baseName(fileName) + flatSuffix + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Decodes a file for retouching, preferring the flat variant.
    static func imageForRetouch(fileName: String, in directory: URL) -> UIImage? {
        if let flat = flatURL(for: fileName, in: directory),
           let image = UIImage(contentsOfFile: flat.path) {
            return image
        }
        let graded = directory.appendingPathComponent(baseName(fileName))
        return UIImage(contentsOfFile: graded.path)
    }

    private static func baseName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }
}
