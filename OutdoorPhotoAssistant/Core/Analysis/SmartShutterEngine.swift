import Foundation

struct SmartShutterDecision: Equatable {
    enum Action: String {
        case shootNow = "立即拍摄"
        case wait = "等待更稳定"
    }

    let action: Action
    let delay: TimeInterval
    let reason: String
    let score: Int
}

/// 把"稳定性 + 曝光 + 清晰度"变成一次快门决策的纯函数，方便单测。
/// 刻意去掉了多帧连拍：手机上多帧连拍会连带保存多张全分辨率图，内存与相册都会失控。
enum SmartShutterEngine {
    static func decide(stability: Int,
                       isStable: Bool,
                       exposureScore: Int,
                       sharpnessScore: Int) -> SmartShutterDecision {
        let quality = max(0, min(100, Int(Double(exposureScore) * 0.45 + Double(sharpnessScore) * 0.55)))

        if stability < 35 {
            return SmartShutterDecision(action: .wait,
                                        delay: 0.45,
                                        reason: "手持抖动较大，先稳定机身",
                                        score: max(0, quality - 18))
        }
        if !isStable {
            return SmartShutterDecision(action: .wait,
                                        delay: 0.25,
                                        reason: "正在稳定，避免快门瞬间拖影",
                                        score: max(0, quality - 8))
        }
        if quality < 55 {
            return SmartShutterDecision(action: .wait,
                                        delay: 0.30,
                                        reason: "正在等待更合适的曝光状态",
                                        score: quality)
        }
        return SmartShutterDecision(action: .shootNow,
                                    delay: 0,
                                    reason: "稳定性与曝光合格",
                                    score: quality)
    }
}
