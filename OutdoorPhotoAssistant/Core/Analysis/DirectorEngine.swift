import Foundation

// Frame evidence is expressed in normalized Vision coordinates (origin bottom-left).
// No image bytes, face identities or biometric templates are stored in preferences.
struct DirectorBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var area: Double { max(0, width) * max(0, height) }
    var valid: Bool { [x, y, width, height].allSatisfy { $0.isFinite } && width > 0 && height > 0 }
    func scaledAroundCenter(_ factor: Double) -> DirectorBox {
        DirectorBox(x: 0.5 + (x - 0.5) * factor, y: 0.5 + (y - 0.5) * factor,
                    width: width * factor, height: height * factor)
    }
    func overlap(_ other: DirectorBox) -> Double {
        let w = max(0, min(maxX, other.maxX) - max(x, other.x))
        let h = max(0, min(maxY, other.maxY) - max(y, other.y))
        let intersection = w * h
        return intersection / max(0.000001, area + other.area - intersection)
    }
}

/// Output of the on-device DirectorNet Core ML model (see tools/director_lab).
/// Kept Foundation-only so the engine and its tests compile without CoreML.
/// Shift convention (same as training): dx > 0 means the camera should move right,
/// dy > 0 down, dz > 0 zoom in (zoom factor = exp(dz)). All relative to the current frame.
struct DirectorMLOutput: Equatable {
    var scene: String
    var sceneConfidence: Double
    var quality: Double // 0...1, how close the current framing is to the learned ideal
    var dx: Double
    var dy: Double
    var dz: Double
    var magnitude: Double { max(abs(dx), abs(dy), abs(dz) * 0.8) }
}

/// Exponential smoothing for the model output, which is sampled only a few times per second.
struct DirectorMLSmoother {
    private var state: DirectorMLOutput?
    private var lastTime = -Double.infinity
    var alpha = 0.5
    var resetGap = 1.5

    mutating func reset() { self = DirectorMLSmoother() }
    mutating func update(_ new: DirectorMLOutput, now: Double) -> DirectorMLOutput {
        defer { lastTime = now }
        guard let old = state, now - lastTime <= resetGap else { state = new; return new }
        var blended = new
        blended.quality = old.quality + alpha * (new.quality - old.quality)
        blended.dx = old.dx + alpha * (new.dx - old.dx)
        blended.dy = old.dy + alpha * (new.dy - old.dy)
        blended.dz = old.dz + alpha * (new.dz - old.dz)
        blended.sceneConfidence = old.scene == new.scene ? old.sceneConfidence + alpha * (new.sceneConfidence - old.sceneConfidence) : new.sceneConfidence
        state = blended
        return blended
    }
}

struct DirectorObservation: Equatable {
    var ml: DirectorMLOutput?
    var subject: DirectorBox?
    var subjectKind = "none" // body / face / group / object / none
    var personCount = 0
    var confidence = 0.0
    var brightness = 0.5
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0
    var warmth = 0.0 // sampled red minus blue, not calibrated color temperature
    var subjectBrightness = 0.5
    var leftBrightness = 0.5
    var rightBrightness = 0.5
    var sharpness = 60
    var horizon = 0.0
}

struct DirectorEvidence: Equatable {
    let domain: String
    let rule: String
    let observation: String
    let action: String
}

struct DirectorLearningContext: Codable, Equatable {
    var scene: String
    var kind: String
    var group: Bool
    var subjectFraction: Double
    var automaticFraming: Bool
    var key: String { scene + "/" + kind + (group ? "/group" : "/single") }
}

struct DirectorPreference: Codable, Equatable {
    var count = 0
    var occupancySamples = 0
    var filterSamples = 0
    var subjectFraction = 0.5
    var filterStrength = 0.55
    var preferredFilter = "自然"
    var filterVotes: [String: Int] = [:]

    /// Bounded online preference update; does not retrain the Vision models.
    mutating func learn(context: DirectorLearningContext, filter: String, strength: Double,
                        framingFeedback: String) {
        let alpha = 0.18
        if context.automaticFraming && context.subjectFraction.isFinite && context.subjectFraction > 0 {
            let multiplier = framingFeedback == "主体太小" ? 1.10 : framingFeedback == "主体太大" ? 0.90 : 1
            let observed = max(0.08, min(0.82, context.subjectFraction * multiplier))
            subjectFraction = occupancySamples == 0 ? observed : subjectFraction * (1 - alpha) + observed * alpha
            occupancySamples += 1
        }
        if framingFeedback == "喜欢效果" {
            let safeStrength = strength.isFinite ? max(0, min(0.8, strength)) : 0.55
            filterStrength = filterSamples == 0 ? safeStrength : filterStrength * (1 - alpha) + safeStrength * alpha
            filterVotes[filter, default: 0] += 1
            preferredFilter = filterVotes.sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }.first?.key ?? filter
            filterSamples += 1
        }
        count += 1
    }
}

final class DirectorPreferenceStore {
    static let shared = DirectorPreferenceStore()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey = "director.preferences.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func read() -> [String: DirectorPreference] {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode([String: DirectorPreference].self, from: data) else { return [:] }
        return value
    }
    func preference(for context: DirectorLearningContext) -> DirectorPreference? {
        lock.lock(); defer { lock.unlock() }
        return read()[context.key]
    }
    var feedbackCount: Int {
        lock.lock(); defer { lock.unlock() }
        return read().values.reduce(0) { $0 + $1.count }
    }
    func learn(context: DirectorLearningContext, filter: String, strength: Double, framingFeedback: String) {
        lock.lock(); defer { lock.unlock() }
        if let previous = defaults.data(forKey: storageKey) { defaults.set(previous, forKey: storageKey + ".undo") }
        else { defaults.set(Data("{}".utf8), forKey: storageKey + ".undo") }
        var profiles = read()
        var value = profiles[context.key] ?? DirectorPreference()
        value.learn(context: context, filter: filter, strength: strength, framingFeedback: framingFeedback)
        profiles[context.key] = value
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: storageKey) }
    }
    func undoLastFeedback() {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: storageKey + ".undo") else { return }
        defaults.set(data, forKey: storageKey)
        defaults.removeObject(forKey: storageKey + ".undo")
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey + ".undo")
        defaults.removeObject(forKey: storageKey)
    }
}

