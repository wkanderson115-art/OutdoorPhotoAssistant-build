import Foundation
import UIKit
import CoreImage
import ImageIO
import ColorSync

struct CommercialQualityReport {
    enum Decision: String { case passedTechnical = "技术检查通过", reviewRequired = "需要人工审核", rejected = "拒绝交付" }
    let decision: Decision
    let findings: [String]
}

/// Conservative checks: never equate passing technical checks with commercial approval.
final class CommercialQualityGate {
    func review(original: UIImage, candidate: UIImage, aiModified: Bool) -> CommercialQualityReport {
        var findings: [String] = []
        let a = original.cgImage, b = candidate.cgImage
        guard let source = a, let result = b else {
            return .init(decision: .rejected, findings: ["原图或成片无法解码"])
        }
        if result.width < 1200 || result.height < 1200 { findings.append("像素不足以满足部分商业用途，请核对客户尺寸") }
        if result.width != source.width || result.height != source.height { findings.append("图像像素尺寸改变，需核对裁切与缩放") }
        // Fast, deterministic pixel audit. Detects gross tonal damage; not semantic identity verification.
        if let metrics = RetouchPixelAudit.measure(original: source, candidate: result) {
            if metrics.clippedFraction > 0.18 { findings.append("高光或暗部裁切像素偏多（\(Int(metrics.clippedFraction * 100))%），建议人工复核") }
            if metrics.meanAbsoluteDifference > 0.28 { findings.append("相对原图的平均像素变化过大，可能存在过度处理") }
            if metrics.changedFraction > 0.55 { findings.append("大面积像素发生变化，请核对主体和背景是否被改写") }
        } else { findings.append("像素质量抽样不可用，需人工检查") }
        if aiModified { findings.append("AI 结果尚无可靠身份、结构与伪影模型审核，必须人工确认") }
        findings.append("尚需人工确认肤质、构图、授权及商业用途")
        return .init(decision: .reviewRequired, findings: findings)
    }
    func verifyJPEG(_ url: URL, expectedWidth: Int, expectedHeight: Int) -> CommercialQualityReport {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .init(decision: .rejected, findings: ["JPEG 无法完整解码"])
        }
        var findings: [String] = []
        if image.width != expectedWidth || image.height != expectedHeight { findings.append("导出尺寸不一致") }
        if image.colorSpace?.name != CGColorSpace.sRGB { findings.append("导出色彩空间无法确认为 sRGB") }
        if !findings.isEmpty { return .init(decision: .rejected, findings: findings) }
        return .init(decision: .passedTechnical, findings: ["JPEG 可解码、尺寸与 sRGB 色彩空间检查通过；商业内容仍需审核"])
    }
}
