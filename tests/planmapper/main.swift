// tests/planmapper/main.swift
//
// Pure-logic harness for `OutdoorPhotoAssistant/Core/Cloud/RetouchPlanMapper.swift`
// (Foundation only, no UIKit, no network, no CIContext).
//
// Build + run on macOS / CI with the stub models (no UIKit needed, this is the
// path that mirrors the other Foundation-only harnesses in this repo):
//
//   mkdir -p build
//   xcrun swiftc -D TEST_STUBS \
//     OutdoorPhotoAssistant/Core/Cloud/RetouchPlanMapper.swift \
//     tests/planmapper/main.swift -o build/planmapper-tests
//   build/planmapper-tests
//
// Cross-check against the real model files (iOS simulator target, because
// RetouchStudioModel.swift imports UIKit):
//
//   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchParameters.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchStudioModel.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/PresetCatalog.swift \
//     OutdoorPhotoAssistant/Core/Cloud/CloudConfiguration.swift \
//     OutdoorPhotoAssistant/Core/Cloud/CloudAPI.swift \
//     OutdoorPhotoAssistant/Core/Cloud/RetouchPlanMapper.swift \
//     tests/planmapper/main.swift -o build/planmapper-real
//   xcrun simctl boot "iPhone 15" || true
//   xcrun simctl bootstatus "iPhone 15" -b
//   xcrun simctl spawn booted build/planmapper-real
//
// The stub block below is compiled ONLY with `-D TEST_STUBS`. It mirrors the
// memberwise initialisers and the handful of members the mapper touches; it is
// not a replacement for the real model files and must never be linked into the
// app target. Nothing in the app target is modified by this file.
//
// Exits 0 when everything passes, 1 on the first failed group of checks.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Stub models (only with -D TEST_STUBS)

#if TEST_STUBS

/// Same field order and defaults as `Core/Cloud/CloudAPI.swift`.
struct PhotoAdvice: Equatable {
    let scene: String
    var understanding: String? = nil
    var editSteps: [String]? = nil
    let strengths: [String]
    let issues: [String]
    let recommendations: [String]
    let editPrompt: String
    let preserve: [String]
}

/// Same cases and `displayName` strings as `Core/CommercialRetouch/RetouchParameters.swift`.
enum RetouchLook: String, CaseIterable, Identifiable {
    case commercialNatural
    case refinedPortrait
    case cinematic
    case freshJapanese
    case landscapeNatural
    case nightClear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commercialNatural: return "商业自然"
        case .refinedPortrait: return "精致写真"
        case .cinematic: return "电影人像"
        case .freshJapanese: return "清新日系"
        case .landscapeNatural: return "自然风光"
        case .nightClear: return "夜景通透"
        }
    }
}

struct ReshapeParameters: Equatable {
    var faceWidth: Double = 0
    var jawline: Double = 0
    var chin: Double = 0
    var eyeSize: Double = 0
    var noseWidth: Double = 0
}

struct BackgroundOptions: Equatable {
    enum Kind: String, Equatable {
        case keep
        case clean
        case solid
        case gradient
    }

    var kind: Kind = .keep
    var cleanupAmount: Double = 0.5

    var isKeep: Bool { kind == .keep }

    static let keep = BackgroundOptions()
    static let white = BackgroundOptions(kind: .solid)
    static let studioBlue = BackgroundOptions(kind: .gradient)
}

enum IDPhotoSpec: String, Equatable {
    case oneInch
    case smallOneInch
    case twoInch
    case smallTwoInch
    case passport
    case visaUS
    case custom
}

struct RetouchAdjustments: Equatable {
    var strength: Double = 1.0
    var presetID: String = "p02"
    var reshape: ReshapeParameters = ReshapeParameters()
    var background: BackgroundOptions = BackgroundOptions.keep
    var idPhoto: IDPhotoSpec? = nil
    var cropToIDPhoto: Bool = false
}

struct RetouchPreset {
    let id: String
    let look: RetouchLook
}

func makePreset(id: String, look: RetouchLook) -> RetouchPreset {
    return RetouchPreset(id: id, look: look)
}