struct DirectorInput {
    var observation: DirectorObservation
    var scene: String
    var sceneConfidence: Double
    var zoom: Double
    var minimumZoom: Double
    var maximumZoom: Double
    var nativeMaximumZoom: Double
    var stable: Bool
    var framing: String // 自动 / 环境 / 全身 / 半身 / 肖像
    var composition: String // 自动 / 居中 / 三分
    var preference: DirectorPreference?
}

struct DirectorDecision: Equatable {
    var targetZoom = 1.0
    var shouldZoom = false
    var filter = "自然"
    var maximumFilterStrength = 0.55
    var exposureBias = 0.0
    var protectHighlights = false
    var liftShadows = false
    var ready = false
    var blockers: [String] = []
    var context: DirectorLearningContext?
    var evidence: [DirectorEvidence] = []
    /// 屏幕上那一行导演指令。机位优先（带方向与幅度），再退到构图/时机，
    /// 最后兜底也必须是可执行动作，不留「等待可靠画面」这种空话。
    var summary: String {
        evidence.last(where: { $0.domain == "机位" })?.action
            ?? evidence.last(where: { $0.domain == "构图" })?.action
            ?? evidence.last(where: { $0.domain == "时机" })?.action
            ?? evidence.last(where: { $0.domain == "导演策划" })?.action
            ?? "未锁定主体：把人物放到画面中央三分之一，点击屏幕锁定"
    }
}

// Adapted from wearereasonablepeople/KalmanFilter, KalmanFilter/KalmanFilter.swift.
// Copyright (c) 2019 WEAREREASONABLEPEOPLE B.V.; source header (c) 2016 Oleksii Dykan.
// Scalar specialization (F=H=1, B=0); upstream MIT license in DirectorLicenses.
struct DirectorKalman {
    var estimate: Double
    var covariance = 1.0
    mutating func update(_ measurement: Double) -> Double {
        let predictedStateEstimate = estimate
        let predictedEstimateCovariance = covariance + 0.0002
        let measurementResidual = measurement - predictedStateEstimate
        let residualCovariance = predictedEstimateCovariance + 0.002
        let kalmanGain = predictedEstimateCovariance / residualCovariance
        estimate = predictedStateEstimate + kalmanGain * measurementResidual
        covariance = (1 - kalmanGain) * predictedEstimateCovariance
        return estimate
    }
}

// Adapted from jwagner/smartcrop.js importance()/thirds(), MIT (c) 2016 Jonas Wagner.
// This is the crop-position scoring portion, not the full smartcrop pixel detector.
enum DirectorCropImportance {
    static func thirds(_ input: Double) -> Double {
        let x = (((input - 1 / 3 + 1).truncatingRemainder(dividingBy: 2)) * 0.5 - 0.5) * 16
        return max(1 - x * x, 0)
    }
    static func score(x: Double, y: Double, ruleOfThirds: Bool) -> Double {
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return -0.5 }
        let px = abs(0.5 - x) * 2
        let py = abs(0.5 - y) * 2
        let dx = max(px - 0.6, 0)
        let dy = max(py - 0.6, 0)
        let d = (dx * dx + dy * dy) * -20
        var s = 1.41 - sqrt(px * px + py * py)
        if ruleOfThirds {
            // Compare the actual subject position with the four thirds-line
            // intersections.  Feeding centre-distance into `thirds` made the
            // former implementation reward the centre rather than the thirds.
            let thirdX = max(0, 1 - min(abs(x - 1.0 / 3), abs(x - 2.0 / 3)) / 0.20)
            let thirdY = max(0, 1 - min(abs(y - 1.0 / 3), abs(y - 2.0 / 3)) / 0.20)
            s += 0.8 * (thirdX + thirdY)
        }
        return s + d
    }
}

enum DirectorEngine {
    /// Minimum model confidence / framing error before the model is allowed to speak.
    static let mlMinimumMove = 0.12
    static let mlGoodQuality = 0.80

    // MARK: - 变焦滞回状态（只存在引擎内部，DirectorDecision 仍是纯值类型）
    /// 上一次真正下发的变焦目标（一阶低通平滑后的值）。
    private static var lastZoomTarget = 1.0
    /// 上一次真正下发变焦的时刻，取 evaluate 传入的 now（秒）。
    private static var lastZoomActionAt = -Double.infinity
    /// 死区：新目标与当前目标相对差小于 8% 就不动，杀掉每帧抖动。
    static let zoomDeadBand = 0.08
    /// 最短下发间隔（秒）：两条真实变焦指令之间至少隔这么久。
    static let zoomCommandInterval = 1.2
    /// 一阶低通系数：每帧向理想值收敛 35%，避免跳变。
    static let zoomSmoothing = 0.35
    /// 数码变焦硬上限倍数（相对 nativeMaximumZoom）。
    static let digitalCeilingFactor = 3.0
    /// 闭眼状态由 Vision 层上报；没上报就按 unknown，绝不编造。
    private static var reportedEyes = "unknown"

    static func resetZoomGate() {
        lastZoomTarget = 1.0
        lastZoomActionAt = -Double.infinity
    }

    /// 由真正把变焦指令送给镜头的一方调用（DirectorController），记录「真正下发」的时刻。
    static func noteZoomCommand(at now: Double) {
        guard now.isFinite else { return }
        lastZoomActionAt = now
    }

    /// FrameAnalyzer / CaptureView 把眼睛状态报进来后，时机文案自动切到「等睁眼再按」。
    static func reportEyes(_ state: String) {
        if state == "closed" { reportedEyes = "closed" }
        else if state == "open" { reportedEyes = "open" }
        else { reportedEyes = "unknown" }
    }

    /// 固定小数位；非有限值一律当 0，保证文案里永远是数字。
    static func fixed(_ value: Double, digits: Int) -> String {
        let safe = value.isFinite ? value : 0
        if digits <= 1 { return String(format: "%.1f", safe) }
        if digits >= 3 { return String(format: "%.3f", safe) }
        return String(format: "%.2f", safe)
    }

