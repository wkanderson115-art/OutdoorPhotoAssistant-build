import Foundation

// MARK: - Preset model

/// A catalogue preset = one look plus a concrete, tuned parameter block.
///
/// `RetouchLook` and `RetouchParameters` live in `RetouchParameters.swift` and do
/// not declare `Codable`/`Hashable`, and Swift can only synthesise those
/// conformances in the file that declares the type, so both are implemented here
/// explicitly:
/// - identity / hashing is the stable `id` string,
/// - the numeric parameter block round-trips as `[String: Double]`.
struct RetouchPreset: Identifiable, Codable, Hashable {
    let id: String
    let category: String
    let name: String
    let look: RetouchLook
    let aiAllowed: Bool
    let parameters: RetouchParameters

    init(id: String, category: String, name: String, look: RetouchLook,
         aiAllowed: Bool, parameters: RetouchParameters) {
        self.id = id
        self.category = category
        self.name = name
        self.look = look
        self.aiAllowed = aiAllowed
        self.parameters = parameters
    }

    // MARK: Hashable

    static func == (lhs: RetouchPreset, rhs: RetouchPreset) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, category, name, look, aiAllowed, parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let category = try container.decodeIfPresent(String.self, forKey: .category) ?? "人像摄影"
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        let lookName = try container.decodeIfPresent(String.self, forKey: .look) ?? RetouchLook.commercialNatural.rawValue
        let look = RetouchLook(rawValue: lookName) ?? .commercialNatural
        let aiAllowed = try container.decodeIfPresent(Bool.self, forKey: .aiAllowed) ?? true
        let stored = try container.decodeIfPresent([String: Double].self, forKey: .parameters)
        let base = RetouchParameters.preset(look: look, category: category)
        self.init(id: id, category: category, name: name, look: look, aiAllowed: aiAllowed,
                  parameters: RetouchPreset.apply(stored ?? [:], to: base))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(category, forKey: .category)
        try container.encode(name, forKey: .name)
        try container.encode(look.rawValue, forKey: .look)
        try container.encode(aiAllowed, forKey: .aiAllowed)
        try container.encode(RetouchPreset.dictionary(of: parameters), forKey: .parameters)
    }

    /// Flattens the parameter struct into `[String: Double]` without a hand-written
    /// coding-key list, so a newly tuned field in the lab is persisted automatically.
    private static func dictionary(of parameters: RetouchParameters) -> [String: Double] {
        var output: [String: Double] = [:]
        for child in Mirror(reflecting: parameters).children {
            guard let key = child.label else { continue }
            if let value = child.value as? Double {
                output[key] = value
            } else if let value = child.value as? Int {
                output[key] = Double(value)
            }
        }
        return output
    }

    /// Rebuilds a parameter block from the flattened dictionary, keeping the
    /// look/category defaults for any key a newer or older build did not persist.
    private static func apply(_ values: [String: Double], to base: RetouchParameters) -> RetouchParameters {
        var p = base
        for (key, value) in values {
            switch key {
            case "smoothRadius": p.smoothRadius = value
            case "smoothAmount": p.smoothAmount = value
            case "textureGain": p.textureGain = value
            case "colorEvenAmount": p.colorEvenAmount = value
            case "colorEvenRadius": p.colorEvenRadius = value
            case "dodgeBurnAmount": p.dodgeBurnAmount = value
            case "dodgeBurnRadius": p.dodgeBurnRadius = value
            case "dodgeBurnClip": p.dodgeBurnClip = value
            case "skinToneAmount": p.skinToneAmount = value
            case "blemishStrength": p.blemishStrength = value
            case "blemishSensitivity": p.blemishSensitivity = value
            case "eyeAmount": p.eyeAmount = value
            case "teethAmount": p.teethAmount = value
            case "underEyeAmount": p.underEyeAmount = value
            case "lipAmount": p.lipAmount = value
            case "clarityAmount": p.clarityAmount = value
            case "clarityRadius": p.clarityRadius = value
            case "sharpenRadius": p.sharpenRadius = value
            case "sharpenAmount": p.sharpenAmount = value
            case "sharpenThreshold": p.sharpenThreshold = value
            case "exposureTarget": p.exposureTarget = value
            case "maxExposureEV": p.maxExposureEV = value
            case "highlightRolloff": p.highlightRolloff = value
            case "shadowLift": p.shadowLift = value
            case "contrast": p.contrast = value
            case "vibrance": p.vibrance = value
            case "saturation": p.saturation = value
            case "lutStrength": p.lutStrength = value
            case "grain": p.grain = value
            case "vignette": p.vignette = value
            case "skinProtectDE": p.skinProtectDE = value
            case "maxPasses": p.maxPasses = max(1, Int(value.rounded()))
            default: break
            }
        }
        return p
    }
}

