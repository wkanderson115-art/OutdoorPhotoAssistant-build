import CoreImage
import CoreML
import CoreVideo
import Foundation

/// On-device DirectorNet (scene + framing quality + suggested camera move).
///
/// The model is optional: if `DirectorNet.mlmodelc` is not in the app bundle, `isAvailable`
/// is false and the app falls back to the rule-based director. Drag `DirectorNet.mlpackage`
/// (exported by tools/director_lab) into the Xcode project; Xcode compiles it into the bundle.
/// Models exported with `--smoke` (pipeline test only) are refused on purpose.
final class DirectorMLModel {
    static let shared = DirectorMLModel()
    static let inputSize = 224
    static let fallbackLabels = ["人物", "风景", "海边", "日落", "夜景", "建筑", "花草", "汽车"]

    let isAvailable: Bool
    let statusText: String

    private let model: MLModel?
    private let labels: [String]
    private let context = CIContext()
    private let lock = NSLock()
    private var scratch: CVPixelBuffer?

    private init() {
        let loaded = Self.load()
        model = loaded.model
        labels = loaded.labels
        statusText = loaded.status
        isAvailable = loaded.model != nil
    }

    private static func load() -> (model: MLModel?, labels: [String], status: String) {
        guard let url = Bundle.main.url(forResource: "DirectorNet", withExtension: "mlmodelc") else {
            return (nil, fallbackLabels, "未内置 DirectorNet 模型：使用规则导演")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            if metadata["stage"] == "smoke" {
                return (nil, fallbackLabels, "DirectorNet 是管线测试模型（smoke），已忽略")
            }
            let labels = metadata["labels"].map { $0.split(separator: ",").map(String.init) } ?? fallbackLabels
            return (model, labels.isEmpty ? fallbackLabels : labels, "DirectorNet 已加载")
        } catch {
            return (nil, fallbackLabels, "DirectorNet 加载失败：" + error.localizedDescription)
        }
    }

    /// `buffer` must already be upright (what the user sees); its own width/height give the aspect,
    /// so the same call works for portrait and landscape frames.
    func predict(buffer: CVPixelBuffer) -> DirectorMLOutput? {
        guard let model else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let input = resized(buffer),
              let aspect = try? MLMultiArray(shape: [1, 1], dataType: .float32) else { return nil }
        aspect[0] = NSNumber(value: Float(Double(width) / Double(height)))
        guard let features = try? MLDictionaryFeatureProvider(dictionary: [
                  "image": MLFeatureValue(pixelBuffer: input),
                  "aspect": MLFeatureValue(multiArray: aspect)]),
              let output = try? model.prediction(from: features),
              let scene = output.featureValue(for: "scene")?.multiArrayValue,
              let quality = output.featureValue(for: "quality")?.multiArrayValue,
              let shift = output.featureValue(for: "shift")?.multiArrayValue,
              scene.count == labels.count, quality.count >= 1, shift.count >= 3 else { return nil }
        let probabilities = (0..<scene.count).map { scene[$0].doubleValue }
        guard let best = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) else { return nil }
        let result = DirectorMLOutput(scene: labels[best], sceneConfidence: probabilities[best],
                                      quality: min(1, max(0, quality[0].doubleValue)),
                                      dx: shift[0].doubleValue, dy: shift[1].doubleValue, dz: shift[2].doubleValue)
        return [result.sceneConfidence, result.quality, result.dx, result.dy, result.dz].allSatisfy { $0.isFinite } ? result : nil
    }

    private func resized(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if scratch == nil {
            var created: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, Self.inputSize, Self.inputSize,
                                kCVPixelFormatType_32BGRA, attributes, &created)
            scratch = created
        }
        guard let target = scratch else { return nil }
        let image = CIImage(cvPixelBuffer: source)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let scale = CGAffineTransform(scaleX: CGFloat(Self.inputSize) / image.extent.width,
                                      y: CGFloat(Self.inputSize) / image.extent.height)
        context.render(image.transformed(by: scale), to: target)
        return target
    }
}