    /// 数码变焦上限：不允许用裁切代替走近。
    /// 人物已占画面高度 12% 以上时封顶 min(native×2, 3.0) 且不超过 2×；
    /// 只有运动/特写且主体占比 < 8% 才准吃满硬件上限。
    static func zoomCeiling(nativeMaximum: Double, upper: Double, fraction: Double,
                            person: Bool, framing: String) -> Double {
        let native = (nativeMaximum.isFinite && nativeMaximum > 0) ? nativeMaximum : 1
        let limit = (upper.isFinite && upper > 0) ? upper : 1
        let motionShot = framing == "运动" || framing == "特写"
        var ceiling = motionShot && fraction < 0.08 ? limit : min(limit, native * digitalCeilingFactor)
        if person && fraction >= 0.12 {
            ceiling = min(ceiling, min(native * 2, digitalCeilingFactor))
            ceiling = min(ceiling, 2.0)
        }
        if !ceiling.isFinite || ceiling <= 0 { ceiling = limit }
        return ceiling
    }

    /// 模型给出的机位短语。只说人话，不直接碰镜头。
    static func mlPositionPhrase(_ ml: DirectorMLOutput?) -> String {
        guard let ml, ml.quality.isFinite, ml.dx.isFinite, ml.dy.isFinite, ml.dz.isFinite,
              ml.quality < mlGoodQuality, ml.magnitude >= mlMinimumMove else { return "" }
        var parts: [String] = []
        if abs(ml.dx) >= mlMinimumMove { parts.append(ml.dx > 0 ? "镜头向右转一点" : "镜头向左转一点") }
        if abs(ml.dy) >= mlMinimumMove { parts.append(ml.dy > 0 ? "镜头向下压一点" : "镜头向上抬一点") }
        if abs(ml.dz) >= mlMinimumMove { parts.append(ml.dz > 0 ? "再推近一点" : "再拉远一点") }
        return parts.joined(separator: "，")
    }

    /// 曝光：永远带实测值和下一步动作，绝不只写「注意曝光」。
    static func exposureAdvice(brightness: Double, highlights: Double, subjectBrightness: Double,
                               bias: Double) -> (observation: String, action: String) {
        let level = fixed(brightness, digits: 2)
        let subjectLevel = fixed(subjectBrightness, digits: 2)
        let clipped = fixed(highlights * 100, digits: 1) + "%"
        let backlit = subjectBrightness < 0.25 && brightness > subjectBrightness + 0.18
        if backlit {
            return ("逆光：主体 " + subjectLevel + " / 画面 " + level,
                    "逆光：转到侧光位或给主体补 0.3EV，提亮阴影救不回来（亮部占比 " + clipped + "）")
        }
        if brightness < 0.16 {
            return ("亮度 " + level + "，亮部占比 " + clipped,
                    "光线不足：ISO/快门已拉高，靠稳 1 秒或换到侧光位，必要时 +0.3EV")
        }
        if brightness > 0.88 || highlights > 0.85 {
            return ("亮度 " + level + "，亮部占比 " + clipped,
                    "高光接近溢出：压低 0.3EV 或避开直射，别正对太阳")
        }
        if highlights > 0.045 {
            return ("亮度 " + level + "，亮部占比 " + clipped + " 接近溢出",
                    "高光接近溢出：压低 0.3EV 或换到侧光位")
        }
        let biasText = fixed(abs(bias), digits: 1)
        let biasSign = bias < 0 ? "-" : (bias > 0 ? "+" : "")
        return ("亮度 " + level + "，亮部占比 " + clipped,
                "曝光可用：保持 " + biasSign + biasText + "EV，先保主体脸部")
    }

    /// 时机：缺哪项说哪项，blockers 与自动快门门禁同一套依据。
    static func timingAdvice(stable: Bool, sharpness: Int, horizon: Double, shouldZoom: Bool,
                             targetZoom: Double, person: Bool, eyesClosed: Bool) -> (observation: String, action: String) {
        if person && eyesClosed {
            return ("检测到闭眼", "闭眼：等睁眼再按，或连拍里挑一张睁眼的")
        }
        if abs(horizon) >= 0.06 {
            let degrees = fixed(abs(horizon) * 180 / Double.pi, digits: 1)
            let right = horizon > 0
            return ("地平线" + (right ? "右倾 " : "左倾 ") + degrees + "°",
                    "地平线" + (right ? "右倾 " : "左倾 ") + degrees + "°：" + (right ? "向左" : "向右") + "微转手机校平")
        }
        if !stable {
            return ("机身仍在移动", "机身未稳：靠住栏杆或双手夹紧，稳住 1 秒即自动拍摄")
        }
        if sharpness < 65 {
            return ("锐度 " + String(sharpness) + " 偏低", "细节不足：重新对焦屏幕上主体，或靠近 15cm")
        }
        if shouldZoom {
            return ("变焦进行中", "正在变焦到 " + fixed(targetZoom, digits: 2) + "×：等镜头到位，1 秒后自动拍")
        }
        return ("画面稳定且清晰", "稳住 1 秒即自动拍摄")
    }

    /// 0.03～0.06 的轻微倾斜：还没到拦快门，但必须报出角度和转向。
    static func levelEvidence(horizon: Double) -> DirectorEvidence? {
        let magnitude = abs(horizon)
        guard magnitude.isFinite, magnitude > 0.03, magnitude < 0.06 else { return nil }
        let degrees = fixed(magnitude * 180 / Double.pi, digits: 1)
        let right = horizon > 0
        return DirectorEvidence(domain: "水平", rule: "地平线与透视校平",
                                observation: "地平线" + (right ? "右倾 " : "左倾 ") + degrees + "°",
                                action: "地平线" + (right ? "右倾 " : "左倾 ") + degrees + "°：" + (right ? "向左" : "向右") + "微转手机")
    }

