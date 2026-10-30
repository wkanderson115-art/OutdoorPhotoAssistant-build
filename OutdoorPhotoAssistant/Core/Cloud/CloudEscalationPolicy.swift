import Foundation

/// Decides when a photo is worth a paid cloud round-trip.
///
/// Product rule (20-photo/day studio): the cloud is an *escalation*, not the
/// default. Local QC is cheap and deterministic, so it gates the expensive call:
/// only frames the local engine could not sign off on are sent to the seedream /
/// DeepSeek brain. That keeps cost near zero on a normal shoot while still
/// rescuing the hard frames.
struct CloudEscalationPolicy {
    /// Hard budget per batch; a studio shoot should never silently burn credits.
    var maxCloudCallsPerBatch: Int = 5

    enum Reason: String {
        case localFailed = "本地质检未通过"
        case poorTexture = "纹理保留异常（可能过度磨皮或锐化）"
        case lowStructure = "结构相似度偏低（可能修坏结构）"
        case blemishLeft = "仍有明显瑕疵未清"
        case manualRequest = "人工主动要求云端方案"
    }

    /// Returns the reason to escalate, or nil when the local result is good enough.
    func escalationReason(report: RetouchQualityReport?,
                          spotsRemaining: Int,
                          isDocumentCategory: Bool,
                          manualRequest: Bool = false) -> Reason? {
        // Documents and scans never go to a generative model.
        if isDocumentCategory { return nil }
        if manualRequest { return .manualRequest }
        guard let report else { return .localFailed }
        if !report.passed { return .localFailed }
        let texture = report.metrics["texture_retention"] ?? 1.0
        if texture < 0.55 || texture > 1.20 { return .poorTexture }
        let ssim = report.metrics["ssim"] ?? 1.0
        if ssim < 0.88 { return .lowStructure }
        if spotsRemaining > 2 { return .blemishLeft }
        return nil
    }

    /// Whether the batch still has budget for another cloud call.
    func hasBudget(used: Int) -> Bool { used < maxCloudCallsPerBatch }

    /// Operator-facing one-liner for the review sheet.
    func summary(used: Int, total: Int) -> String {
        "云端升级 \(used)/\(min(total, maxCloudCallsPerBatch))：只对本地质检未通过的片子发起"
    }
}
