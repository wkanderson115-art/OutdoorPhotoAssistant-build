import Foundation

// MARK: - 建议模型
//
// 这里是单张精修页与批量精修台共用的「AI 修图建议」模型与规则引擎。
// 规则来自 `CommercialRetouchView` 里原本内联实现的那一套，逐条搬过来，阈值、
// 文案与失败计数口径完全一致，只是补了一个 `failureCount` 供批处理汇总使用。
// 本文件刻意只依赖 Foundation，方便在独立检查中直接调用。

enum AIEditSubjectMode: String, Equatable {
    case portrait
    case scene
    case product
    case document
}

/// 一条可执行的 AI 修图建议：指标 → 现象 → 建议动作 → 建议参数。
struct AIEditSuggestion: Identifiable, Equatable {
    let id = UUID()
    let metric: String        // 指标名，如「肤色 ΔE」
    let finding: String       // 现象，如「肤色 ΔE00 4.09，超过 3.00 上限」
    let action: String        // 建议动作，如「AI 阶段只做肤色自然化，禁止整体换色」
    let parameter: String     // 建议参数，如「肤色 ΔE 目标 ≤2.0；强度 ≤0.9；预设 商业自然」
}

/// 本地精修完成后产出的整套 AI 修图建议，含可直接发送给 Seedream 的提示词。
struct AIEditAdvice: Equatable {
    var items: [AIEditSuggestion]
    var prompt: String              // 可直接发送给 Seedream 的完整中文提示词
    var recommendedPresetID: String
    var recommendedStrength: Double
    var headline: String            // 一句话结论
    var failureCount: Int           // 未合规项数（决定建议强度与批次汇总口径）
    var sceneCategory: String       // 本次实际使用的摄影分类
    var subjectMode: String         // 人像 / 场景 / 商品建筑 / 文档
}

// MARK: - 规则引擎

enum AIEditAdvisor {