    /// Turns the learned framing suggestion into on-screen guidance. Never drives the lens by itself:
    /// zoom stays behind the subject gate, the temporal controller and the cooldown.
    static func mlEvidence(_ ml: DirectorMLOutput?) -> [DirectorEvidence] {
        guard let ml, ml.dx.isFinite, ml.dy.isFinite, ml.dz.isFinite, ml.quality.isFinite else { return [] }
        let quality = String(Int((ml.quality * 100).rounded()))
        if ml.quality >= mlGoodQuality || ml.magnitude < mlMinimumMove {
            return [DirectorEvidence(domain: "AI模型", rule: "构图模型评分", observation: "取景接近模型学到的理想构图（" + quality + "分）", action: "保持当前取景")]
        }
        var steps: [String] = []
        let horizontal = abs(ml.dx) >= mlMinimumMove
        let vertical = abs(ml.dy) >= mlMinimumMove
        if horizontal { steps.append(ml.dx > 0 ? "向右转一点" : "向左转一点") }
        if vertical { steps.append(ml.dy > 0 ? "镜头向下压一点" : "镜头向上抬一点") }
        if abs(ml.dz) >= mlMinimumMove { steps.append(ml.dz > 0 ? "走近或小幅推近" : "后退或小幅拉远") }
        let action = steps.joined(separator: "，")
        var result = [DirectorEvidence(domain: "AI模型", rule: "构图模型评分", observation: "取景离理想构图还有差距（" + quality + "分）", action: action)]
        // `机位` is what the instruction line shows; only promote it when the move is clear.
        if ml.magnitude >= 0.2 { result.append(DirectorEvidence(domain: "机位", rule: "构图模型建议", observation: "模型建议调整取景", action: action)) }
        return result
    }

    static func context(_ input: DirectorInput) -> DirectorLearningContext {
        DirectorLearningContext(scene: input.scene, kind: input.observation.subjectKind,
                                group: input.observation.personCount > 1,
                                subjectFraction: input.observation.subject?.height ?? 0,
                                automaticFraming: input.framing == "自动")
    }

    /// 旧调用点与单元测试走这里：没有帧时钟时用参考时钟。
    static func evaluate(_ input: DirectorInput) -> DirectorDecision {
        evaluate(input, now: Date().timeIntervalSinceReferenceDate)
    }

