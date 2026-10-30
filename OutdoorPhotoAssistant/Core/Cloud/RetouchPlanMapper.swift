import Foundation

// MARK: - Plan model

/// Local retouch plan translated from a cloud `PhotoAdvice`.
///
/// `RetouchPlan` is the boundary between the DeepSeek "photography brain"
/// (`PhotoAdvice`, produced by `DeepSeekClient.analyze`) and the on-device
/// `RetouchPipeline`. Nothing here talks to the network; it is pure data.
///
/// `stageAmounts` is the only field that is not part of the original six-field
/// contract: `RetouchPipeline` needs per-stage numbers (`smoothAmount`,
/// `blemishStrength`, ...) and `RetouchParameters` is not `Equatable`, so it
/// cannot live in an `Equatable` plan. `stageAmounts` carries those numbers as a
/// plain dictionary and the caller folds them into `preset.parameters`.
///
/// Stage vocabulary (documented contract, consumed by the caller):
///
/// | key                  | range        | how the caller applies it                                   |
/// |----------------------|--------------|-------------------------------------------------------------|
/// | smoothAmount         | 0...1 weight | `p.smoothAmount += w` (then clamp 0...1)                    |
/// | blemishStrength      | 0...1 weight | `p.blemishStrength += w` (then clamp 0...1)                 |
/// | dodgeBurnAmount      | 0...1 weight | `p.dodgeBurnAmount += w` (then clamp 0...1)                 |
/// | contrast             | 0...1 weight | `p.contrast += w * 0.15` (contrast baselines are ~1.04)     |
/// | clarityAmount        | 0...1 weight | `p.clarityAmount += w` (then clamp 0...1)                   |
/// | sharpenAmount        | 0...1 weight | `p.sharpenAmount += w` (then clamp 0...1)                   |
/// | highlightRolloff     | 0...1 weight | `p.highlightRolloff = max(0.72, p.highlightRolloff - w)`    |
/// | textureGain          | 0...1 weight | `p.textureGain = min(1, p.textureGain + w)`                 |
/// | skinProtectDECap     | absolute     | `p.skinProtectDE = min(p.skinProtectDE, cap)`               |
/// | backgroundCleanup    | 0...1 target | `adjustments.background.cleanupAmount` (already applied)    |
/// | faceWidth            | 0...1 target | `adjustments.reshape.faceWidth` (already applied)           |
/// | jawline              | 0...1 target | `adjustments.reshape.jawline` (already applied)             |
/// | eyeSize              | 0...1 target | `adjustments.reshape.eyeSize` (already applied)             |
/// | idPhoto              | marker 1.0   | present => ID-photo pipeline requested                      |
///
/// "weight" entries are additive hints, "target"/"marker" entries are absolute
/// values that the mapper already wrote into `adjustments`.
struct RetouchPlan: Equatable {
    var look: RetouchLook
    var adjustments: RetouchAdjustments
    var presetID: String
    /// Chinese, user-facing: what was seen -> what was changed. 2...6 entries.
    var reasons: [String]
    /// 0...1, derived from keyword hits and advice size.
    var confidence: Double
    /// True when the advice touches something the local engine cannot do safely
    /// (hair edges) or when `confidence` is below 0.55.
    var needsManualReview: Bool
    /// Per-stage numbers folded into `preset.parameters` by the caller.
    var stageAmounts: [String: Double] = [:]
}

// MARK: - Mapper