// MARK: - Engine choice

enum RetouchEngineChoice: String, CaseIterable, Identifiable {
    case local = "本地专业精修"
    case seedream = "Seedream AI 精修"
    case dual = "双引擎智能融合"
    var id: String { rawValue }
}

// MARK: - Catalogue

/// 80 presets, 20 categories. Each preset starts from
/// `RetouchParameters.preset(look:category:)` and then applies a small explicit
/// delta set, so no two presets are numerically identical.
///
/// Deltas stay inside the envelope measured in `tools/retouch_lab`:
/// smoothAmount 0.40–0.65 · dodgeBurnAmount 0.15–0.42 · contrast 0.98–1.12 ·
/// exposureTarget 0.47–0.60 · sharpenAmount 0.10–0.36 · lutStrength 0.25–0.58.
/// Product / architecture / document categories intentionally keep the portrait
/// stages at 0 (from `preset(look:category:)`) and sharpen hard, which is why
/// those presets carry no smooth/dodge deltas.
enum RetouchPresetCatalog {
    static let all: [RetouchPreset] = [

        // MARK: 人像摄影
        make("p01", "人像摄影", "商业自然", .commercialNatural, ai: true,
             smooth: 0.50, textureGain: 0.86, dodgeBurn: 0.24, lut: 0.36),
        make("p02", "人像摄影", "精致写真", .refinedPortrait, ai: true,
             smooth: 0.60, textureGain: 0.82, dodgeBurn: 0.40, lut: 0.42),
        make("p03", "人像摄影", "清新日系", .freshJapanese, ai: true,
             contrast: 0.98, exposure: 0.60, shadowLift: 0.20, lut: 0.42),
        make("p04", "人像摄影", "电影人像", .cinematic, ai: true,
             contrast: 1.12, shadowLift: 0.15, lut: 0.55),
        make("p05", "人像摄影", "商务肖像", .commercialNatural, ai: true,
             smooth: 0.46, dodgeBurn: 0.22, sharpen: 0.20, lut: 0.32),
        make("p06", "人像摄影", "暖光情绪", .cinematic, ai: true,
             contrast: 1.06, shadowLift: 0.14, lut: 0.40, vibrance: 0.06),

        // MARK: 婚纱与情侣
        make("p07", "婚纱与情侣", "浪漫婚纱", .refinedPortrait, ai: true,
             smooth: 0.62, dodgeBurn: 0.38, exposure: 0.56, lut: 0.44),
        make("p08", "婚纱与情侣", "婚礼纪实", .cinematic, ai: false,
             contrast: 1.06, shadowLift: 0.18, lut: 0.34),
        make("p09", "婚纱与情侣", "情侣写真", .refinedPortrait, ai: true,
             smooth: 0.56, dodgeBurn: 0.34, lut: 0.40, vibrance: 0.07),
        make("p10", "婚纱与情侣", "复古胶片", .cinematic, ai: true,
             contrast: 1.08, lut: 0.52, grain: 0.030),

        // MARK: 家庭与儿童
        make("p11", "家庭与儿童", "家庭合影", .commercialNatural, ai: true,
             smooth: 0.48, dodgeBurn: 0.26, lut: 0.36),
        make("p12", "家庭与儿童", "儿童抓拍", .freshJapanese, ai: true,
             smooth: 0.58, exposure: 0.58, shadowLift: 0.20),
        make("p13", "家庭与儿童", "亲子写真", .freshJapanese, ai: true,
             exposure: 0.57, shadowLift: 0.19, vibrance: 0.07),
        make("p14", "家庭与儿童", "新生儿柔光", .freshJapanese, ai: true,
             smooth: 0.64, contrast: 0.98, exposure: 0.59, shadowLift: 0.22),

        // MARK: 时尚与穿搭
        make("p15", "时尚与穿搭", "时尚大片", .cinematic, ai: true,
             contrast: 1.10, clarity: 0.12, lut: 0.50),
        make("p16", "时尚与穿搭", "街头穿搭", .cinematic, ai: true,
             contrast: 1.09, lut: 0.46, vibrance: 0.04),
        make("p17", "时尚与穿搭", "服装电商", .commercialNatural, ai: true,
             smooth: 0.44, dodgeBurn: 0.20, sharpen: 0.24, lut: 0.30),
        make("p18", "时尚与穿搭", "杂志封面", .refinedPortrait, ai: true,
             smooth: 0.60, dodgeBurn: 0.42, contrast: 1.06, lut: 0.48),

        // MARK: 人文与街拍
        make("p19", "人文与街拍", "街头纪实", .cinematic, ai: false,
             contrast: 1.08, lut: 0.32, vibrance: 0.03),
        make("p20", "人文与街拍", "人文故事", .cinematic, ai: false,
             contrast: 1.10, shadowLift: 0.18, lut: 0.38),
        make("p21", "人文与街拍", "黑白纪实", .cinematic, ai: false,
             contrast: 1.12, lut: 0.36, saturation: 0.0),

        // MARK: 运动与动作
        make("p22", "运动与动作", "高速抓拍", .commercialNatural, ai: true,
             smooth: 0.44, sharpen: 0.28, clarity: 0.14, lut: 0.30),
        make("p23", "运动与动作", "运动赛事", .commercialNatural, ai: true,
             smooth: 0.42, contrast: 1.08, sharpen: 0.30, vibrance: 0.10),
        make("p24", "运动与动作", "动感追焦", .cinematic, ai: true,
             contrast: 1.10, clarity: 0.16, lut: 0.44),

        // MARK: 风景摄影
        make("p25", "风景摄影", "自然风光", .landscapeNatural, ai: false,
             sharpen: 0.30, clarity: 0.18, lut: 0.28, vibrance: 0.11),
        make("p26", "风景摄影", "商业风光", .landscapeNatural, ai: true,
             sharpen: 0.32, clarity: 0.20, lut: 0.34, vibrance: 0.10),
        make("p27", "风景摄影", "城市纪实", .cinematic, ai: false,
             contrast: 1.08, clarity: 0.15, lut: 0.36),
        make("p28", "风景摄影", "黄金时刻", .landscapeNatural, ai: true,
             contrast: 1.06, shadowLift: 0.14, lut: 0.36, vibrance: 0.12),
        make("p29", "风景摄影", "夜景通透", .nightClear, ai: true,
             shadowLift: 0.28, clarity: 0.14, lut: 0.30),

        // MARK: 宠物与野生动物
        make("p30", "宠物与野生动物", "宠物写真", .commercialNatural, ai: true,
             smooth: 0.50, dodgeBurn: 0.26, sharpen: 0.22),
        make("p31", "宠物与野生动物", "户外活力", .freshJapanese, ai: true,
             exposure: 0.58, sharpen: 0.22, vibrance: 0.10),
        make("p32", "宠物与野生动物", "温馨日常", .commercialNatural, ai: true,
             smooth: 0.52, dodgeBurn: 0.24, lut: 0.32),
        make("p33", "宠物与野生动物", "野生动物", .landscapeNatural, ai: false,
             sharpen: 0.32, clarity: 0.16, vibrance: 0.08),

        // MARK: 微距与植物
        make("p34", "微距与植物", "花卉微距", .landscapeNatural, ai: true,
             sharpen: 0.28, clarity: 0.18, vibrance: 0.12),
        make("p35", "微距与植物", "昆虫微距", .landscapeNatural, ai: true,
             sharpen: 0.32, clarity: 0.16, vibrance: 0.06),
        make("p36", "微距与植物", "露珠细节", .landscapeNatural, ai: true,
             sharpen: 0.30, clarity: 0.20, vibrance: 0.05),
        make("p37", "微距与植物", "植物图鉴", .landscapeNatural, ai: true,
             sharpen: 0.28, clarity: 0.14, lut: 0.26, vibrance: 0.08),

        // MARK: 星空与天文（类别基线已关闭磨皮）
        make("p38", "星空与天文", "银河星空", .nightClear, ai: true,
             contrast: 1.02, exposure: 0.47, shadowLift: 0.24, sharpen: 0.12),
        make("p39", "星空与天文", "星轨长曝", .nightClear, ai: true,
             contrast: 1.04, exposure: 0.48, shadowLift: 0.22, sharpen: 0.10),
        make("p40", "星空与天文", "月亮摄影", .nightClear, ai: true,
             contrast: 1.10, exposure: 0.47, shadowLift: 0.12, sharpen: 0.16),
        make("p41", "星空与天文", "极光夜空", .nightClear, ai: true,
             exposure: 0.47, shadowLift: 0.26, sharpen: 0.11, vibrance: 0.10),

        // MARK: 航拍与无人机
        make("p42", "航拍与无人机", "自然航拍", .landscapeNatural, ai: true,
             sharpen: 0.30, clarity: 0.20, vibrance: 0.12),
        make("p43", "航拍与无人机", "城市航拍", .landscapeNatural, ai: true,
             contrast: 1.06, sharpen: 0.30, clarity: 0.19),
        make("p44", "航拍与无人机", "建筑俯瞰", .landscapeNatural, ai: true,
             sharpen: 0.32, clarity: 0.18, lut: 0.28),

        // MARK: 美食摄影
        make("p45", "美食摄影", "美食写真", .commercialNatural, ai: true,
             smooth: 0.42, dodgeBurn: 0.18, clarity: 0.14, vibrance: 0.12),
        make("p46", "美食摄影", "餐厅菜单", .commercialNatural, ai: true,
             smooth: 0.42, sharpen: 0.22, clarity: 0.14, vibrance: 0.10),
        make("p47", "美食摄影", "咖啡甜品", .freshJapanese, ai: true,
             smooth: 0.44, exposure: 0.57, clarity: 0.12, vibrance: 0.10),
        make("p48", "美食摄影", "夜市美食", .nightClear, ai: true,
             exposure: 0.49, shadowLift: 0.24, vibrance: 0.10),

        // MARK: 商品摄影（无人物阶段：磨皮/减淡/眼唇/眼袋为 0，锐化加强）
        make("p49", "商品摄影", "电商白底", .commercialNatural, ai: true,
             sharpen: 0.36, clarity: 0.18, lut: 0.25, vibrance: 0.06),
        make("p50", "商品摄影", "奢侈品质感", .commercialNatural, ai: true,
             contrast: 1.06, sharpen: 0.32, clarity: 0.20, lut: 0.30),
        make("p51", "商品摄影", "商品广告", .commercialNatural, ai: true,
             contrast: 1.04, sharpen: 0.34, clarity: 0.18, lut: 0.34),
        make("p52", "商品摄影", "透明材质", .commercialNatural, ai: true,
             contrast: 1.02, sharpen: 0.34, clarity: 0.16, lut: 0.26),

        // MARK: 建筑与室内（无人物阶段，结构细节优先）
        make("p53", "建筑与室内", "建筑外观", .landscapeNatural, ai: true,
             contrast: 1.06, sharpen: 0.32, clarity: 0.20, lut: 0.28),
        make("p54", "建筑与室内", "室内空间", .landscapeNatural, ai: true,
             shadowLift: 0.16, sharpen: 0.30, clarity: 0.16, lut: 0.30),
        make("p55", "建筑与室内", "酒店民宿", .landscapeNatural, ai: true,
             exposure: 0.55, shadowLift: 0.18, sharpen: 0.30, vibrance: 0.08),
        make("p56", "建筑与室内", "房地产摄影", .landscapeNatural, ai: true,
             exposure: 0.54, sharpen: 0.32, clarity: 0.20),

        // MARK: 汽车与机车
        make("p57", "汽车与机车", "汽车商业", .commercialNatural, ai: true,
             smooth: 0.40, sharpen: 0.30, clarity: 0.18, lut: 0.34),
        make("p58", "汽车与机车", "机车写真", .cinematic, ai: true,
             contrast: 1.08, clarity: 0.16, lut: 0.44),
        make("p59", "汽车与机车", "汽车夜景", .nightClear, ai: true,
             exposure: 0.48, shadowLift: 0.28, clarity: 0.14),
        make("p60", "汽车与机车", "车辆细节", .landscapeNatural, ai: true,
             sharpen: 0.32, clarity: 0.20, lut: 0.28),

        // MARK: 静物与艺术
        make("p61", "静物与艺术", "静物质感", .commercialNatural, ai: true,
             smooth: 0.42, sharpen: 0.30, clarity: 0.18, lut: 0.32),
        make("p62", "静物与艺术", "极简摄影", .landscapeNatural, ai: true,
             contrast: 1.04, sharpen: 0.24, clarity: 0.14, lut: 0.26),
        make("p63", "静物与艺术", "艺术黑白", .cinematic, ai: true,
             contrast: 1.12, lut: 0.40, saturation: 0.0),
        make("p64", "静物与艺术", "复古静物胶片", .cinematic, ai: true,
             contrast: 1.06, lut: 0.52, grain: 0.030),

        // MARK: 演出与活动
        make("p65", "演出与活动", "演唱会", .nightClear, ai: true,
             exposure: 0.50, shadowLift: 0.26, vibrance: 0.10),
        make("p66", "演出与活动", "舞台演出", .nightClear, ai: true,
             exposure: 0.48, shadowLift: 0.28, vibrance: 0.08),
        make("p67", "演出与活动", "会议活动", .commercialNatural, ai: true,
             smooth: 0.44, dodgeBurn: 0.20, sharpen: 0.22, lut: 0.30),
        make("p68", "演出与活动", "节日烟花", .nightClear, ai: true,
             contrast: 1.08, shadowLift: 0.24, vibrance: 0.12),

        // MARK: 水下摄影
        make("p69", "水下摄影", "海底风光", .landscapeNatural, ai: true,
             sharpen: 0.26, clarity: 0.16, lut: 0.34, vibrance: 0.14),
        make("p70", "水下摄影", "水下人像", .commercialNatural, ai: true,
             smooth: 0.44, dodgeBurn: 0.20, clarity: 0.12, lut: 0.36),
        make("p71", "水下摄影", "珊瑚生态", .landscapeNatural, ai: true,
             sharpen: 0.28, clarity: 0.18, vibrance: 0.16),
        make("p72", "水下摄影", "水下运动", .landscapeNatural, ai: true,
             sharpen: 0.30, clarity: 0.16, vibrance: 0.12),

        // MARK: 旅行与日常
        make("p73", "旅行与日常", "旅行大片", .landscapeNatural, ai: true,
             sharpen: 0.28, clarity: 0.18, lut: 0.36, vibrance: 0.12),
        make("p74", "旅行与日常", "生活随拍", .freshJapanese, ai: true,
             exposure: 0.57, shadowLift: 0.18, lut: 0.38),
        make("p75", "旅行与日常", "手机随手拍", .freshJapanese, ai: true,
             exposure: 0.56, shadowLift: 0.20, sharpen: 0.20, lut: 0.36),
        make("p76", "旅行与日常", "社交分享", .freshJapanese, ai: true,
             exposure: 0.58, lut: 0.42, vibrance: 0.10),

        // MARK: 文档与翻拍（无人物阶段，强锐化 + 高对比）
        make("p77", "文档与翻拍", "文档扫描", .commercialNatural, ai: false,
             contrast: 1.10, sharpen: 0.36, clarity: 0.20, lut: 0.25),
        make("p78", "文档与翻拍", "证件翻拍", .commercialNatural, ai: false,
             contrast: 1.08, sharpen: 0.36, clarity: 0.18),
        make("p79", "文档与翻拍", "书籍翻拍", .commercialNatural, ai: false,
             contrast: 1.10, sharpen: 0.34, clarity: 0.18),
        make("p80", "文档与翻拍", "展品记录", .commercialNatural, ai: false,
             contrast: 1.04, sharpen: 0.32, clarity: 0.18),
    ]

