import Foundation
import CoreGraphics

/// A detected subject. Pure value type — only CoreGraphics, no UIKit/Vision —
/// so it can live next to the scoring helpers and be tested without a camera.
struct SubjectInfo: Equatable {
    var type: String = "未知"
    var rect: CGRect = .zero
    var confidence: Float = 0
}

/// Pure-logic scoring helpers split out of FrameAnalyzer so they can be
/// compiled and unit-tested without UIKit / Vision / a camera. Keeping these
/// functions here means the analysis layer's heuristics finally have a
/// runtime test path on macOS CI, not just a syntax check.
///
/// All inputs are plain structs and doubles; no CIImage, no CVPixelBuffer,
/// no UIImage, no VN*Observation. The live `FrameAnalyzer` calls these via
/// `FrameScoring.*`. `classifyScene` stays in FrameAnalyzer because it
/// depends on `VNClassificationObservation`.
struct FrameScoring {
    /// Composition score 0–100. Explained: subject position (rule of thirds),
    /// edge inset, horizon tilt and brightness centring.
    static func composeScore(subject: SubjectInfo, brightness: Double, horizon: Double) -> Int {
        guard subject.rect != .zero else { return 27 }

        var score = 0.0
        let midX = Double(subject.rect.midX)
        let midY = Double(subject.rect.midY)
        let spatial = DirectorCropImportance.score(x: midX, y: midY, ruleOfThirds: true)
        score += 40 * min(1, max(0, spatial / 1.41))

        let inset = Double(min(subject.rect.minX,
                               subject.rect.minY,
                               1 - subject.rect.maxX,
                               1 - subject.rect.maxY))
        score += 15 * min(1, max(0, inset / 0.08))
        score += 25 * max(0, 1 - abs(horizon) / 0.12)
        score += 20 * max(0, 1 - abs(brightness - 0.52) / 0.28)
        return max(0, min(100, Int(score.rounded())))
    }

    /// Map a brightness reading to a 0–100 exposure quality score.
    static func exposureQuality(_ brightness: Double) -> Int {
        if brightness < 0.10 || brightness > 0.95 { return 40 }
        if brightness < 0.16 || brightness > 0.90 { return 62 }
        if brightness < 0.22 || brightness > 0.85 { return 80 }
        return 100
    }

    /// Average the three sub-scores into a coarse level label.
    static func qualityLevel(exposure: Int, composition: Int, sharpness: Int) -> String {
        let average = (exposure + composition + sharpness) / 3
        if average >= 85 { return "优秀" }
        if average >= 70 { return "良好" }
        return "需要调整"
    }

    /// Subject position → a short framing hint for the on-screen guidance line.
    static func framingHint(subject: SubjectInfo, scene: String) -> String {
        guard subject.rect != .zero else {
            return scene == "风景" ? "寻找前景层次，避免主体贴边" : "等待识别主体"
        }
        let x = subject.rect.midX
        if x < 0.30 { return "主体偏左：右侧保留视线空间" }
        if x > 0.70 { return "主体偏右：左侧保留视线空间" }
        if abs(x - 0.5) < 0.10 { return "主体居中：尝试向三分线移动" }
        return "主体位置合适，保持当前取景"
    }
}