/// Translates `PhotoAdvice` into a `RetouchPlan`.
///
/// Mapping table (advice field -> destination):
///
/// | advice field          | destination                                                        |
/// |-----------------------|--------------------------------------------------------------------|
/// | `scene`               | `RetouchPlan.look`; also decides ID-photo / background deliverable  |
/// | `issues` + `editSteps`| `stageAmounts` (keyword weights, repeated hits add up, cap 1.0)     |
/// | `issues` + `editSteps`| `adjustments.reshape` (faceWidth / jawline / eyeSize)               |
/// | `issues` + `editSteps`| `adjustments.background` cleanup branch                             |
/// | `scene` + `issues` + `editSteps` | `cropToIDPhoto` / `idPhoto` / white-blue background       |
/// | `preserve`            | gentle mode: strength capped at 1.0, `skinProtectDECap` 2.0,        |
/// |                       | `textureGain + 0.15`                                                |
/// | `editSteps` count, text size | `confidence` (0.40...0.90) and `needsManualReview`          |
///
/// Scene -> look rules, evaluated in this exact order (first match wins):
///
/// | order | look              | Chinese / English keywords                                   |
/// |-------|-------------------|--------------------------------------------------------------|
/// | 1     | `cinematic`       | 黑白 纪实 街拍 胶片 复古 电影 · monochrome film street vintage  |
/// | 2     | `freshJapanese`   | 日系 清新 · japanese fresh                                    |
/// | 3     | `refinedPortrait` | 婚纱 写真 人像 · wedding portrait bride                       |
/// | 4     | `nightClear`      | 夜景 星空 · night starry astrophotography aurora              |
/// | 5     | `landscapeNatural`| 风光 建筑 航拍 旅行 · landscape architecture aerial travel    |
/// | 6     | `commercialNatural`| 商业 证件 电商 商品 · commercial product ecommerce idphoto   |
///
/// Matching is whitespace tolerant (`磨 皮` == `磨皮`) and case insensitive for
/// Latin text, so `"POR TRAIT"` matches `portrait`.
///
/// Explicit "want a strong look" words (`明显` `浓郁` `强烈` `大片` `电影感`
/// `胶片感`) raise strength by 0.10, the gentle words (`轻微` `轻度` `克制`
/// `保守`) lower it by 0.10, and `preserve` always caps it at 1.00. The result is
/// clamped to 0.60...1.15.
///
/// Hair (`发丝` `碎发` `刘海`) never produces a parameter: the local engine cannot
/// rebuild hair edges, so it only becomes a reason plus `needsManualReview`.
enum RetouchPlanMapper {

    // MARK: Public API