#else

/// Real model files are compiled alongside in this mode; only the factory differs
/// because `RetouchPreset` also needs category/name/aiAllowed/parameters there.
func makePreset(id: String, look: RetouchLook) -> RetouchPreset {
    return RetouchPreset(id: id,
                         category: "人像摄影",
                         name: "测试预设",
                         look: look,
                         aiAllowed: true,
                         parameters: RetouchParameters.preset(look: look, category: "人像摄影"))
}

#endif

// MARK: - Assertions

var checkCount = 0
var failureCount = 0

func pass(_ name: String) {
    checkCount += 1
    print("PASS  " + name)
}

func fail(_ name: String, _ detail: String) {
    checkCount += 1
    failureCount += 1
    print("FAIL  " + name + "  ->  " + detail)
}

func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        pass(name)
    } else {
        fail(name, detail.isEmpty ? "条件不成立" : detail)
    }
}

func checkEqual(_ actual: String, _ expected: String, _ name: String) {
    check(actual == expected, name, "期望 " + expected + "，实际 " + actual)
}

func checkClose(_ actual: Double, _ expected: Double, _ tolerance: Double, _ name: String) {
    let delta = abs(actual - expected)
    if delta <= tolerance {
        pass(name)
    } else {
        fail(name, "期望 " + String(format: "%.4f", expected) + " ± " + String(format: "%.4f", tolerance)
            + "，实际 " + String(format: "%.4f", actual))
    }
}

func section(_ title: String) {
    print("")
    print("-- " + title)
}

// MARK: - Fixtures

/// Mirrors the memberwise initialiser of the real `PhotoAdvice` in both modes.
func advice(scene: String,
            issues: [String] = [],
            steps: [String]? = nil,
            preserve: [String] = [],
            recommendations: [String] = [],
            editPrompt: String = "按本图可见问题做小幅精修。",
            understanding: String? = nil) -> PhotoAdvice {
    return PhotoAdvice(scene: scene,
                       understanding: understanding,
                       editSteps: steps,
                       strengths: [],
                       issues: issues,
                       recommendations: recommendations,
                       editPrompt: editPrompt,
                       preserve: preserve)
}

let portraitPreset = makePreset(id: "p02", look: .refinedPortrait)
let landscapePreset = makePreset(id: "p25", look: .landscapeNatural)

let forbiddenSliderTokens = ["smoothAmount", "blemishStrength", "dodgeBurnAmount", "clarityAmount",
                             "sharpenAmount", "highlightRolloff", "textureGain", "skinProtect",
                             "faceWidth", "jawline", "eyeSize", "backgroundCleanup",
                             "stageAmounts", "Amount", "Gain", "Rolloff", "Strength"]