    /// 街拍/纪实形态的预设 id：它们和商品图同处一个 category，但交付标准完全不同——
    /// 「像现场」而不是「像产品」。所以门禁按 scene 口径判（纹理 0.60–1.20），
    /// 而不是 product 的 0.60–1.45。
    /// * p27 城市纪实（风景摄影）：街景纪实，路人不按肤色判
    /// * p58 机车写真（汽车与机车）：街头环境里拍车
    /// * p59 汽车夜景（汽车与机车）：夜间街景，暗部压缩本来就掉纹理
    /// 其余汽车类（p57 汽车商业 / p60 车辆细节）仍是 product 口径。
    /// p16 街头穿搭不在此列：人是主体，走肤色（portrait）口径。
    static let sceneModePresetIDs: Set<String> = ["p27", "p58", "p59"]

    static var categories: [String] { Array(Set(all.map(\.category))).sorted() }

    static func find(_ id: String) -> RetouchPreset { all.first { $0.id == id } ?? all[0] }

    static func presets(for category: String) -> [RetouchPreset] {
        all.filter { $0.category == category }
    }

    // MARK: - Construction

    /// Builds one preset: `RetouchParameters.preset(look:category:)` for the tuned
    /// baseline, then the explicit per-preset deltas below.
    ///
    /// Delta → field mapping: `smooth` = smoothAmount · `textureGain` = textureGain ·
    /// `dodgeBurn` = dodgeBurnAmount · `contrast` = contrast ·
    /// `exposure` = exposureTarget · `shadowLift` = shadowLift ·
    /// `sharpen` = sharpenAmount · `clarity` = clarityAmount ·
    /// `lut` = lutStrength · `vibrance` = vibrance ·
    /// `saturation` = saturation · `grain` = grain ·
    /// `blemishStrength` = blemishStrength.
    private static func make(_ id: String, _ category: String, _ name: String,
                             _ look: RetouchLook, ai: Bool,
                             smooth: Double? = nil,
                             textureGain: Double? = nil,
                             dodgeBurn: Double? = nil,
                             contrast: Double? = nil,
                             exposure: Double? = nil,
                             shadowLift: Double? = nil,
                             sharpen: Double? = nil,
                             clarity: Double? = nil,
                             lut: Double? = nil,
                             vibrance: Double? = nil,
                             saturation: Double? = nil,
                             grain: Double? = nil,
                             blemishStrength: Double? = nil) -> RetouchPreset {
        var p = RetouchParameters.preset(look: look, category: category)
        if let value = smooth { p.smoothAmount = value }
        if let value = textureGain { p.textureGain = value }
        if let value = dodgeBurn { p.dodgeBurnAmount = value }
        if let value = contrast { p.contrast = value }
        if let value = exposure { p.exposureTarget = value }
        if let value = shadowLift { p.shadowLift = value }
        if let value = sharpen { p.sharpenAmount = value }
        if let value = clarity { p.clarityAmount = value }
        if let value = lut { p.lutStrength = value }
        if let value = vibrance { p.vibrance = value }
        if let value = saturation { p.saturation = value }
        if let value = grain { p.grain = value }
        if let value = blemishStrength { p.blemishStrength = value }
        return RetouchPreset(id: id, category: category, name: name,
                             look: look, aiAllowed: ai, parameters: p)
    }
}