    static func evaluate(_ input: DirectorInput, now: Double) -> DirectorDecision {
        let o = input.observation
        let requestedZoom = input.zoom.isFinite && input.zoom > 0 ? input.zoom : 1
        let lower = max(0.01, input.minimumZoom.isFinite ? input.minimumZoom : 1)
        let upper = max(lower, input.maximumZoom.isFinite ? input.maximumZoom : lower)
        let zoom = max(lower, min(requestedZoom, upper))
        var decision = DirectorDecision(targetZoom: zoom)
        decision.context = context(input)
        let person = o.personCount > 0
        let eyesClosed = reportedEyes == "closed" && person
        func evidence(_ domain: String, _ rule: String, _ observation: String, _ action: String) -> DirectorEvidence {
            DirectorEvidence(domain: domain, rule: rule, observation: observation, action: action)
        }
        // Light/color decisions use measured image statistics, not a guessed light-source direction.
        decision.protectHighlights = o.highlights > 0.045
        decision.liftShadows = o.shadows > 0.32 && o.highlights < 0.03
        decision.exposureBias = decision.protectHighlights ? -0.3 : decision.liftShadows ? 0.2 : 0
        if o.subjectBrightness < 0.25 && o.brightness > o.subjectBrightness + 0.18 {
            decision.evidence.append(evidence("光线色彩", "逆光与动态范围", "主体比整体画面暗", "保护亮部，优先换角度或补光，不强行提亮阴影"))
        } else if decision.protectHighlights {
            decision.evidence.append(evidence("光线色彩", "高光保护", "亮部接近饱和的采样增加", "小幅压曝光；已溢出的细节不能凭空恢复"))
        } else {
            decision.evidence.append(evidence("光线色彩", "明暗关系", "亮暗分布处于可用范围", "保留现场明暗，不强制HDR拉平"))
        }
        if abs(o.leftBrightness - o.rightBrightness) > 0.18 {
            decision.evidence.append(evidence("光线色彩", "画面亮度平衡", o.leftBrightness > o.rightBrightness ? "画面左侧更亮" : "画面右侧更亮", "检查亮部是否抢主体；这不等同于判断真实光源方向"))
        }
        // Filter selection is conservative for skin and low-confidence recognition.
        if person { decision.filter = "人像" }
        else if input.sceneConfidence < 0.65 { decision.filter = "自然" }
        else {
            switch input.scene {
            case "日落": decision.filter = "日落"
            case "夜景": decision.filter = "夜景"
            case "花草": decision.filter = "森系"
            case "风景", "海边": decision.filter = "风景"
            default: decision.filter = "自然"
            }
        }
        if o.saturation > 0.48 || (person && o.warmth > 0.14) { decision.filter = "自然" }
        let hasApprovedFilterPreference = (input.preference?.filterSamples ?? 0) >= 3
        if let preference = input.preference, hasApprovedFilterPreference {
            // Apply the user's context-specific choices, bounded by present image quality.
            decision.filter = preference.preferredFilter
            decision.maximumFilterStrength = max(0.15, min(0.8, preference.filterStrength))
        }
        if person { decision.maximumFilterStrength = min(0.5, decision.maximumFilterStrength) }
        if o.saturation > 0.48 || decision.protectHighlights { decision.maximumFilterStrength = min(0.4, decision.maximumFilterStrength) }
        if person && !hasApprovedFilterPreference {
            decision.filter = o.brightness < 0.20 || o.warmth > 0.14 || o.saturation > 0.48 ? "自然" : "人像"
        } else if !hasApprovedFilterPreference && o.brightness < 0.16 {
            decision.filter = "自然"
        } else if !hasApprovedFilterPreference && o.saturation < 0.12 {
            decision.filter = "自然" // Neutral scenes must not be artificially colored.
        }
        let lightState = o.brightness < 0.20 ? "暗光" : o.brightness > 0.80 ? "明亮场景" : "正常亮度"
        let colorState = o.saturation > 0.48 ? "色彩已浓，限制增艳" : o.saturation < 0.12 ? "低彩度，保持中性色" : "适度增强现场色彩"
        decision.evidence.append(evidence("滤镜", "拍摄现场依据", lightState + "；" + (person ? "检测到人物；" : "未检测到人物；") + colorState,
            "选择" + decision.filter + "；强度上限" + String(Int(decision.maximumFilterStrength * 100)) + "%" + (decision.protectHighlights ? "，优先保护高光" : "，保留现场层次")))
        decision.evidence.append(evidence("滤镜", "自然色与肤色优先", "滤镜：" + decision.filter, "按场景和用户反馈选风格，对高饱和与人像限制强度"))
        let mlGuidance = Self.mlEvidence(o.ml)
        // 没有可靠主体时也必须给可执行取景指令，并把 构图/机位/曝光/时机 四域补齐。
        guard let box = o.subject, box.valid, o.confidence >= 0.50 else {
            lastZoomTarget = zoom
            let confidenceText = fixed(o.confidence, digits: 2)
            let landscape = !person && ["风景", "海边", "日落", "夜景", "建筑"].contains(input.scene)
            let weakBox = (o.subject?.valid ?? false)
            let positionBase: String
            if weakBox {
                positionBase = "主体不确定（置信度 " + confidenceText + "）：把主体放到画面中央三分之一，点击屏幕锁定"
            } else if person {
                positionBase = "未锁定主体：把人物放到画面中央三分之一，点击屏幕锁定"
            } else if landscape {
                positionBase = "无主体场景：地平线对齐，天空留 1/3，最亮处放在三分线交叉点"
            } else {
                positionBase = "未锁定主体：向左右各移动半步扫一遍，看到主体就点一下屏幕"
            }
            let modelPhrase = Self.mlPositionPhrase(o.ml)
            let positionAction = modelPhrase.isEmpty ? positionBase : positionBase + "；" + modelPhrase
            let frameAction: String
            if landscape {
                frameAction = "先用 " + fixed(zoom, digits: 2) + "× 广角取景：地平线压到画面下方 1/3，前景占下部 1/4"
            } else {
                frameAction = "把主体放进中央三分之一（横向 0.33～0.67），头顶留出 1/10 空间"
            }
            let noSubjectExposure = Self.exposureAdvice(brightness: o.brightness, highlights: o.highlights,
                                                        subjectBrightness: o.subjectBrightness, bias: decision.exposureBias)
            let noSubjectTiming = Self.timingAdvice(stable: input.stable, sharpness: o.sharpness, horizon: o.horizon,
                                                    shouldZoom: false, targetZoom: zoom, person: person, eyesClosed: eyesClosed)
            decision.evidence.append(evidence("人物定位", "可靠主体门控", "未检测到可靠主体（置信度 " + confidenceText + "）",
                                              "保持 " + fixed(zoom, digits: 2) + "×，不按猜测自动追焦放大"))
            decision.evidence.append(evidence("构图", landscape ? "环境取景与层次" : "主体定位与留白",
                                              landscape ? "无主体：按 1/3 地平线与前景层次取景" : "主体框缺失或置信度不足",
                                              frameAction))
            decision.evidence.append(contentsOf: mlGuidance)
            decision.evidence.append(evidence("曝光", "实测亮度与亮部", noSubjectExposure.observation, noSubjectExposure.action))
            decision.evidence.append(evidence("时机", "稳定、锐度与水平", noSubjectTiming.observation, noSubjectTiming.action))
            if let level = Self.levelEvidence(horizon: o.horizon) { decision.evidence.append(level) }
            decision.evidence.append(evidence("机位", "取景起点与主体锁定", "当前 " + fixed(zoom, digits: 2) + "×，目标：中央三分之一",
                                              positionAction))
            var noSubjectBlockers: [String] = []
            if weakBox { noSubjectBlockers.append("主体置信度 " + confidenceText + " 不足：靠近 30cm 或点击屏幕锁定") }
            else { noSubjectBlockers.append("未锁定主体：把主体放进中央三分之一并点击锁定") }
            if abs(o.horizon) >= 0.06 {
                noSubjectBlockers.append("地平线" + (o.horizon > 0 ? "右倾 " : "左倾 ") + fixed(abs(o.horizon) * 180 / Double.pi, digits: 1) + "°：先转手机校平")
            } else if o.brightness <= 0.16 {
                noSubjectBlockers.append("亮度 " + fixed(o.brightness, digits: 2) + " 偏低：换向光位或靠稳 1 秒")
            }
            decision.blockers = Array(noSubjectBlockers.prefix(3))
            return decision
        }
        var desired: Double
        if o.subjectKind == "face" {
            // A detected face at 30% of frame height is already too tight for
            // the default portrait framing. Leave enough head and shoulder room
            // unless the photographer explicitly asks for a close-up.
            desired = input.framing == "特写" ? 0.45 : 0.24
        } else {
            switch input.framing {
            case "环境": desired = 0.42
            case "完整人物": desired = 0.70
            case "半身": desired = 0.76
            case "特写": desired = 0.82
            case "合影": desired = 0.62
            case "运动": desired = 0.48
            case "突出主体": desired = 0.80
            default: desired = o.personCount > 1 ? 0.62 : person ? 0.58 : 0.42
            }
        }
        if !person && ["风景", "海边", "日落", "夜景"].contains(input.scene) { desired = min(desired, 0.32) }
        if input.framing == "自动", let p = input.preference, p.occupancySamples >= 3 {
            desired = max(0.08, min(0.82, p.subjectFraction))
        }
        let fraction = max(0.01, box.height)
        decision.evidence.append(evidence("人物定位", o.personCount > 1 ? "合影完整性" : o.subjectKind == "face" ? "人脸与全身区分" : "主体占比",
                                          "目标占高约" + String(Int(desired * 100)) + "%，实测 " + fixed(fraction, digits: 2),
                                          o.subjectKind == "face" ? "只有人脸证据，不能据此保证全身入镜" : "优先保留完整人物与头顶留白，不机械放大人脸"))
        let clipped = box.x < 0.025 || box.maxX > 0.975 || box.y < 0.025 || box.maxY > 0.975
        let needsChange = clipped || abs(log(max(0.01, box.height) / desired)) > 0.17
        let thirds = input.composition == "三分" || (input.composition == "自动" && !person)
        let ceiling = Self.zoomCeiling(nativeMaximum: input.nativeMaximumZoom, upper: upper,
                                       fraction: fraction, person: person, framing: input.framing)
        func score(_ target: Double) -> Double {
            let ratio = target / zoom
            let predicted = box.scaledAroundCenter(ratio)
            if ratio > 1.001 && (predicted.x < 0.05 || predicted.maxX > 0.95 || predicted.y < 0.05 || predicted.maxY > 0.94) { return -100 }
            let occupancy = -abs(log(max(0.01, predicted.height) / desired))
            let margin = min(predicted.x, min(predicted.y, min(1 - predicted.maxX, 1 - predicted.maxY)))
            let edgePenalty = min(0, margin - 0.045) * 12
            let position = DirectorCropImportance.score(x: predicted.midX, y: predicted.midY, ruleOfThirds: thirds) * 0.10
            let digital = max(0, log(target / max(1, input.nativeMaximumZoom)))
            let qualityPenalty = digital * (o.brightness < 0.22 || o.sharpness < 65 || input.scene == "夜景" ? 0.6 : 0.08)
            let movementPenalty = abs(log(ratio)) * 0.08
            return occupancy + edgePenalty + position - qualityPenalty - movementPenalty
        }
        var best = zoom
        var bestScore = score(zoom)
        // 一步解算理想倍率，再补候选方案；候选一律不许超过数码变焦上限。
        let ideal = max(lower, min(upper, zoom * desired / max(0.05, box.height)))
        let idealClamped = max(zoom / 1.35, min(zoom * 1.35, ideal))
        for candidate in [idealClamped, zoom * 1.15, zoom * 0.87, zoom] {
            let c = max(lower, min(upper, candidate))
            if c > ceiling { continue }
            if o.brightness < 0.20 && c > zoom { continue }
            if o.sharpness < 55 && c > zoom { continue }
            if o.subjectBrightness > 0.9 && input.scene == "日落" && c > zoom { continue }
            if score(c) > bestScore + 0.025 { best = c; bestScore = score(c) }
        }
        // 变焦四道闸：上限（数码裁切不算走近）→ 死区 8% → 最短 1.2s → 一阶低通 0.35。
        let canZoom = input.stable && abs(o.horizon) < 0.14 && needsChange
        let commandCeiling = max(lower, min(upper, ceiling))
        let commanded = max(lower, min(commandCeiling, best))
        if canZoom && commanded.isFinite {
            let manualTakeover = !lastZoomTarget.isFinite || lastZoomTarget <= 0
                || abs(log(max(0.01, zoom) / max(0.01, lastZoomTarget))) > 0.5
                || (now.isFinite && now - lastZoomActionAt > 6)
            if manualTakeover { lastZoomTarget = zoom }
            let gapToIdeal = abs(commanded - lastZoomTarget) / max(0.01, lastZoomTarget)
            if gapToIdeal >= Self.zoomDeadBand {
                let smoothed = lastZoomTarget + Self.zoomSmoothing * (commanded - lastZoomTarget)
                lastZoomTarget = max(lower, min(upper, smoothed.isFinite ? smoothed : commanded))
            }
            decision.targetZoom = max(lower, min(upper, lastZoomTarget))
            let intervalReady = now.isFinite && now - lastZoomActionAt >= Self.zoomCommandInterval
            let lensGap = abs(log(max(0.01, decision.targetZoom) / max(0.01, zoom)))
            // 目标没变就只在镜头明显没跟上时补发，不会来回抽动。
            // 时间戳交给真正下发的一方提交（noteZoomCommand），免得被门控告吹掉的建议白吃 1.2s。
            decision.shouldZoom = intervalReady && lensGap > 0.045 && (gapToIdeal >= Self.zoomDeadBand || lensGap > 0.12)
        } else {
            lastZoomTarget = zoom
            decision.targetZoom = zoom
            decision.shouldZoom = false
        }
        let expectedOccupancy = max(0.02, min(1.5, fraction * decision.targetZoom / max(0.01, zoom)))
        let frameAction: String
        if clipped {
            frameAction = "主体贴边：后退约 20cm 让人物完整入镜，再决定倍率"
        } else if decision.shouldZoom && decision.targetZoom > zoom {
            frameAction = "推近到 " + fixed(decision.targetZoom, digits: 2) + "×，主体占高 " + fixed(fraction, digits: 2) + " → " + fixed(expectedOccupancy, digits: 2)
        } else if decision.shouldZoom {
            frameAction = "拉远到 " + fixed(decision.targetZoom, digits: 2) + "×，保留留白与四肢"
        } else if fraction < desired * 0.85 {
            let cm = max(10, min(150, Int(((desired / max(0.05, fraction) - 1) * 100).rounded())))
            frameAction = "画面偏松：再靠近 " + String(cm) + "cm 或切 2×，主体占高 " + fixed(fraction, digits: 2) + " / 目标 " + fixed(desired, digits: 2)
        } else if fraction > max(0.75, desired * 1.25) && !["半身", "特写", "突出主体"].contains(input.framing) {
            let back = max(10, min(150, Int(((fraction / max(0.05, desired) - 1) * 100).rounded())))
            frameAction = "画面太满（占高 " + fixed(fraction, digits: 2) + "）：后退 " + String(back) + "cm 或拉远到 " + fixed(max(lower, min(commandCeiling, zoom * 0.85)), digits: 2) + "×"
        } else {
            frameAction = "保持 " + fixed(zoom, digits: 2) + "×：主体占高 " + fixed(fraction, digits: 2) + "，目标 " + fixed(desired, digits: 2)
        }
        decision.evidence.append(evidence("构图", thirds ? "三分与边缘重要性" : "居中与视觉平衡",
                                          (clipped ? "主体靠近画面边界" : "比较中心裁切候选方案") + "；实测占高 " + fixed(fraction, digits: 2),
                                          frameAction))
        if abs(o.horizon) > 0.06 {
            decision.evidence.append(evidence("拍摄技巧", "水平与透视", "水平线存在倾斜 " + fixed(abs(o.horizon) * 180 / Double.pi, digits: 1) + "°",
                                              (o.horizon > 0 ? "地平线右倾：向左微转手机" : "地平线左倾：向右微转手机") + "；变焦不能代替移动机位"))
        }
        if !input.stable || o.brightness < 0.20 || o.sharpness < 55 {
            decision.evidence.append(evidence("拍摄技巧", "稳定、快门与细节",
                                              "稳定=" + (input.stable ? "是" : "否") + "，亮度 " + fixed(o.brightness, digits: 2) + "，锐度 " + String(o.sharpness),
                                              "暂停推近，先稳住手机、补光或重新对焦"))
        }
        // Compare feasible composition anchors. Off-centre alternatives are guidance,
        // never an invisible digital crop or a claim that the phone can pan itself.
        let anchors: [(String, Double)] = input.composition == "居中" ? [("居中", 0.5)] : input.composition == "三分" ? [("左三分", 1.0 / 3), ("右三分", 2.0 / 3)] : [("居中", 0.5), ("左三分", 1.0 / 3), ("右三分", 2.0 / 3)]
        let candidates = anchors.map { name, x -> (String, Double, Double) in
            let margin = min(x - box.width / 2, 1 - x - box.width / 2)
            let edge = max(0, 0.05 - margin) * 10
            let movement = abs(box.midX - x)
            let narrative = (input.framing == "环境" && name != "居中") ? 0.08 : 0
            return (name, x, -movement - edge + narrative)
        }
        if let best = candidates.max(by: { $0.2 < $1.2 }) {
            decision.evidence.append(evidence("候选构图", "居中与三分比较", "比较" + String(candidates.count) + "个方案，考虑主体宽度、留边与移动量；选择" + best.0,
                abs(box.midX - best.1) < 0.06 ? "主体已接近所选构图位置" : best.1 < box.midX ? "让主体在画面中稍向左移动，保留完整边缘" : "让主体在画面中稍向右移动，保留完整边缘"))
        }
        let portrait = person && o.personCount == 1
        let backlit = o.subjectBrightness < 0.25 && o.brightness > o.subjectBrightness + 0.18
        let plan = o.personCount > 1 ? "合影：优先所有人物完整清晰，保留背景空间，不建议强虚化" : portrait ? "单人人像：先保证脸部清晰，再按背景与人物距离考虑轻度虚化" : "环境叙事：保留前中后景层次，不增加人像虚化"
        decision.evidence.append(evidence("导演策划", "景别与景深", plan,
            backlit ? "人物明显偏暗：请转向柔和侧光或补光，先保住亮部" : clipped ? "请后退或拉远，让人物完整入镜，再调整主体位置" : abs(o.horizon) > 0.06 ? "请校平手机，再检查画面四边" : "构图基本到位，保持主体位置，等待对焦与稳定确认"))
        decision.evidence.append(evidence("景深", "真实景深优先", portrait ? "单人主体已识别，但未测得可靠背景距离" : "合影或环境场景需要更多清晰范围",
            portrait ? "先让人物远离背景；只有可用深度遮罩时再考虑轻度虚化，不模糊头发和主体边缘" : "保留背景细节，不默认虚化"))
        decision.evidence.append(evidence("曝光与快门", "能力与时机", "固定光圈手机由系统自动曝光协调ISO与快门；本轮通过曝光补偿保护层次",
            !input.stable ? "手机仍在移动，暂停自动快门" : o.sharpness < 65 ? "主体细节不足，请稳住手机并确认对焦，暂不自动拍" : "继续保持：连续有效画面确认后触发快门，条件变化立即重判"))
        decision.evidence.append(contentsOf: mlGuidance)
        decision.ready = input.stable && !clipped && !decision.shouldZoom && abs(o.horizon) < 0.06 && o.sharpness >= 65 && o.brightness > 0.16 && o.brightness < 0.88
        let exposureLine = Self.exposureAdvice(brightness: o.brightness, highlights: o.highlights,
                                               subjectBrightness: o.subjectBrightness, bias: decision.exposureBias)
        let timingLine = Self.timingAdvice(stable: input.stable, sharpness: o.sharpness, horizon: o.horizon,
                                           shouldZoom: decision.shouldZoom, targetZoom: decision.targetZoom,
                                           person: person, eyesClosed: eyesClosed)
        decision.evidence.append(evidence("曝光", "实测亮度、亮部与曝光补偿", exposureLine.observation, exposureLine.action))
        decision.evidence.append(evidence("时机", "稳定、锐度、水平与变焦状态", timingLine.observation, timingLine.action))
        if let level = Self.levelEvidence(horizon: o.horizon) { decision.evidence.append(level) }
        // 机位量化：dx/dy 都是归一化偏差，文案统一写「机位…移动半步」。
        let idealX: Double
        if input.composition == "居中" { idealX = 0.5 }
        else if input.composition == "三分" { idealX = box.midX < 0.5 ? 1.0 / 3 : 2.0 / 3 }
        else { idealX = thirds ? (box.midX < 0.5 ? 1.0 / 3 : 2.0 / 3) : 0.5 }
        let dx = box.midX - idealX
        let dy = box.midY - 0.5
        let anchorName = abs(idealX - 0.5) < 0.001 ? "居中" : (idealX < 0.5 ? "左三分" : "右三分")
        var moves: [String] = []
        if abs(dx) >= 0.04 {
            let step = abs(dx) >= 0.18 ? "两步" : (abs(dx) >= 0.08 ? "半步" : "小半步")
            moves.append("主体" + (dx < 0 ? "偏左 " : "偏右 ") + fixed(abs(dx), digits: 2) + "，" + (dx < 0 ? "机位向右移动" : "机位向左移动") + step)
        }
        if abs(dy) >= 0.04 {
            moves.append("主体" + (dy > 0 ? "偏上 " : "偏下 ") + fixed(abs(dy), digits: 2) + "，" + (dy > 0 ? "略微下压机位" : "略微抬高机位"))
        }
        let positionAction: String
        if !moves.isEmpty {
            positionAction = moves.joined(separator: "；")
        } else if decision.shouldZoom && decision.targetZoom > zoom {
            let cm = max(10, min(150, Int(((desired / max(0.05, expectedOccupancy) - 1) * 100).rounded())))
            positionAction = "已自动推近至 " + fixed(decision.targetZoom, digits: 2) + "×，再靠近 " + String(cm) + "cm 更满"
        } else if decision.shouldZoom && decision.targetZoom < zoom {
            positionAction = "已自动拉远至 " + fixed(decision.targetZoom, digits: 2) + "×，也可后退半步让主体完整"
        } else if fraction < desired * 0.85 {
            let cm = max(10, min(150, Int(((desired / max(0.05, fraction) - 1) * 100).rounded())))
            positionAction = "构图在" + anchorName + "，但主体偏小（占高 " + fixed(fraction, digits: 2) + "）：再靠近 " + String(cm) + "cm"
        } else {
            positionAction = "构图已就位（" + anchorName + "），稳住 1 秒即自动拍摄"
        }
        decision.evidence.append(evidence("机位", "主体偏差与机位动作",
                                          "主体中心 (" + fixed(box.midX, digits: 2) + ", " + fixed(box.midY, digits: 2) + ")，目标 " + anchorName,
                                          positionAction))
        // blockers 最多 3 条，每条都是具体原因，与 ready 共用同一套判据。
        var blockers: [String] = []
        if !input.stable { blockers.append("机身未稳：靠住栏杆或双手夹紧，稳住 1 秒") }
        if clipped { blockers.append("主体贴边：后退 20cm 让人物完整入镜") }
        if abs(o.horizon) >= 0.06 {
            blockers.append("地平线" + (o.horizon > 0 ? "右倾 " : "左倾 ") + fixed(abs(o.horizon) * 180 / Double.pi, digits: 1) + "°：先转手机校平")
        }
        if o.sharpness < 65 { blockers.append("锐度 " + String(o.sharpness) + " 偏低：重新对焦或靠近 15cm") }
        if o.brightness <= 0.16 { blockers.append("亮度 " + fixed(o.brightness, digits: 2) + " 偏低：换向光位或补光") }
        if o.brightness >= 0.88 { blockers.append("亮度 " + fixed(o.brightness, digits: 2) + " 偏高：压低 0.3EV") }
        if decision.shouldZoom { blockers.append("正在变焦到 " + fixed(decision.targetZoom, digits: 2) + "×：等镜头到位") }
        decision.blockers = Array(blockers.prefix(3))
        return decision
    }
}