    static func map(advice: PhotoAdvice, preset: RetouchPreset) -> RetouchPlan {
        let stepTexts = advice.editSteps ?? []
        let corpus = normalize((stepTexts + advice.issues).joined(separator: " "))
        let styleCorpus = normalize((stepTexts + advice.issues + advice.recommendations).joined(separator: " "))
        let preserveCorpus = normalize(advice.preserve.joined(separator: " "))

        // 1. Look: scene decides, issues are only a fallback, then the operator's preset.
        let look = matchLook(scene: advice.scene, issues: advice.issues) ?? preset.look

        // 2. Stage weights from issues + edit steps.
        var stageAmounts = amounts(fromSteps: stepTexts, issues: advice.issues)

        // 3. Preserve => gentle mode.
        let preservedWords = matchedWords(in: preserveCorpus, words: preserveWords)
        let identityProtected = !preservedWords.isEmpty
        if identityProtected {
            stageAmounts["skinProtectDECap"] = 2.0
            stageAmounts["textureGain"] = (stageAmounts["textureGain"] ?? 0.0) + 0.15
        }

        // 4. Strength 0.60...1.15, capped at 1.00 when identity must be preserved.
        var strength = 1.0
        let wantsStrong = !matchedWords(in: styleCorpus, words: strongWords).isEmpty
        let wantsGentle = !matchedWords(in: styleCorpus, words: gentleWords).isEmpty
        if wantsStrong && !wantsGentle { strength += 0.10 }
        if wantsGentle && !wantsStrong { strength -= 0.10 }
        if identityProtected { strength = min(strength, 1.0) }
        strength = clamp(strength, 0.60, 1.15)
        strength = (strength * 100.0).rounded() / 100.0

        // 5. ID photo / background.
        // The deliverable type (ID photo) is a scene-level decision, so the scene
        // text participates here even though per-stage weights stay limited to
        // `issues` + `editSteps`.
        let idCorpus = normalize(advice.scene + " " + (stepTexts + advice.issues).joined(separator: " "))
        let idPhotoWanted = !matchedWords(in: idCorpus, words: idPhotoWords).isEmpty
        let wantsBlue = idCorpus.contains("蓝底") || idCorpus.contains("蓝背景")
        let wantsCleanup = !matchedWords(in: corpus, words: cleanupWords).isEmpty
        let spec = idPhotoSpec(in: idCorpus)

        // 6. Assemble adjustments.
        var adjustments = RetouchAdjustments()
        adjustments.presetID = preset.id
        adjustments.strength = strength
        adjustments.reshape.faceWidth = clamp01(stageAmounts["faceWidth"] ?? 0.0)
        adjustments.reshape.jawline = clamp01(stageAmounts["jawline"] ?? 0.0)
        adjustments.reshape.eyeSize = clamp01(stageAmounts["eyeSize"] ?? 0.0)

        if idPhotoWanted {
            adjustments.cropToIDPhoto = true
            adjustments.idPhoto = spec
            stageAmounts["idPhoto"] = 1.0
            // A dedicated ID-photo background replaces the old one, so a "背景"
            // keyword must not also pull in the cleaner stage.
            stageAmounts.removeValue(forKey: "backgroundCleanup")
            if wantsBlue {
                adjustments.background = BackgroundOptions.studioBlue
            } else {
                adjustments.background = BackgroundOptions.white
            }
        } else if wantsCleanup {
            var background = BackgroundOptions()
            background.kind = .clean
            let cleanup = clamp01(stageAmounts["backgroundCleanup"] ?? 0.50)
            background.cleanupAmount = cleanup
            adjustments.background = background
            stageAmounts["backgroundCleanup"] = cleanup
        }

        // 7. Confidence + manual review.
        let confidence = confidenceValue(advice: advice, stageAmounts: stageAmounts, hasSteps: !stepTexts.isEmpty)
        let uncertainWords = matchedWords(in: corpus, words: manualReviewWords)
        let needsManualReview = confidence < 0.55 || !uncertainWords.isEmpty

        // 8. Reasons: 2...6 Chinese lines, no English slider names.
        var reasons: [String] = []
        reasons.append("场景判定为「" + shortScene(advice.scene) + "」→ 采用" + look.displayName)
        reasons.append(contentsOf: stageReasons(stageAmounts: stageAmounts, limit: 3))
        if identityProtected {
            reasons.append("你要求保留" + preservedWords.prefix(3).joined(separator: "、")
                + " → 强度上限压到 1.00，纹理保留 +15%，肤色保护上限 2.00")
        }
        if !uncertainWords.isEmpty {
            reasons.append("提到" + uncertainWords.prefix(2).joined(separator: "、")
                + " → 本地引擎不做发丝边缘重绘，已标记人工复核")
        }
        if idPhotoWanted {
            reasons.append("识别为证件照 → 按" + idPhotoName(spec)
                + "规格裁切并套用" + (wantsBlue ? "蓝底" : "白底") + "背景")
        } else if wantsCleanup {
            reasons.append("看到背景干扰 → 背景清理 " + percent(clamp01(stageAmounts["backgroundCleanup"] ?? 0.0)))
        }
        let reshapeReason = reshapeText(adjustments: adjustments)
        if !reshapeReason.isEmpty { reasons.append(reshapeReason) }
        if strength > 1.0 {
            reasons.append("AI 建议的风格偏明显 → 强度 " + twoDecimals(strength) + "（量程 0.60 至 1.15）")
        } else if strength < 1.0 {
            reasons.append("AI 建议克制处理 → 强度 " + twoDecimals(strength) + "（量程 0.60 至 1.15）")
        }
        if reasons.count > 6 { reasons = Array(reasons.prefix(6)) }
        if reasons.count < 2 {
            reasons.append("没有可量化的具体问题 → 沿用预设 " + preset.id + " 的画面风格，不做额外处理")
        }
        if reasons.count < 2 {
            reasons.append("参数保守，建议人工确认一次")
        }

        let cleanedAmounts = stageAmounts.filter { $0.value > 0.0 }

        return RetouchPlan(look: look,
                           adjustments: adjustments,
                           presetID: preset.id,
                           reasons: reasons,
                           confidence: confidence,
                           needsManualReview: needsManualReview,
                           stageAmounts: cleanedAmounts)
    }

    /// Public scene -> look mapping. Unknown scenes fall back to `commercialNatural`.
    static func look(forScene scene: String, issues: [String]) -> RetouchLook {
        return matchLook(scene: scene, issues: issues) ?? .commercialNatural
    }