/// True when the text contains a run of `minimum` or more ASCII letters.
func hasLatinRun(_ text: String, minimum: Int) -> Bool {
    var run = 0
    for scalar in text.unicodeScalars {
        let isLatinLetter = (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
        if isLatinLetter {
            run += 1
            if run >= minimum { return true }
        } else {
            run = 0
        }
    }
    return false
}

func checkInvariants(_ label: String, _ plan: RetouchPlan) {
    let count = plan.reasons.count
    check(count >= 2 && count <= 6, label + "：reasons 数量 2...6", "实际 " + String(count))
    check(plan.confidence >= 0.40 - 1e-9 && plan.confidence <= 0.90 + 1e-9,
          label + "：confidence 落在 0.40...0.90", "实际 " + String(format: "%.2f", plan.confidence))
    check(plan.adjustments.strength >= 0.60 - 1e-9 && plan.adjustments.strength <= 1.15 + 1e-9,
          label + "：strength 落在 0.60...1.15", "实际 " + String(format: "%.2f", plan.adjustments.strength))
    check(plan.adjustments.presetID == plan.presetID, label + "：presetID 与 adjustments 一致",
          plan.presetID + " / " + plan.adjustments.presetID)

    var offending = ""
    for reason in plan.reasons {
        for token in forbiddenSliderTokens where reason.contains(token) {
            offending = token
        }
    }
    check(offending.isEmpty, label + "：reasons 不出现英文滑杆名", offending)
}

// MARK: - 1. scene -> look

section("1. scene -> look（20 条）")

struct LookCase {
    let scene: String
    let issues: [String]
    let expected: RetouchLook
    let note: String
}

let lookCases: [LookCase] = [
    LookCase(scene: "黑白人像", issues: [], expected: .cinematic, note: "黑白"),
    LookCase(scene: "街头纪实", issues: [], expected: .cinematic, note: "纪实"),
    LookCase(scene: "复古胶片", issues: [], expected: .cinematic, note: "胶片"),
    LookCase(scene: "日系清新", issues: [], expected: .freshJapanese, note: "日系"),
    LookCase(scene: "  日 系  清 新 ", issues: [], expected: .freshJapanese, note: "空格容错"),
    LookCase(scene: "POR TRAIT", issues: [], expected: .refinedPortrait, note: "大小写+空格容错"),
    LookCase(scene: "婚纱外景", issues: [], expected: .refinedPortrait, note: "婚纱"),
    LookCase(scene: "夜景", issues: [], expected: .nightClear, note: "夜景"),
    LookCase(scene: "星空银河", issues: [], expected: .nightClear, note: "星空"),
    LookCase(scene: "城市风光", issues: [], expected: .landscapeNatural, note: "风光"),
    LookCase(scene: "无人机航拍", issues: [], expected: .landscapeNatural, note: "航拍"),
    LookCase(scene: "建筑室内", issues: [], expected: .landscapeNatural, note: "建筑"),
    LookCase(scene: "证件照", issues: [], expected: .commercialNatural, note: "证件"),
    LookCase(scene: "电商商品图", issues: [], expected: .commercialNatural, note: "电商"),
    LookCase(scene: "商业广告", issues: [], expected: .commercialNatural, note: "商业"),
    LookCase(scene: "完全看不出类别的描述", issues: [], expected: .commercialNatural, note: "未知场景回退"),
    LookCase(scene: "未知", issues: ["夜景噪点多"], expected: .nightClear, note: "issues 兜底"),
    LookCase(scene: "人像", issues: ["建筑背景杂乱"], expected: .refinedPortrait, note: "scene 优先于 issues"),
    // Ordering consequence of the documented rule table (人像 rule 3 is before 夜景/商业):
    LookCase(scene: "夜景人像", issues: [], expected: .refinedPortrait, note: "规则顺序：人像先于夜景"),
    LookCase(scene: "商业人像", issues: [], expected: .refinedPortrait, note: "规则顺序：人像先于商业")
]

for item in lookCases {
    let actual = RetouchPlanMapper.look(forScene: item.scene, issues: item.issues)
    check(actual == item.expected,
          "scene「" + item.scene + "」(" + item.note + ") -> " + item.expected.rawValue,
          "实际 " + actual.rawValue)
}

// MARK: - 2. amounts: accumulation + cap

section("2. amounts 累加与封顶")

let repeated = RetouchPlanMapper.amounts(fromSteps: ["磨皮", "磨皮"], issues: [])
checkClose(repeated["smoothAmount"] ?? -1.0, 0.20, 1e-9, "两次「磨皮」累加到 0.20")

let spaced = RetouchPlanMapper.amounts(fromSteps: [], issues: ["磨 皮"])
checkClose(spaced["smoothAmount"] ?? -1.0, 0.10, 1e-9, "「磨 皮」按 0.10 命中（空格容错）")

let capped = RetouchPlanMapper.amounts(fromSteps: [], issues: ["瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵"])
checkClose(capped["blemishStrength"] ?? -1.0, 1.0, 1e-9, "十次「瑕疵」封顶 1.0")

let twoWords = RetouchPlanMapper.amounts(fromSteps: ["毛孔", "肤质"], issues: [])
checkClose(twoWords["smoothAmount"] ?? -1.0, 0.16, 1e-9, "「毛孔」+「肤质」累加 0.16")

let shaping = RetouchPlanMapper.amounts(fromSteps: ["光影"], issues: [])
checkClose(shaping["dodgeBurnAmount"] ?? -1.0, 0.10, 1e-9, "「光影」驱动局部明暗 0.10")
checkClose(shaping["contrast"] ?? -1.0, 0.04, 1e-9, "「光影」同时驱动对比 0.04")

let clarity = RetouchPlanMapper.amounts(fromSteps: ["通透"], issues: [])
checkClose(clarity["clarityAmount"] ?? -1.0, 0.12, 1e-9, "「通透」驱动通透 0.12")
checkClose(clarity["sharpenAmount"] ?? -1.0, 0.10, 1e-9, "「通透」同时驱动锐化 0.10")

let cleanup = RetouchPlanMapper.amounts(fromSteps: [], issues: ["背景", "杂物"])
checkClose(cleanup["backgroundCleanup"] ?? -1.0, 0.75, 1e-9, "「背景」+「杂物」累加 0.75")

let empty = RetouchPlanMapper.amounts(fromSteps: [], issues: [])
check(empty.isEmpty, "无关键词时 amounts 为空", "实际 " + String(empty.count) + " 个键")

// MARK: - 3. preserve => gentle profile

section("3. preserve 温和化")

let strongPlan = RetouchPlanMapper.map(advice: advice(scene: "人像",
                                                     issues: ["毛孔明显"],
                                                     steps: ["明显加强磨皮"]),
                                       preset: portraitPreset)
checkClose(strongPlan.adjustments.strength, 1.10, 1e-9, "无 preserve 且要求明显 -> 强度 1.10")
check(strongPlan.stageAmounts["skinProtectDECap"] == nil, "无 preserve 时不给肤色保护上限")

let gentleProfilePlan = RetouchPlanMapper.map(advice: advice(scene: "人像",
                                                           issues: ["毛孔明显"],
                                                           steps: ["明显加强磨皮"],
                                                           preserve: ["保留身份", "保留五官"]),
                                             preset: portraitPreset)
checkClose(gentleProfilePlan.adjustments.strength, 1.00, 1e-9, "preserve 身份 -> 强度上限压到 1.00")
checkClose(gentleProfilePlan.stageAmounts["skinProtectDECap"] ?? -1.0, 2.0, 1e-9, "preserve -> 肤色保护上限 2.00")
checkClose(gentleProfilePlan.stageAmounts["textureGain"] ?? -1.0, 0.15, 1e-9, "preserve -> 纹理保留 +0.15")
check(gentleProfilePlan.reasons.contains { $0.contains("保留") }, "preserve 写进 reasons")

let quietPlan = RetouchPlanMapper.map(advice: advice(scene: "人像", issues: ["毛孔"]),
                                      preset: portraitPreset)
checkClose(quietPlan.adjustments.strength, 1.00, 1e-9, "没有语气词 -> 强度 1.00")

let gentlePlan = RetouchPlanMapper.map(advice: advice(scene: "人像",
                                                     issues: ["暗沉"],
                                                     steps: ["轻微提亮"]),
                                       preset: portraitPreset)
checkClose(gentlePlan.adjustments.strength, 0.90, 1e-9, "轻微 -> 强度 0.90")

let conflictPlan = RetouchPlanMapper.map(advice: advice(scene: "人像",
                                                       issues: ["暗沉"],
                                                       steps: ["明显提亮但又要求轻微"]),
                                         preset: portraitPreset)
checkClose(conflictPlan.adjustments.strength, 1.00, 1e-9, "明显+轻微同时出现 -> 强度保持 1.00")

// MARK: - 4. ID photo + background

section("4. 证件照与背景")

let idWhite = RetouchPlanMapper.map(advice: advice(scene: "证件照", issues: ["白底"]), preset: portraitPreset)
check(idWhite.adjustments.cropToIDPhoto, "证件照 -> cropToIDPhoto")
check(idWhite.adjustments.idPhoto == IDPhotoSpec.oneInch, "证件照默认一寸",
      String(describing: idWhite.adjustments.idPhoto))
check(idWhite.adjustments.background.kind == BackgroundOptions.Kind.solid, "白底 -> 纯色背景",
      idWhite.adjustments.background.kind.rawValue)
check(idWhite.stageAmounts["idPhoto"] == 1.0, "证件照 -> 带 idPhoto 标记")

let idBlue = RetouchPlanMapper.map(advice: advice(scene: "证件照", issues: ["蓝底"]), preset: portraitPreset)
check(idBlue.adjustments.background.kind == BackgroundOptions.Kind.gradient, "蓝底 -> 渐变背景",
      idBlue.adjustments.background.kind.rawValue)

let idPassport = RetouchPlanMapper.map(advice: advice(scene: "护照", issues: []), preset: portraitPreset)
check(idPassport.adjustments.idPhoto == IDPhotoSpec.passport, "护照 -> 护照规格",
      String(describing: idPassport.adjustments.idPhoto))

let idVisa = RetouchPlanMapper.map(advice: advice(scene: "美签", issues: []), preset: portraitPreset)
check(idVisa.adjustments.idPhoto == IDPhotoSpec.visaUS, "美签 -> 美签规格",
      String(describing: idVisa.adjustments.idPhoto))

let idTwoInch = RetouchPlanMapper.map(advice: advice(scene: "二寸照片", issues: []), preset: portraitPreset)
check(idTwoInch.adjustments.idPhoto == IDPhotoSpec.twoInch, "二寸 -> 二寸规格",
      String(describing: idTwoInch.adjustments.idPhoto))

let cleanOnly = RetouchPlanMapper.map(advice: advice(scene: "风光", issues: ["背景杂乱"]), preset: landscapePreset)
check(!cleanOnly.adjustments.cropToIDPhoto, "只提背景杂物 -> 不裁证件照")
check(cleanOnly.adjustments.background.kind == BackgroundOptions.Kind.clean, "只提背景杂物 -> 只清理背景",
      cleanOnly.adjustments.background.kind.rawValue)
check(cleanOnly.adjustments.background.cleanupAmount > 0.0, "背景清理强度 > 0",
      String(format: "%.2f", cleanOnly.adjustments.background.cleanupAmount))

let untouchedBackground = RetouchPlanMapper.map(advice: advice(scene: "风光", issues: ["天空过曝"]),
                                               preset: landscapePreset)
check(untouchedBackground.adjustments.background.isKeep, "没提背景 -> 保留原背景")
check(untouchedBackground.stageAmounts["backgroundCleanup"] == nil, "没提背景 -> 不产生背景清理权重")

let idBeatsCleanup = RetouchPlanMapper.map(advice: advice(scene: "证件照", issues: ["背景杂乱"]),
                                          preset: portraitPreset)
check(idBeatsCleanup.adjustments.cropToIDPhoto, "证件照优先于背景清理")
check(idBeatsCleanup.stageAmounts["backgroundCleanup"] == nil, "证件照换底后不再叠加背景清理权重")

// MARK: - 5. reshape

section("5. 液化")

let reshapePlan = RetouchPlanMapper.map(advice: advice(scene: "人像",
                                                      issues: ["脸型偏圆"],
                                                      steps: ["瘦脸", "下颌收紧"]),
                                       preset: portraitPreset)
check(reshapePlan.adjustments.reshape.faceWidth > 0.0, "瘦脸/脸型 -> faceWidth > 0",
      String(format: "%.2f", reshapePlan.adjustments.reshape.faceWidth))
check(reshapePlan.adjustments.reshape.jawline > 0.0, "下颌 -> jawline > 0",
      String(format: "%.2f", reshapePlan.adjustments.reshape.jawline))
checkClose(reshapePlan.adjustments.reshape.eyeSize, 0.0, 1e-9, "没提大眼 -> eyeSize 保持 0")
check(reshapePlan.reasons.contains { $0.contains("液化") }, "液化写进 reasons")

let eyePlan = RetouchPlanMapper.map(advice: advice(scene: "人像", steps: ["大眼"]), preset: portraitPreset)
check(eyePlan.adjustments.reshape.eyeSize > 0.0, "大眼 -> eyeSize > 0",
      String(format: "%.2f", eyePlan.adjustments.reshape.eyeSize))
checkClose(eyePlan.adjustments.reshape.faceWidth, 0.0, 1e-9, "只提大眼 -> faceWidth 保持 0")

let noReshapePlan = RetouchPlanMapper.map(advice: advice(scene: "风光", issues: ["暗沉"]), preset: landscapePreset)
checkClose(noReshapePlan.adjustments.reshape.faceWidth, 0.0, 1e-9, "没提脸型 -> faceWidth = 0")
checkClose(noReshapePlan.adjustments.reshape.jawline, 0.0, 1e-9, "没提下颌 -> jawline = 0")
checkClose(noReshapePlan.adjustments.reshape.eyeSize, 0.0, 1e-9, "没提大眼 -> eyeSize = 0")

// MARK: - 6. determinism

section("6. 确定性")

let determinismAdvice = advice(scene: "夜景人像",
                               issues: ["油光重", "毛孔明显", "背景杂物"],
                               steps: ["分区提亮", "轻微磨皮"],
                               preserve: ["保留痣"],
                               recommendations: ["主方案：收紧高光"],
                               editPrompt: "分区提亮面部，收回油光，保留皮肤纹理。")
let determinismPlanA = RetouchPlanMapper.map(advice: determinismAdvice, preset: portraitPreset)
let determinismPlanB = RetouchPlanMapper.map(advice: determinismAdvice, preset: portraitPreset)
check(determinismPlanA == determinismPlanB, "同一份 advice 两次 map 结果完全相同")
check(determinismPlanA.reasons == determinismPlanB.reasons, "reasons 顺序完全一致")
check(RetouchPlanMapper.amounts(fromSteps: ["磨皮", "通透"], issues: ["背景"])
        == RetouchPlanMapper.amounts(fromSteps: ["磨皮", "通透"], issues: ["背景"]),
      "amounts 两次调用完全相同")
check(RetouchPlanMapper.summary(determinismPlanA) == RetouchPlanMapper.summary(determinismPlanB),
      "summary 两次调用完全相同")

// MARK: - 7. confidence + reasons bounds

section("7. confidence 与 reasons 边界")

let barePlan = RetouchPlanMapper.map(advice: advice(scene: "未知", editPrompt: "保持原片"),
                                    preset: portraitPreset)
checkClose(barePlan.confidence, 0.40, 1e-9, "没有命中也没有步骤 -> 置信 0.40")
check(barePlan.needsManualReview, "置信 < 0.55 -> 需人工复核")
check(barePlan.reasons.count == 2, "只有场景一条时会补齐到 2 条", "实际 " + String(barePlan.reasons.count))

let richAdvice = advice(scene: "人像",
                        issues: ["毛孔明显", "油光重", "高光溢出", "痘印", "画面发灰"],
                        steps: ["分区提亮", "通透处理", "分区磨皮并保留纹理，直到缩小看有层次、放大看仍有毛孔"],
                        recommendations: ["主方案：先压高光再提中间调"],
                        preserve: ["保留皮肤纹理"],
                        editPrompt: "分区提亮面部与衣领，收回额头鼻尖油光，降低整体灰雾，保留毛孔与发丝。")
let richPlan = RetouchPlanMapper.map(advice: richAdvice, preset: portraitPreset)
check(richPlan.confidence >= 0.55, "信息量足够时置信 >= 0.55", String(format: "%.2f", richPlan.confidence))
check(richPlan.confidence <= 0.90, "置信不超过 0.90", String(format: "%.2f", richPlan.confidence))
check(!richPlan.needsManualReview, "没有发丝类不确定项 -> 不需要人工复核")

let hairAdvice = advice(scene: "人像",
                        issues: ["碎发很多", "毛孔明显", "油光", "高光", "痘印"],
                        steps: ["分区提亮通透", "磨皮"],
                        recommendations: ["主方案：清理边缘碎发"],
                        editPrompt: "清理边缘碎发并在发丝外沿保留干净过渡。")
let hairPlan = RetouchPlanMapper.map(advice: hairAdvice, preset: portraitPreset)
check(hairPlan.needsManualReview, "提到碎发 -> 需人工复核（即使置信不低）")
check(hairPlan.reasons.contains { $0.contains("人工复核") }, "碎发写进 reasons 并说明人工复核")
check(hairPlan.stageAmounts.keys.allSatisfy { $0 != "hair" && $0 != "hairEdge" },
      "碎发不产生任何参数键")

let inventory: [(String, PhotoAdvice)] = [
    ("裸建议", advice(scene: "未知", editPrompt: "保持原片")),
    ("人像常规", advice(scene: "人像", issues: ["毛孔明显"], steps: ["轻微磨皮"])),
    ("夜景强风格", advice(scene: "夜景", issues: ["噪点", "暗部死黑"], steps: ["明显提亮暗部"],
                            recommendations: ["主方案：保留夜空色相"])),
    ("证件照", advice(scene: "证件照", issues: ["白底", "痘印"], steps: ["祛痘印"])),
    ("风光", advice(scene: "城市风光", issues: ["画面发灰", "细节偏软"], steps: ["通透处理"])),
    ("婚纱", advice(scene: "婚纱外景", issues: ["肤色不均"], steps: ["磨皮", "提亮"],
                     preserve: ["保留五官", "保留雀斑"])),
    ("碎石级文本", advice(scene: "人像", issues: ["瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵瑕疵"],
                            steps: ["大眼", "瘦脸", "下颌收紧", "背景换底"])),
    ("全英文场景", advice(scene: "portrait night street", issues: ["oil shine", "smoothen skin"],
                            steps: ["lift midtones"]))
]

for item in inventory {
    let plan = RetouchPlanMapper.map(advice: item.1, preset: portraitPreset)
    checkInvariants(item.0, plan)
}

// Chinese-scene advices must not echo Latin runs except the two-letter "AI" tag.
var latinReasonOffender = ""
for item in inventory where item.0 != "全英文场景" {
    let plan = RetouchPlanMapper.map(advice: item.1, preset: portraitPreset)
    for reason in plan.reasons where hasLatinRun(reason, minimum: 3) {
        latinReasonOffender = reason
    }
}
check(latinReasonOffender.isEmpty, "中文场景的 reasons 没有连续 3 个以上英文字母", latinReasonOffender)

// Unknown scene keeps the operator's preset look.
let unknownScenePlan = RetouchPlanMapper.map(advice: advice(scene: "", editPrompt: "保持原片"),
                                            preset: landscapePreset)
check(unknownScenePlan.look == .landscapeNatural, "场景识别不出来时沿用传入预设的 look",
      unknownScenePlan.look.rawValue)

// MARK: - 8. summary

section("8. summary 文案")

let summary = RetouchPlanMapper.summary(richPlan)
let summaryLines = summary.split(separator: "\n", omittingEmptySubsequences: false)
check(summary.contains("方案："), "summary 带「方案：」开头")
check(summary.contains("强度"), "summary 带强度")
check(summary.contains("置信"), "summary 带置信")
check(summary.contains(richPlan.look.displayName), "summary 带中文 look 名称")
check(summaryLines.count == richPlan.reasons.count + 1,
      "summary 行数 = 1 + reasons 数量",
      "实际 " + String(summaryLines.count))
check(summary.contains("1. "), "summary 给 reasons 编号")

let reviewSummary = RetouchPlanMapper.summary(hairPlan)
check(reviewSummary.contains("需人工复核"), "需要人工复核时 summary 有标记")

// MARK: - Summary

print("")
let passed = checkCount - failureCount
print("== 结果：" + String(passed) + "/" + String(checkCount) + " 项通过，失败 " + String(failureCount) + " 项 ==")
if failureCount == 0 {
    print("== 全部通过 ==")
}
exit(failureCount == 0 ? 0 : 1)