/// Temporal controller: smooth normalized/world occupancy, verify continuity, then dwell.
/// Smoothing measured height directly would lag behind our own zoom and cause hunting.
struct DirectorController {
    private var smoother: DirectorKalman?
    private var lastBox: DirectorBox?
    private var lastSignature = ""
    private var lastObservationTime = -Double.infinity
    private var lastZoomTime = -Double.infinity
    private var direction = 0
    private var streak = 0

    mutating func reset() {
        self = DirectorController()
        DirectorEngine.resetZoomGate()
    }
    mutating func evaluate(_ input: DirectorInput, now: Double, allowAutomaticZoom: Bool) -> DirectorDecision {
        var filtered = input
        guard let box = input.observation.subject, box.valid, input.observation.confidence >= 0.50 else {
            smoother = nil; lastBox = nil; streak = 0
            return DirectorEngine.evaluate(input, now: now)
        }
        let signature = input.scene + input.observation.subjectKind + String(input.observation.personCount)
        let discontinuity = signature != lastSignature || now - lastObservationTime > 0.8 || (lastBox.map { $0.overlap(box) < 0.25 } ?? true)
        let normalizedHeight = box.height / max(0.01, input.zoom)
        if discontinuity { smoother = DirectorKalman(estimate: normalizedHeight); streak = 0 }
        let smoothed = smoother?.update(normalizedHeight) ?? normalizedHeight
        var adjusted = box
        adjusted.height = max(0.01, min(1.5, smoothed * input.zoom))
        adjusted.y = box.midY - adjusted.height / 2
        filtered.observation.subject = adjusted
        lastSignature = signature; lastObservationTime = now; lastBox = box
        var decision = DirectorEngine.evaluate(filtered, now: now)
        // Keep the raw measured context for user feedback, never the smoothed estimate.
        decision.context = DirectorEngine.context(input)
        // The raw box always vetoes a crop, even if the smoother lags a fast approach.
        let rawPrediction = box.scaledAroundCenter(decision.targetZoom / max(0.01, input.zoom))
        if decision.targetZoom > input.zoom &&
            (rawPrediction.x < 0.05 || rawPrediction.maxX > 0.95 || rawPrediction.y < 0.05 || rawPrediction.maxY > 0.94) {
            decision.shouldZoom = false
            decision.targetZoom = input.zoom
        }
        let nextDirection = decision.targetZoom > input.zoom ? 1 : -1
        if !allowAutomaticZoom || !decision.shouldZoom {
            if decision.shouldZoom && !allowAutomaticZoom {
                decision.evidence.append(DirectorEvidence(domain: "拍摄技巧", rule: "自动控制门控", observation: "开关、手动接管或拍摄状态暂不允许变焦", action: "本轮保留建议，不执行自动变焦"))
            }
            streak = 0; decision.shouldZoom = false; return decision
        }
        streak = nextDirection == direction ? streak + 1 : 1
        direction = nextDirection
        if streak < 4 || now - lastZoomTime < 1.4 {
            decision.shouldZoom = false
            decision.evidence.append(DirectorEvidence(domain: "拍摄技巧", rule: "连续确认与冷却", observation: "候选取景正在确认或镜头尚在稳定", action: "等待后续画面，不立即重复变焦"))
            return decision
        }
        lastZoomTime = now; streak = 0
        DirectorEngine.noteZoomCommand(at: now)
        return decision
    }
}


enum DirectorKnowledge {
    static let domains: [(name: String, principles: String)] = [
        ("构图", "三分与居中并存；比较候选取景；检查边缘、留白与主体占比。"),
        ("光线色彩", "采样亮暗分布、主体与背景反差、饱和度和偏色线索；保护亮部、保留阴影；不把画面亮侧冒充光源方向。"),
        ("滤镜", "按场景选择风格；优先自然肤色；高饱和与人像降低强度；有足够反馈后使用同场景偏好。"),
        ("人物定位", "区分人脸、人体和多人；联合人物框；推近前保护完整人物和头顶空间。"),
        ("摄影技巧", "低光和手抖时停止推近；限制数字放大代价；主体丢失、切镜头或手动接管时暂停并重新确认。")
    ]
}

enum DirectorLicenses {
    static let smartcrop = """
Copyright (c) 2016 Jonas Wagner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
    static let kalman = """
MIT License

Copyright (c) 2019 WEAREREASONABLEPEOPLE B.V.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
}