    /// Keyword weights from `editSteps` + `issues`. Repeated hits add up, each key
    /// is capped at 1.0, and keys that never matched are absent from the result.
    static func amounts(fromSteps steps: [String], issues: [String]) -> [String: Double] {
        let corpus = normalize((steps + issues).joined(separator: " "))
        var result: [String: Double] = [:]
        for rule in amountRules {
            let hits = occurrences(of: rule.word, in: corpus)
            if hits > 0 {
                result[rule.key] = (result[rule.key] ?? 0.0) + Double(hits) * rule.weight
            }
        }
        var capped: [String: Double] = [:]
        for (key, value) in result {
            capped[key] = min(1.0, value)
        }
        return capped
    }

    /// One-line-per-reason Chinese summary for the review sheet.
    static func summary(_ plan: RetouchPlan) -> String {
        var lines: [String] = []
        var head = "方案：" + plan.look.displayName
            + "（预设 " + plan.presetID + "）"
            + " · 强度 " + twoDecimals(plan.adjustments.strength)
            + " · 置信 " + twoDecimals(plan.confidence)
        if plan.needsManualReview { head += " · 需人工复核" }
        lines.append(head)
        var index = 1
        for reason in plan.reasons {
            lines.append("\(index). " + reason)
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Look rules

    private struct LookRule {
        let look: RetouchLook
        let words: [String]
    }

    private static let lookRules: [LookRule] = [
        LookRule(look: .cinematic, words: ["黑白", "纪实", "街拍", "胶片", "复古", "电影",
                                           "monochrome", "blackandwhite", "grayscale", "film",
                                           "vintage", "street", "cinematic"]),
        LookRule(look: .freshJapanese, words: ["日系", "清新", "japanese", "fresh"]),
        LookRule(look: .refinedPortrait, words: ["婚纱", "写真", "人像", "wedding", "portrait", "bride"]),
        LookRule(look: .nightClear, words: ["夜景", "星空", "night", "starry", "astrophotography", "aurora"]),
        LookRule(look: .landscapeNatural, words: ["风光", "建筑", "航拍", "旅行",
                                                  "landscape", "architecture", "aerial", "travel", "scenery"]),
        LookRule(look: .commercialNatural, words: ["商业", "证件", "电商", "商品",
                                                   "commercial", "product", "ecommerce", "idphoto", "lookbook"])
    ]

    private static func matchLook(scene: String, issues: [String]) -> RetouchLook? {
        let sceneText = normalize(scene)
        for rule in lookRules {
            for word in rule.words where sceneText.contains(word) {
                return rule.look
            }
        }
        let issueText = normalize(issues.joined(separator: " "))
        for rule in lookRules {
            for word in rule.words where issueText.contains(word) {
                return rule.look
            }
        }
        return nil
    }

    // MARK: Amount rules

    private struct AmountRule {
        let key: String
        let word: String
        let weight: Double
    }

    /// Every keyword the cloud advice may use, with the stage it drives and how
    /// much weight one hit adds. Several keywords can target the same stage.
    private static let amountRules: [AmountRule] = [
        // skin texture -> smoothAmount
        AmountRule(key: "smoothAmount", word: "磨皮", weight: 0.10),
        AmountRule(key: "smoothAmount", word: "肤质", weight: 0.08),
        AmountRule(key: "smoothAmount", word: "毛孔", weight: 0.08),
        AmountRule(key: "smoothAmount", word: "均匀", weight: 0.06),
        AmountRule(key: "smoothAmount", word: "细腻", weight: 0.06),
        AmountRule(key: "smoothAmount", word: "平滑", weight: 0.06),
        // temporary blemishes -> blemishStrength
        AmountRule(key: "blemishStrength", word: "痘", weight: 0.12),
        AmountRule(key: "blemishStrength", word: "斑", weight: 0.10),
        AmountRule(key: "blemishStrength", word: "痣", weight: 0.05),
        AmountRule(key: "blemishStrength", word: "瑕疵", weight: 0.12),
        AmountRule(key: "blemishStrength", word: "印记", weight: 0.10),
        // light shaping -> dodgeBurnAmount (+ contrast)
        AmountRule(key: "dodgeBurnAmount", word: "光影", weight: 0.10),
        AmountRule(key: "dodgeBurnAmount", word: "立体", weight: 0.10),
        AmountRule(key: "dodgeBurnAmount", word: "暗沉", weight: 0.08),
        AmountRule(key: "dodgeBurnAmount", word: "提亮", weight: 0.08),
        AmountRule(key: "contrast", word: "光影", weight: 0.04),
        AmountRule(key: "contrast", word: "立体", weight: 0.04),
        AmountRule(key: "contrast", word: "暗沉", weight: 0.04),
        AmountRule(key: "contrast", word: "提亮", weight: 0.03),
        // clarity -> clarityAmount + sharpenAmount
        AmountRule(key: "clarityAmount", word: "通透", weight: 0.12),
        AmountRule(key: "clarityAmount", word: "清晰", weight: 0.10),
        AmountRule(key: "clarityAmount", word: "锐利", weight: 0.08),
        AmountRule(key: "clarityAmount", word: "细节", weight: 0.06),
        AmountRule(key: "sharpenAmount", word: "通透", weight: 0.10),
        AmountRule(key: "sharpenAmount", word: "清晰", weight: 0.09),
        AmountRule(key: "sharpenAmount", word: "锐利", weight: 0.10),
        AmountRule(key: "sharpenAmount", word: "细节", weight: 0.08),
        // oily highlights -> highlightRolloff
        AmountRule(key: "highlightRolloff", word: "油光", weight: 0.15),
        AmountRule(key: "highlightRolloff", word: "高光", weight: 0.12),
        AmountRule(key: "highlightRolloff", word: "反光", weight: 0.10),
        // background -> backgroundCleanup
        AmountRule(key: "backgroundCleanup", word: "背景", weight: 0.35),
        AmountRule(key: "backgroundCleanup", word: "杂物", weight: 0.40),
        AmountRule(key: "backgroundCleanup", word: "换底", weight: 0.60),
        AmountRule(key: "backgroundCleanup", word: "去背", weight: 0.60),
        // liquify -> reshape targets
        AmountRule(key: "faceWidth", word: "瘦脸", weight: 0.25),
        AmountRule(key: "faceWidth", word: "脸型", weight: 0.20),
        AmountRule(key: "faceWidth", word: "下颌", weight: 0.15),
        AmountRule(key: "jawline", word: "下颌", weight: 0.25),
        AmountRule(key: "jawline", word: "脸型", weight: 0.15),
        AmountRule(key: "jawline", word: "瘦脸", weight: 0.10),
        AmountRule(key: "eyeSize", word: "大眼", weight: 0.25)
    ]

    // MARK: Keyword sets

    /// `preserve` words that force the gentle profile.
    private static let preserveWords = ["身份", "五官", "痣", "雀斑", "纹身", "发丝"]

    /// Words the local engine cannot act on safely: they only flag manual review.
    private static let manualReviewWords = ["发丝", "碎发", "刘海"]

    /// Strong-style words (raise strength by one step).
    private static let strongWords = ["明显", "浓郁", "强烈", "大片", "电影感", "胶片感"]

    /// Gentle words (lower strength by one step).
    private static let gentleWords = ["轻微", "轻度", "克制", "保守"]

    /// ID-photo requests (a bare size/type name already means "ID photo").
    private static let idPhotoWords = ["证件照", "证件", "白底", "蓝底", "红底", "签证照", "护照照",
                                       "一寸", "二寸", "护照", "签证", "美签",
                                       "idphoto", "passportphoto"]

    /// Background cleanup requests.
    private static let cleanupWords = ["背景", "杂物", "换底", "去背"]

    private static func idPhotoSpec(in corpus: String) -> IDPhotoSpec {
        if corpus.contains("护照") { return .passport }
        if corpus.contains("美签") || corpus.contains("签证") { return .visaUS }
        if corpus.contains("二寸") { return .twoInch }
        return .oneInch
    }

    private static func idPhotoName(_ spec: IDPhotoSpec) -> String {
        switch spec {
        case .oneInch: return "一寸"
        case .twoInch: return "二寸"
        case .passport: return "护照"
        case .visaUS: return "美签"
        case .smallOneInch: return "小一寸"
        case .smallTwoInch: return "小二寸"
        case .custom: return "自定义"
        }
    }

    // MARK: Reason building

    private struct StageReason {
        let key: String
        let observed: String
        let action: String
    }

    /// Fixed table so reasons stay stable across runs (no dictionary iteration order).
    private static let stageReasonTable: [StageReason] = [
        StageReason(key: "smoothAmount", observed: "肤色不均、毛孔明显", action: "磨皮 "),
        StageReason(key: "blemishStrength", observed: "临时痘印斑点", action: "祛瑕 "),
        StageReason(key: "dodgeBurnAmount", observed: "面部光影偏平", action: "局部明暗 "),
        StageReason(key: "contrast", observed: "画面发灰", action: "对比 "),
        StageReason(key: "clarityAmount", observed: "画面不够通透", action: "通透 "),
        StageReason(key: "sharpenAmount", observed: "边缘细节偏软", action: "锐化 "),
        StageReason(key: "highlightRolloff", observed: "油光与高光反光", action: "高光压制 "),
        StageReason(key: "backgroundCleanup", observed: "背景杂物干扰", action: "背景清理 ")
    ]

    private static func stageReasons(stageAmounts: [String: Double], limit: Int) -> [String] {
        var entries: [(index: Int, reason: String, amount: Double)] = []
        for (index, stage) in stageReasonTable.enumerated() {
            guard let amount = stageAmounts[stage.key], amount > 0.0 else { continue }
            entries.append((index, "看到" + stage.observed + " → " + stage.action + percent(amount), amount))
        }
        entries.sort { lhs, rhs in
            if lhs.amount == rhs.amount { return lhs.index < rhs.index }
            return lhs.amount > rhs.amount
        }
        var reasons: [String] = []
        for entry in entries.prefix(limit) {
            reasons.append(entry.reason)
        }
        return reasons
    }

    private static func reshapeText(adjustments: RetouchAdjustments) -> String {
        let face = adjustments.reshape.faceWidth
        let jaw = adjustments.reshape.jawline
        let eye = adjustments.reshape.eyeSize
        if face <= 0.0 && jaw <= 0.0 && eye <= 0.0 { return "" }
        var parts: [String] = []
        var observed: [String] = []
        if face > 0.0 { parts.append("脸型 " + percent(face)); observed.append("脸型") }
        if jaw > 0.0 { parts.append("下颌 " + percent(jaw)); observed.append("下颌") }
        if eye > 0.0 { parts.append("眼睛 " + percent(eye)); observed.append("眼睛") }
        return "看到" + observed.joined(separator: "、") + "被点名 → 液化 " + parts.joined(separator: "、")
            + "（位移上限 6% 由本地引擎兜底）"
    }

    // MARK: Confidence

    private static func confidenceValue(advice: PhotoAdvice, stageAmounts: [String: Double],
                                       hasSteps: Bool) -> Double {
        var actionable = 0
        for key in stageAmounts.keys where key != "skinProtectDECap" && key != "textureGain" {
            actionable += 1
        }
        var characters = advice.scene.count + advice.editPrompt.count
        characters += advice.understanding?.count ?? 0
        for text in advice.issues { characters += text.count }
        for text in advice.editSteps ?? [] { characters += text.count }
        for text in advice.recommendations { characters += text.count }
        for text in advice.preserve { characters += text.count }

        var value = 0.40
        value += 0.06 * Double(min(actionable, 5))
        if hasSteps { value += 0.08 }
        value += min(0.12, (Double(characters) / 900.0) * 0.12)
        value = clamp(value, 0.40, 0.90)
        return (value * 100.0).rounded() / 100.0
    }

    // MARK: Text helpers

    /// Removes all whitespace and lowercases Latin text so "磨 皮" and "磨皮"
    /// are the same token and "POR TRAIT" matches "portrait".
    private static func normalize(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text.lowercased() where !character.isWhitespace {
            output.append(character)
        }
        return output
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack[haystack.startIndex...]
        while let range = search.range(of: needle) {
            count += 1
            search = search[range.upperBound...]
        }
        return count
    }

    private static func matchedWords(in corpus: String, words: [String]) -> [String] {
        var hits: [String] = []
        for word in words where corpus.contains(word) {
            hits.append(word)
        }
        return hits
    }

    private static func shortScene(_ scene: String) -> String {
        let trimmed = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "未描述" }
        if trimmed.count <= 18 { return trimmed }
        return String(trimmed.prefix(18)) + "…"
    }

    private static func percent(_ value: Double) -> String {
        return "+" + String(format: "%.0f", value * 100.0) + "%"
    }

    private static func twoDecimals(_ value: Double) -> String {
        return String(format: "%.2f", value)
    }

    private static func clamp01(_ value: Double) -> Double {
        return clamp(value, 0.0, 1.0)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }
}