    /// 把一次质检报告翻译成可执行的 AI 修图建议。
    ///
    /// 11 条规则与 `CommercialRetouchView` 里的实现逐条对应：前 7 条按 `report.metrics`
    /// 的键判定（阈值：肤色 ΔE 3.0 / 1.5、裁切 0.0100 与 0.0020、纹理 0.50、接缝 0.30、
    /// SSIM 0.85），第 8 条看剩余瑕疵，第 9 条在质检通过时给 3 条增殖建议，第 10 条是
    /// 「未通过：」note 的兜底，第 11 条是全部不命中时的通用建议。
    /// 每个判定都带具体数值，不写空话。
    static func makeAdvice(report: RetouchQualityReport, look: RetouchLook, presetID: String,
                           strength: Double, spotsFound: Int, spotsRemaining: Int,
                           shootingMode: AIEditSubjectMode? = nil) -> AIEditAdvice {
        let scene = RetouchPresetCatalog.find(presetID).category
        let portraitScenes = ["人像摄影", "婚纱与情侣", "家庭与儿童", "时尚与穿搭"]
        let inferredPortrait = portraitScenes.contains(scene)
            || ((report.metrics["skin_tone_de"] ?? 0) > 0.01 && spotsFound > 0)
        let resolvedMode = shootingMode ?? (inferredPortrait ? .portrait : Self.defaultMode(for: scene))
        let isPortrait = resolvedMode == .portrait
        var items: [AIEditSuggestion] = []
        var failures = 0
        let metrics = report.metrics
        let notes = report.notes

        func add(metric: String, finding: String, action: String, parameter: String, failure: Bool) {
            if failure { failures += 1 }
            items.append(AIEditSuggestion(metric: metric, finding: finding,
                                          action: action, parameter: parameter))
        }

        // ① 肤色色差
        if isPortrait, let tone = metrics["skin_tone_de"] {
            if tone > 3.0 {
                add(metric: "肤色 ΔE",
                    finding: String(format: "肤色 ΔE00 %.2f，超过 3.00 上限", tone),
                    action: "AI 阶段只做肤色自然化、把色差拉回 ≤2.00，禁止整体换色或加暖色滤镜",
                    parameter: String(format: "肤色 ΔE 目标 ≤2.00（当前 %.2f）；强度 ≤0.85；预设选 商业自然", tone),
                    failure: true)
            } else if tone >= 1.5 {
                add(metric: "肤色 ΔE",
                    finding: String(format: "肤色微偏：ΔE00 %.2f，处在 1.50–3.00 临界区", tone),
                    action: "肤色微偏，AI 不要叠加任何暖色/橙色调，只做中性回正",
                    parameter: String(format: "肤色 ΔE 目标 ≤1.50（当前 %.2f）；强度 ≤0.90", tone),
                    failure: false)
            }
        } else if isPortrait, let note = noteFallback(notes, keyword: "ΔE00") {
            add(metric: "肤色 ΔE", finding: note,
                action: "AI 阶段只做肤色自然化、把色差拉回 ≤2.00，禁止整体换色或加暖色滤镜",
                parameter: "肤色 ΔE 目标 ≤2.00；强度 ≤0.85；预设选 商业自然",
                failure: true)
        }

        // ② 全图高光/死黑裁切
        if let clip = metrics["clipping_full"] {
            if clip > 0.0100 {
                add(metric: "整体裁切",
                    finding: String(format: "全图高光/死黑裁切 %.4f，超过 0.0100 上限", clip),
                    action: "高光/死黑溢出，AI 必须恢复高光与暗部层次，输出禁止出现纯白/纯黑",
                    parameter: String(format: "要求 AI 保留 1%%–99%% 动态范围（当前裁切 %.4f）；强度 ≤0.90", clip),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "全图高光") {
            add(metric: "整体裁切", finding: note,
                action: "高光/死黑溢出，AI 必须恢复高光与暗部层次，输出禁止出现纯白/纯黑",
                parameter: "要求 AI 保留 1%–99% 动态范围；强度 ≤0.90",
                failure: true)
        }

        // ③ 皮肤高光裁切
        if isPortrait, let clip = metrics["clipping_skin"] {
            if clip > 0.002 {
                add(metric: "肤色裁切",
                    finding: String(format: "皮肤高光/死黑裁切 %.4f，超过 0.0020 上限", clip),
                    action: "皮肤高光溢出，AI 压低皮肤高光、保留过渡，不许把皮肤压成灰面",
                    parameter: String(format: "皮肤高光裁切目标 ≤0.0015（当前 %.4f）；强度 ≤0.85", clip),
                    failure: true)
            }
        } else if isPortrait, let note = noteFallback(notes, keyword: "皮肤高光") {
            add(metric: "肤色裁切", finding: note,
                action: "皮肤高光溢出，AI 压低皮肤高光、保留过渡",
                parameter: "皮肤高光裁切目标 ≤0.0015；强度 ≤0.85",
                failure: true)
        }

        // ④ 磨皮过度
        if isPortrait, let texture = metrics["texture_retention"] {
            if texture < 0.50 {
                add(metric: "纹理保留",
                    finding: String(format: "纹理保留率 %.2f，低于 0.50 下限（磨皮过度）", texture),
                    action: "磨皮过度，AI 回补皮肤纹理与毛孔，禁止再磨皮",
                    parameter: String(format: "纹理保留目标 ≥0.55（当前 %.2f）；AI 阶段磨皮强度 0；强度 ≤0.80", texture),
                    failure: true)
            }
        } else if isPortrait, let note = noteFallback(notes, keyword: "皮肤纹理保留率") {
            add(metric: "纹理保留", finding: note,
                action: "磨皮过度，AI 回补皮肤纹理与毛孔，禁止再磨皮",
                parameter: "纹理保留目标 ≥0.55；AI 阶段磨皮强度 0；强度 ≤0.80",
                failure: true)
        }

        // ⑤ 蒙版接缝
        if let seam = metrics["seam_ratio"] {
            if abs(seam - 1.0) > 0.30 {
                add(metric: "接缝比例",
                    finding: String(format: "蒙版接缝梯度比 %.2f，偏离 1.00 达 %.2f（阈 0.30）", seam, abs(seam - 1.0)),
                    action: "接缝明显，AI 只做局部色调过渡，保留原有结构和纹理",
                    parameter: String(format: "接缝比目标 0.85–1.15（当前 %.2f）；禁止局部重绘；强度 ≤0.85", seam),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "接缝") {
            add(metric: "接缝比例", finding: note,
                action: "接缝明显，AI 只做局部色调过渡，保留原有结构和纹理",
                parameter: "接缝比目标 0.85–1.15；禁止局部重绘；强度 ≤0.85",
                failure: true)
        }

        // ⑥ 结构相似度
        if let ssim = metrics["ssim"] {
            if ssim < 0.85 {
                add(metric: "SSIM",
                    finding: String(format: "结构相似度 %.3f，低于 0.85 下限（改动过大）", ssim),
                    action: "改动过大，AI 只修复必要的局部光影和色彩，不改变主体结构与构图",
                    parameter: String(format: "SSIM 目标 ≥0.90（当前 %.3f）；强度 ≤0.80", ssim),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "结构相似度") {
            add(metric: "SSIM", finding: note,
                action: "改动过大，AI 只修复必要的局部光影和色彩，不改变主体结构与构图",
                parameter: "SSIM 目标 ≥0.90；强度 ≤0.80",
                failure: true)
        }

        // ⑦ 剩余瑕疵
        if isPortrait && spotsRemaining > 0 {
            add(metric: "剩余瑕疵",
                finding: "仍有 \(spotsRemaining) 处瑕疵未清理（本次检测 \(spotsFound) 处）",
                action: "AI 清理时避开眼周、唇线、发丝，只做小范围点修",
                parameter: "点修半径 ≤ 画面长边 0.5%；强度 ≤0.80",
                failure: !report.passed)
        }

        // ⑧ 已通过时按真实题材生成增强建议，不再所有照片都套人像式的
        // 「补光 / 背景 / 柔和锐化」三件套。
        if report.passed {
            for suggestion in Self.sceneEnhancements(for: scene, isPortrait: isPortrait) {
                add(metric: suggestion.metric, finding: suggestion.finding,
                    action: suggestion.action, parameter: suggestion.parameter,
                    failure: false)
            }
        }

        // ⑧.5 兜底：任何没被上面规则命中的「未通过：」note 也翻译成建议
        let usedFindings = Set(items.map { $0.finding })
        for note in notes where note.hasPrefix("未通过：") && !usedFindings.contains(note)
            && (isPortrait || !(note.contains("肤色") || note.contains("皮肤") || note.contains("毛孔") || note.contains("瑕疵"))) {
            add(metric: "质检未通过项", finding: note,
                action: "按该条不通过项限制 AI 改动范围，只修对应缺陷，其余保持不动",
                parameter: "对应指标拉回阈值内；强度 ≤0.85",
                failure: true)
        }

        // ⑨ 无任何命中
        if items.isEmpty {
            let tone = metrics["skin_tone_de"] ?? 0
            let retention = metrics["texture_retention"] ?? 0
            let ssim = metrics["ssim"] ?? 0
            add(metric: "综合",
                finding: isPortrait
                    ? String(format: "本地质检参考：肤色 ΔE %.2f、纹理保留 %.2f、SSIM %.3f", tone, retention, ssim)
                    : String(format: "本地质检参考：SSIM %.3f；按 %@ 场景进行克制调整", ssim, scene),
                action: "无需纠正，AI 只做氛围微调",
                parameter: "强度 ≤0.80",
                failure: false)
        }

        // 建议强度：未合规项越多越低，每项 -0.05，下限 0.70
        let rawStrength = report.passed ? strength : max(0.70, strength - 0.05 * Double(failures))
        let recommendedStrength = min(1.30, (rawStrength * 20).rounded() / 20)

        // 建议预设：肤色类失败优先换到「商业自然」（aiAllowed）预设
        var recommendedPresetID = presetID
        let toneFailed: Bool
        if let tone = metrics["skin_tone_de"] {
            toneFailed = tone > 3.0
        } else {
            toneFailed = noteFallback(notes, keyword: "ΔE00") != nil
        }
        if isPortrait && toneFailed, let commercial = RetouchPresetCatalog.all.first(where: { $0.look == .commercialNatural && $0.aiAllowed }) {
            recommendedPresetID = commercial.id
        }

        let presetName = RetouchPresetCatalog.find(recommendedPresetID).name
        let actions = items.map { $0.action }
        let corrections = actions.isEmpty ? "无需纠正，只做氛围微调" : actions.joined(separator: "；")
        let strengthText = String(format: "%.2f", recommendedStrength)
        let sceneInstructions = Self.sceneInstructions(for: scene, isPortrait: isPortrait)
        let prompt = "专业摄影后期。摄影类别：" + scene + "；预设：" + presetName + "。"
            + "场景专用要求：" + sceneInstructions + "；"
            + "本地质检发现的待处理项：" + corrections + "；"
            + "保持原图构图、尺寸、真实光源方向和主体结构；不得虚构丢失的细节，避免过度 HDR、锐化与饱和度。"
            + "建议强度 " + strengthText + "。"


        let headline = report.passed
            ? "本地已合规，AI 只做加强"
            : "本地未合规 \(failures) 项，以下是 AI 阶段的纠正清单"

        _ = look
        return AIEditAdvice(items: items, prompt: prompt,
                            recommendedPresetID: recommendedPresetID,
                            recommendedStrength: recommendedStrength,
                            headline: headline,
                            failureCount: failures,
                            sceneCategory: scene,
                            subjectMode: Self.modeName(resolvedMode))
    }

    private static func defaultMode(for scene: String) -> AIEditSubjectMode {
        switch scene {
        case "商品摄影", "建筑与室内", "汽车与机车", "静物与艺术": return .product
        case "文档与翻拍": return .document
        default: return .scene
        }
    }

    private static func modeName(_ mode: AIEditSubjectMode) -> String {
        switch mode {
        case .portrait: return "人物"
        case .scene: return "自然场景"
        case .product: return "商品／建筑"
        case .document: return "文档结构"
        }
    }

    private static func sceneInstructions(for scene: String, isPortrait: Bool) -> String {
        let person = isPortrait
            ? "画面已检测到人物，保持身份、五官、身体比例、真实肤色和皮肤纹理；人物保护优先于风格化。"
            : "画面未按人像处理，不执行磨皮、瘦脸、美白或五官重绘。"
        let sceneRule: String
        switch scene {
        case "建筑与室内":
            sceneRule = "以建筑实景为准，小幅校正透视和垂直线，平衡窗户、灯具与墙面高光，保护材质、线条、招牌文字和真实空间比例，禁止改变建筑结构。"
        case "风景摄影", "航拍与无人机":
            sceneRule = "保持地形、天空、云层、植被与建筑的真实关系，克制优化动态范围、远近层次和白平衡，不换天空、不制造阳光、不伪造地貌。"
        case "宠物与野生动物":
            sceneRule = "保护动物真实毛色、花纹、胡须、眼睛和身体比例，轻微优化毛发层次与背景噪点，不改变品种或生成毛发。"
        case "美食摄影":
            sceneRule = "保持菜品真实色泽、形状、份量与摆盘，校正偏色、油亮高光和餐具反射，不添加或替换食材。"
        case "商品摄影", "静物与艺术":
            sceneRule = "保持商品外形、商标、文字、材质和真实颜色，只处理光照、反射和背景色偏，不重绘标识或改变产品细节。"
        case "汽车与机车":
            sceneRule = "保护车身线条、品牌标识、车牌、轮毂和漆面真实颜色，克制处理反射与环境光，不改造车型。"
        case "星空与天文":
            sceneRule = "降低暗部噪点并控制点光源溢出，保留真实夜色、星点位置和天空渐变，不虚构星星或银河。"
        case "微距与植物":
            sceneRule = "保留植物或昆虫真实形态、纹理与颜色，控制景深边缘伪影和局部噪点，不生成不存在的微观细节。"
        case "运动与动作":
            sceneRule = "保持动作时序、肢体比例、器材和运动方向，只改善主体分离、快门噪点与局部曝光，不重画姿势。"
        case "演出与活动":
            sceneRule = "保留舞台灯光方向、现场色彩、观众与演出结构，控制高光溢出和暗部噪点，不增加灯束、烟雾或人物。"
        case "水下摄影":
            sceneRule = "校正水下偏色与雾化，保护水体层次、生物颜色和潜水者比例，不生成珊瑚、鱼群或不存在的清晰细节。"
        case "旅行与日常", "人文与街拍":
            sceneRule = "保持现场人物、街景、文字和光线关系，只做纪实式曝光、白平衡和噪点调整，不删除路人或改造环境。"
        case "文档与翻拍":
            sceneRule = "优先保证文字、线条和原始内容准确，只纠正透视、曝光、纸张色偏和阴影，禁止修改、生成或删除任何文字。"
        default:
            sceneRule = "保持画面主体、构图、原始结构和真实色彩，只修正可见的曝光、白平衡与噪点，不增删内容。"
        }
        return person + sceneRule
    }

    private static func sceneEnhancements(for scene: String, isPortrait: Bool)
        -> [(metric: String, finding: String, action: String, parameter: String)] {
        if isPortrait {
            return [
                ("人物光影", "本地质检已通过，可继续微调人物与环境光比", "只轻微平衡面部与环境曝光，保持主光方向", "人物曝光变化 ≤0.20 EV；禁止重塑五官"),
                ("肤质保护", "皮肤纹理已合格，继续处理容易产生塑料感", "保持毛孔、细纹和真实肤色，不再叠加磨皮与美白", "磨皮增量 0；肤色变化保持自然"),
                ("场景一致性", "人物与背景需要保持同一现场光线", "只清理噪点和小色块，不换背景、不删除人物", "背景改动 ≤5%；禁止生成内容")
            ]
        }
        switch scene {
        case "建筑与室内":
            return [
                ("建筑线条", "建筑主体应保持垂直线与真实透视", "只小幅校正倾斜，禁止移动门窗或改变楼体比例", "垂直线优先；几何改动 ≤2%"),
                ("窗景动态范围", "窗户与灯具高光仍可克制回收", "恢复可见高光层次，同时保留室内阴影关系", "曝光变化 ≤0.25 EV；禁止 HDR 光晕"),
                ("材质与文字", "墙面、玻璃、招牌文字是建筑真实性关键", "保护材质纹理和全部可读文字，不做生成式重绘", "锐化增量 0；文字结构完全保持")
            ]
        case "商品摄影", "静物与艺术":
            return [
                ("商品颜色", "商品真实色和材质需优先保持", "只校正白平衡与反射色偏，不改变商品颜色", "色相变化克制；饱和度增量 ≤5%"),
                ("边缘与标识", "轮廓、商标和文字不能被生成式修改", "保护边缘、标签和文字，禁止补画或替换", "结构完全保持；锐化增量 0"),
                ("背景洁净", "背景可做有限清理", "只处理灰尘、噪点和轻微色块，不改变陈列关系", "背景改动 ≤5%；不增删物体")
            ]
        case "风景摄影", "航拍与无人机", "星空与天文":
            return [
                ("天空真实性", "天空与地景关系已经合格", "只平衡天空高光与色阶，不替换天空或生成云星", "高光变化 ≤0.25 EV；禁止换天"),
                ("远近层次", "远景允许轻微去雾但不能制造细节", "克制提升层次和局部对比，保留真实能见度", "去雾与清晰度低强度；禁止 HDR"),
                ("自然色彩", "植被、水体和地貌颜色需保持真实", "只校正白平衡，避免过饱和与不自然青绿", "饱和度增量 ≤5%；不改地貌")
            ]
        default:
            return [
                ("主体结构", "本地质检已通过，主体结构无需重绘", "只做曝光、白平衡和层次微调，不增删内容", "结构保持；强度 ≤0.90"),
                ("高光阴影", "画面动态范围仍可小幅优化", "克制恢复高光与暗部层次，保持光源方向", "曝光变化 ≤0.25 EV；禁止 HDR 光晕"),
                ("细节控制", "本地已完成清晰度处理", "AI 阶段不再锐化，不虚构丢失细节", "锐化增量 0；禁止生成纹理")
            ]
        }
    }

    /// 从质检 notes 里捞兜底 finding：只认「未通过：」开头且含关键字的句子。
    static func noteFallback(_ notes: [String], keyword: String) -> String? {
        notes.first { $0.hasPrefix("未通过：") && $0.contains(keyword) }
    }

    // MARK: - 摘要

    /// 单张一句话摘要：
    /// 例 `未合规 2 项 · 建议强度 0.85 · 肤色 ΔE / 整体裁切`；
    /// 全部合规时是 `全部合规 · 建议强度 1.00 · 补光层次 / 背景干净度 / 锐化控制`。
    static func brief(_ advice: AIEditAdvice) -> String {
        let head = advice.failureCount > 0 ? "未合规 \(advice.failureCount) 项" : "全部合规"
        var seen = Set<String>()
        var metrics: [String] = []
        for item in advice.items where !seen.contains(item.metric) {
            seen.insert(item.metric)
            metrics.append(item.metric)
        }
        let metricText = metrics.isEmpty ? "无" : metrics.joined(separator: " / ")
        return head + " · 建议强度 " + String(format: "%.2f", advice.recommendedStrength)
            + " · " + metricText
    }

    /// 整批汇总：
    /// 例 `12 张中 5 张本地未合规（肤色 ΔE 3 张、整体裁切 2 张）；建议统一用「商业自然」+ 强度 0.85 跑一轮 AI`；
    /// 全合规时 `12 张本地全部合规，可按当前设置直接交付`。
    /// 指标清单按「出现在几张未合规照片上」从多到少取前 3 条。
    static func batchSummary(_ advices: [AIEditAdvice], photoCount: Int) -> String {
        let total = max(photoCount, advices.count)
        guard !advices.isEmpty else {
            return "还没有本地精修结果：先跑完本地精修，再为已处理照片生成 AI 修图建议"
        }
        let failing = advices.filter { $0.failureCount > 0 }
        if failing.isEmpty {
            return "\(total) 张本地全部合规，可按当前设置直接交付"
        }

        var metricCounts: [String: Int] = [:]
        for advice in failing {
            for metric in Set(advice.items.map { $0.metric }) {
                metricCounts[metric, default: 0] += 1
            }
        }
        let topMetrics = metricCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key) \($0.value) 张" }
            .joined(separator: "、")
        let metricText = topMetrics.isEmpty ? "未命中具体指标" : topMetrics

        let presetID = mostCommon(failing.map { $0.recommendedPresetID }) ?? failing[0].recommendedPresetID
        let presetName = RetouchPresetCatalog.find(presetID).name
        let strength = failing.map { $0.recommendedStrength }.min() ?? 0.85
        let strengthText = String(format: "%.2f", strength)
        return "\(total) 张中 \(failing.count) 张本地未合规（\(metricText)）；建议统一用「\(presetName)」+ 强度 \(strengthText) 跑一轮 AI"
    }

    /// 出现次数最多的值；并列时取先出现的那个，保证同一批次结果稳定。
    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for value in values {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        var best: String?
        var bestCount = 0
        for value in order {
            let count = counts[value] ?? 0
            if count > bestCount {
                best = value
                bestCount = count
            }
        }
        return best
    }
}
