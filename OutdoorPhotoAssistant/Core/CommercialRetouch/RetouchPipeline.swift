import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Result of one commercial retouch pass.
struct RetouchOutcome {
    var image: UIImage
    var report: RetouchQualityReport
    var spotsFound: Int
    var spotsRemaining: Int
    var look: RetouchLook
    var exposureEV: Double
    /// The mode is decided from both the selected category and what this image
    /// actually contains (face / screenshot). AI advice must use the same fact.
    var shootingMode: AIEditSubjectMode
}

/// Legacy assessment shape kept for older call sites.
struct RetouchAssessment {
    let acceptable: Bool
    let notes: [String]
}

/// On-device commercial retouch pipeline (V16).
///
/// Stage order mirrors `tools/retouch_lab/pipeline.py`, which is the reference
/// implementation the parameters and QC thresholds were validated against:
/// analyse -> detect blemishes -> heal -> frequency separation -> dodge & burn
/// -> eyes / under-eye / teeth / lips -> tone -> 3D LUT grade -> finishing ->
/// QC gate (automatic repair loop).
final class RetouchPipeline {
    private let context: CIContext
    private let analyzer = RetouchAnalyzer()
    private let engine: RetouchEngine
    private let gate = RetouchQualityGate()
    private lazy var reshapeEngine = RetouchReshapeEngine(context: context)
    private lazy var backgroundEngine = RetouchBackgroundEngine(context: context)

    init() {
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        context = ctx
        engine = RetouchEngine(context: ctx)
    }

    // MARK: - Preset suggestion

    func suggestPreset(image: UIImage) async -> (RetouchPreset, String) {
        let fallback = RetouchPresetCatalog.find("p25")
        guard let cg = image.cgImage else { return (fallback, "无法识别，采用自然风光预设") }
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: cg,
                                      orientation: CGImagePropertyOrientation(rawValue: UInt32(RetouchSpecialist.exifOrientation(image.imageOrientation))) ?? .up)
                .perform([request])
            let labels = (request.results ?? []).filter { $0.confidence >= 0.20 }
            let all = labels.map { $0.identifier.lowercased() }.joined(separator: " ")
            let target = Self.sceneTarget(from: all)
            let preset = RetouchPresetCatalog.all.first { $0.name == target } ?? fallback
            return (preset, labels.first.map { "Vision 初步识别：\($0.identifier)（置信度 \(Int($0.confidence * 100))%），建议人工确认预设" }
                    ?? "未找到可靠分类，建议人工确认预设")
        } catch {
            return (fallback, "场景识别失败，采用自然风光预设")
        }
    }

    /// 20 类场景路由：Vision 标签 → 预设名。顺序敏感，先命中先赢（越具体的场景越靠前），
    /// 这样「人 + 婚纱」不会落到人像、「宠物 + 草地」不会落到风光。
    private static let sceneRules: [(keywords: [String], target: String)] = [
        (["wedding", "bride", "groom", "bouquet"], "浪漫婚纱"),
        (["newborn", "infant", "baby"], "新生儿柔光"),
        (["child", "kid", "toddler", "children"], "儿童抓拍"),
        (["family"], "家庭合影"),
        (["cat", "dog", "pet", "kitten", "puppy", "rabbit", "hamster"], "宠物写真"),
        (["wildlife", "bird", "elephant", "lion", "tiger", "deer"], "野生动物"),
        (["fashion", "runway", "couture", "model"], "时尚大片"),
        (["concert", "stage", "performance", "band", "dj"], "演唱会"),
        (["sport", "running", "bicycle", "soccer", "basketball", "swim"], "高速抓拍"),
        (["food", "dish", "cuisine", "dessert", "coffee", "cake"], "美食写真"),
        (["car", "vehicle", "motorcycle", "automobile", "truck"], "汽车商业"),
        (["building", "architecture", "skyscraper", "interior", "room"], "建筑外观"),
        (["product", "still life", "bottle", "watch", "jewelry"], "静物质感"),
        (["flower", "plant", "leaf", "garden", "blossom"], "花卉微距"),
        (["insect", "butterfly", "bug", "macro"], "昆虫微距"),
        (["star", "night sky", "milky", "aurora", "astronomy", "galaxy"], "银河星空"),
        (["aerial", "drone", "bird's eye", "top down"], "自然航拍"),
        (["underwater", "coral", "diving", "aquarium"], "海底风光"),
        (["document", "text", "receipt", "book", "paper", "screenshot"], "文档扫描"),
        (["portrait", "person", "face", "selfie", "people"], "商业自然"),
        (["travel", "vacation", "tourist"], "旅行大片"),
        (["city", "skyline", "urban", "downtown", "street"], "城市纪实"),
        (["landscape", "mountain", "sky", "beach", "forest", "sunset", "lake", "cloud"], "自然风光"),
    ]

    /// Deterministic label → preset routing; unknown labels fall back to 自然风光.
    static func sceneTarget(from labels: String) -> String {
        for rule in sceneRules where rule.keywords.contains(where: { labels.contains($0) }) {
            return rule.target
        }
        return "自然风光"
    }

    // MARK: - Processing

    func process(_ image: UIImage, preset: RetouchPreset, strength: Double = 1.0) throws -> RetouchOutcome {
        guard let raw = image.cgImage else { throw RetouchFailure.invalidImage }
        let input = CIImage(cgImage: raw).oriented(forExifOrientation: RetouchSpecialist.exifOrientation(image.imageOrientation))
        let extent = input.extent
        guard extent.width > 8, extent.height > 8 else { throw RetouchFailure.invalidImage }
        guard let plan = LocalRetouchPreflight.inspect(width: Int(extent.width), height: Int(extent.height)) else {
            throw RetouchFailure.invalidImage
        }

        var parameters = preset.parameters.scaled(longEdge: max(extent.width, extent.height))
        parameters = Self.applying(strength: strength, to: parameters)

        // 截图/界面图识别：同一张图只在调色之前测一次（550 长边代理，<15 ms）。
        // 截图必须走 document 口径并且不套风格 Look —— 实测套了调色 SSIM 会从 0.999 掉到 0.914，
        // 直接撞破 document 的 0.92 下限；清晰度也要关掉，UI 文字与边框加锐化只会被放大成白边。
        let screenshot = ScreenshotDetector.inspect(input, context: context)
        let treatAsScreenshot = screenshot.isScreenshot
        if treatAsScreenshot {
            parameters.applyLook = false
            parameters.clarityAmount = 0
            parameters.sharpenAmount = min(parameters.sharpenAmount, 0.12)
        }

        let geometry = analyzer.detectFace(in: input, context: context)
        var analysis: SkinAnalysis?
        if let geometry, let result = analyzer.analyze(image: input, geometry: geometry, context: context) {
            analysis = result
        }
        // 品类口径：文档/翻拍最严，商品/建筑/汽车允许加锐化，人像才判肤色。
        // 人脸是否检出只在「其它类别」时才影响口径（人像 vs 风景）；且必须在 analysis 之后算。
        // 截图优先级最高（见 shootingMode 内部），会直接压过 category。
        let mode = Self.shootingMode(for: preset.category, presetID: preset.id,
                                     hasFace: analysis != nil,
                                     isScreenshot: treatAsScreenshot)

        // 轮数下限 3：预设里的 maxPasses 默认是 2，重试点太容易用完就交出不合格图。
        // 这里只在 process 内部抬高下限，不动 RetouchParameters 的默认值（别处还靠它）。
        let passLimit = max(3, parameters.maxPasses)
        var passes = 0
        var best: (image: CIImage, report: RetouchQualityReport, spots: Int, remaining: Int, ev: Double) = (input, .failure, 0, 0, 0)
        repeat {
            passes += 1
            let rendered = renderPass(input: input, analysis: analysis, parameters: parameters,
                                      preset: preset, mode: mode)
            let report = evaluate(input: input, candidate: rendered.image, analysis: analysis,
                                  spotsBefore: rendered.spots, remaining: rendered.remaining, ev: rendered.ev,
                                  mode: mode)
            best = (rendered.image, report, rendered.spots, rendered.remaining, rendered.ev)
            if report.passed || passes >= passLimit { break }
            // 自动修复：门禁报哪一项就退让哪一项。过去只有纹理/裁切/接缝三条分支，
            // 肤色 ΔE 和肤色明度偏移全部掉进最后的 else 直接 break，所以肤色永远修不动。
            if (report.metrics["texture_retention"] ?? 1.0) < 0.50 {
                // 纹理被磨没了：减磨皮、加回纹理权重
                parameters.smoothAmount *= 0.72
                parameters.textureGain = min(1.0, parameters.textureGain + 0.06)
            } else if (report.metrics["clipping_skin"] ?? 0) > 0.002 || (report.metrics["clipping_full"] ?? 0) > 0.0100 {
                // 高光/死黑裁切：先退 Lightroom 阶段的局部对比（clarity/texture/dehaze 是主要来源），
                // 再压低曝光目标、让高光滚降更早介入。
                parameters.lightroomAmount = max(0.0, parameters.lightroomAmount - 0.25)
                parameters.exposureTarget = max(0.35, parameters.exposureTarget - 0.02)
                parameters.highlightRolloff = max(0.72, parameters.highlightRolloff - 0.03)
            } else if (report.metrics["skin_tone_de"] ?? 0) > 3.0 {
                // 肤色 ΔE00 超限：调色链三条同时退让（肤色量 / LUT / 饱和+鲜艳）
                parameters.skinToneAmount = max(0.08, parameters.skinToneAmount * 0.6)
                parameters.lutStrength = max(0.10, parameters.lutStrength * 0.7)
                parameters.saturation = 1.0 + (parameters.saturation - 1.0) * 0.6
                parameters.vibrance *= 0.7
            } else if (report.metrics["skin_pixel_de_p95_info"] ?? 0) > 6.0 {
                // 局部色偏：中位数达标但皮肤区 P95 超限，说明偏色集中在某几块区域。
                // 这里不是继续猜参数去修那块区域，而是把整条调色链再按一档，让后面的
                // 局部拉回（RetouchCompliance.pullSkinToneLocally）在更小的偏差上收敛。
                parameters.skinToneAmount *= 0.8
                parameters.lutStrength *= 0.85
                parameters.lightroomAmount = max(0.0, parameters.lightroomAmount - 0.1)
            } else if (report.metrics["skin_luma_shift"] ?? 0) > 18.0 {
                // 肤色明度被拉太亮/太暗：再退一次肤色量，曝光目标向 0.5 收敛一半
                parameters.skinToneAmount *= 0.7
                parameters.exposureTarget = (parameters.exposureTarget + 0.5) / 2.0
            } else if abs((report.metrics["seam_ratio"] ?? 1.0) - 1.0) > 0.30 {
                // 蒙版接缝：减弱加深减淡与磨皮，让边界梯度回落到 1.00 附近
                parameters.dodgeBurnAmount *= 0.7
                parameters.smoothAmount *= 0.85
            } else if (report.metrics["ssim"] ?? 1.0) < 0.85 {
                // 结构相似度掉太多：整体改动幅度收一档，Lightroom 阶段也跟着退
                parameters.dodgeBurnAmount *= 0.7
                parameters.clarityAmount *= 0.7
                parameters.lightroomAmount = max(0.0, parameters.lightroomAmount - 0.2)
            } else {
                break
            }
        } while true

        // 兜底合规 pass：重试到上限还在门禁外，就在交付图这一层把指标拉回阈值内。
        // 顺序：先肩/趾压缩去裁切，再按 Lab 中位数把肤色拉回（只在皮肤遮罩内生效）。
        let compliant = RetouchCompliance.enforce(candidate: best.image, original: input,
                                                  analysis: analysis, context: context,
                                                  exposureEV: best.ev)
        var report = evaluate(input: input, candidate: compliant, analysis: analysis,
                              spotsBefore: best.spots, remaining: best.remaining, ev: best.ev,
                              mode: mode)

        let tileEdge = plan.tier == .standard ? 2048 : 1024
        guard let base = LocalTiledRenderer.render(compliant, extent: extent, context: context,
                                                   tileEdge: tileEdge) else {
            throw RetouchFailure.processingFailed
        }
        var outputCG = base
        // 8 位兜底：CIColorKernel 的采样值落在上下文的工作色彩空间里，如果这个工作空间不是
        // sRGB gamma，kernel 里的分段压缩就不是按交付像素算的。门禁量裁切看的就是 8 位 sRGB
        // 的 luma，所以这里再按交付像素做一次 256 项 LUT，两次里取裁切更少的那一版。
        if RetouchCompliance.needsClippingRepair(report), let repairedCG = RetouchCompliance.shoulderToeBytes(base) {
            let repairedImage = CIImage(cgImage: repairedCG)
            let repairedReport = evaluate(input: input, candidate: repairedImage, analysis: analysis,
                                          spotsBefore: best.spots, remaining: best.remaining, ev: best.ev,
                                          mode: mode)
            if RetouchCompliance.clippingScore(repairedReport) < RetouchCompliance.clippingScore(report) {
                outputCG = repairedCG
                report = repairedReport
            }
        }
        let output = UIImage(cgImage: outputCG, scale: 1, orientation: .up)
        // 仍然不过也不抛错：照常交付图像，只把 notes 换成唯一可执行动作。
        var finalReport = RetouchCompliance.actionable(report)
        // 截图判定结果必须出现在质检报告里：否则用户只会看到「这张图没套风格、口径也变了」却不知原因。
        if treatAsScreenshot {
            finalReport.notes.insert(Self.screenshotNote(screenshot), at: 0)
        }
        return RetouchOutcome(image: output, report: finalReport, spotsFound: best.spots,
                              spotsRemaining: best.remaining, look: preset.look, exposureEV: best.ev,
                              shootingMode: Self.adviceMode(for: mode))
    }

    /// 把截图判定拼成一条人话，带置信度与三条特征的实测数字（阈值也在里面，现场好核对）。
    static func screenshotNote(_ verdict: ScreenshotDetector.Verdict) -> String {
        let confidence = String(format: "%.2f", verdict.confidence)
        let evidence = verdict.reasons.joined(separator: "；")
        return "提示：检测为截图/界面图（置信度 " + confidence + "），已切文档口径并跳过风格调色。依据：" + evidence
    }

    /// 只负责出图与数瑕疵。质检拆到 `evaluate`，这样重试循环和兜底合规 pass 打分口径一致。
    /// Lightroom 核心阶段总开关：设置里关掉就完全不下发这一阶段（用户可对比开关前后差异）。
    /// 没设置过时默认开启——这是本次升级的主特性，默认就该有。
    /// 由预设类别 + 是否检出人脸决定门禁口径。
    /// 注意这里按 category 判定优先于「有没有脸」：商品图里偶尔也有人脸，
    /// 但它的交付标准是产品细节，不是肤色。
    /// `isScreenshot` 优先级最高：截图/界面图直接走文档口径，压过 category 与有没有脸。
    static func shootingMode(for category: String,
                             presetID: String = "",
                             hasFace: Bool,
                             isScreenshot: Bool = false) -> RetouchQualityGate.ShootingMode {
        // 截图没有「肤色」可言，结构也不允许被改（UI 边缘、文字），只能按 document 判：
        // 纹理 0.60–1.50、SSIM ≥0.92、不判肤色。
        if isScreenshot { return .document }
        if category == "文档与翻拍" { return .document }
        // 街头纪实类预设按 scene 口径判，不分类别、也不看有没有脸：
        // 商品/汽车类里混着棚拍图（product 口径 0.60–1.45）和街头纪实（scene 口径 0.60–1.20）；
        // 城市纪实里偶然出现的路人也不该按肤色判。必须放在 category 判断之前，否则
        // 不在下面四个类别里的预设（如 p27 城市纪实）永远命中不了白名单。
        if RetouchPresetCatalog.sceneModePresetIDs.contains(presetID) { return .scene }
        switch category {
        case "商品摄影", "建筑与室内", "汽车与机车", "静物与艺术":
            return .product
        default:
            return hasFace ? .portrait : .scene
        }
    }

    private static func adviceMode(for mode: RetouchQualityGate.ShootingMode) -> AIEditSubjectMode {
        switch mode {
        case .portrait: return .portrait
        case .scene: return .scene
        case .product: return .product
        case .document: return .document
        }
    }

    private static var lightroomCoreEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "lightroomCore") != nil else { return true }
        return defaults.bool(forKey: "lightroomCore")
    }

    /// 解析当前该用哪套 Look：
    /// * 用户在精修页选了导入的 .xmp 预设 → 用预设里的参数（和 LR 里看到的完全一致）；
    /// * 否则用内置 6 个风格表（`LightroomLookCatalog`）。
    /// 导入预设要读磁盘，所以带一层按 id 的小缓存 + 锁（批处理会并发进来）。
    private static let importedLookLock = NSLock()
    private static var importedLookCache: (id: String, look: LightroomLook)?

    static func resolvedLightroomLook(for style: RetouchLook) -> LightroomLook {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: "lightroomImportedPresetID"),
              !idString.isEmpty, let id = UUID(uuidString: idString) else {
            return LightroomLookCatalog.look(for: style)
        }
        importedLookLock.lock()
        if let cached = importedLookCache, cached.id == idString {
            importedLookLock.unlock()
            return cached.look
        }
        importedLookLock.unlock()
        guard let preset = LightroomPresetStore.shared.preset(id: id) else {
            return LightroomLookCatalog.look(for: style)
        }
        importedLookLock.lock()
        importedLookCache = (idString, preset.look)
        importedLookLock.unlock()
        return preset.look
    }

    /// 导入/删除预设后清掉缓存，避免同名覆盖后还拿着旧参数渲染。
    static func clearLightroomLookCache() {
        importedLookLock.lock()
        importedLookCache = nil
        importedLookLock.unlock()
    }

    private func renderPass(input: CIImage, analysis: SkinAnalysis?, parameters: RetouchParameters,
                            preset: RetouchPreset,
                            mode: RetouchQualityGate.ShootingMode) -> (image: CIImage, spots: Int, remaining: Int, ev: Double) {
        var work = input
        var spots: [BlemishSpot] = []
        if let analysis {
            let detection = engine.detectSpots(in: input, analysis: analysis, parameters: parameters)
            spots = detection.spots
            if !spots.isEmpty {
                work = engine.heal(work, spots: spots, proxy: detection.proxy, parameters: parameters)
            }
            work = engine.smoothSkin(work, analysis: analysis, parameters: parameters)
            work = engine.dodgeAndBurn(work, analysis: analysis, parameters: parameters)
            work = engine.eyes(work, analysis: analysis, parameters: parameters)
            work = engine.underEye(work, analysis: analysis, parameters: parameters)
            work = engine.teeth(work, analysis: analysis, parameters: parameters)
            work = engine.lips(work, analysis: analysis, parameters: parameters)
        }
        let (toned, ev) = engine.tone(work, analysis: analysis, parameters: parameters)
        work = toned
        // Lightroom 核心阶段：ACR 的顺序是“基础色调 → 曲线/HSL/Look → 局部对比”，
        // 所以它插在 tone 之后、grade(LUT Look) 之前。皮肤遮罩传进去，清晰度/纹理/锐化
        // 都会避开皮肤（这是商业精修和随手调色的分界线）。
        if parameters.applyLook, Self.lightroomCoreEnabled, parameters.lightroomAmount > 0.001 {
            let look = Self.resolvedLightroomLook(for: preset.look)
                .scaled(by: parameters.lightroomAmount)
            // 走全链路入口：Develop（ACR 14 段）→ 镜头校正 → 几何 → 修补。
            // 后三段参数默认全关（lens/geometry/repair 都是 no-op），所以出图和纯 Develop 一致；
            // 但要开镜头校正/污点修复时，这里就是挂载点（也保证引擎不会被链接器裁掉）。
            work = look.applyFull(to: work, skinMask: analysis?.skinMask, context: context)
        }
        if parameters.applyLook {
            work = engine.grade(work, look: preset.look, parameters: parameters)
        }
        work = engine.finish(work, analysis: analysis, parameters: parameters)
        work = work.cropped(to: input.extent)

        let remaining: Int
        if let analysis {
            remaining = engine.detectSpots(in: work, analysis: analysis, parameters: parameters).spots.count
        } else {
            remaining = 0
        }
        return (work, spots.count, remaining, ev)
    }

    /// 用同一套门禁重新打分（原来渲染与打分揉在 renderPass 里，兜底 pass 没法复用）。
    private func evaluate(input: CIImage, candidate: CIImage, analysis: SkinAnalysis?,
                          spotsBefore: Int, remaining: Int, ev: Double,
                          mode: RetouchQualityGate.ShootingMode) -> RetouchQualityReport {
        let clearance: Double
        if spotsBefore <= 0 {
            clearance = 1.0
        } else {
            clearance = max(0.0, min(1.0, 1.0 - Double(remaining) / Double(spotsBefore)))
        }
        if let analysis {
            return gate.review(RetouchQualityGate.Input(original: input,
                                                        candidate: candidate,
                                                        skinMask: analysis.skinMask,
                                                        blemishClearance: clearance,
                                                        spotsBefore: spotsBefore,
                                                        exposureEV: ev,
                                                        whiteBalance: analysis.whiteBalance,
                                                        context: context,
                                                        mode: mode))
        }
        // 没检出人脸 → 风景口径（纹理 0.60–1.20，肤色项只作参考信息）。
        return gate.review(RetouchQualityGate.Input(original: input,
                                                    candidate: candidate,
                                                    skinMask: nil,
                                                    blemishClearance: 1.0,
                                                    spotsBefore: 0,
                                                    exposureEV: ev,
                                                    whiteBalance: SIMD3(1, 1, 1),
                                                    context: context,
                                                    mode: mode))
    }

    static func applying(strength: Double, to parameters: RetouchParameters) -> RetouchParameters {
        let s = min(max(strength, 0.4), 1.3)
        var p = parameters
        p.smoothAmount *= s
        p.dodgeBurnAmount *= s
        p.blemishStrength = min(1.0, p.blemishStrength * s)
        p.eyeAmount *= s
        p.underEyeAmount *= s
        p.teethAmount *= s
        p.lipAmount *= s
        p.clarityAmount *= s
        p.sharpenAmount *= s
        p.lutStrength *= min(s, 1.15)
        p.vibrance *= s
        return p
    }

    // MARK: - Batch / studio API

    /// Analysis only (used once per frame to build the shoot anchor).
    func analysis(for image: UIImage) -> SkinAnalysis? {
        guard let raw = image.cgImage else { return nil }
        let input = CIImage(cgImage: raw)
            .oriented(forExifOrientation: RetouchSpecialist.exifOrientation(image.imageOrientation))
        guard let geometry = analyzer.detectFace(in: input, context: context) else { return nil }
        return analyzer.analyze(image: input, geometry: geometry, context: context)
    }

    /// Full studio pass: retouch -> tone -> grade -> liquify -> background ->
    /// finishing -> optional ID-photo crop, all against the shoot anchor so a
    /// delivered set stays colour-consistent.
    func process(_ image: UIImage, preset: RetouchPreset,
                 adjustments: RetouchAdjustments, anchor: ShootAnchor?) throws -> RetouchOutcome {
        guard let raw = image.cgImage else { throw RetouchFailure.invalidImage }
        let input = CIImage(cgImage: raw)
            .oriented(forExifOrientation: RetouchSpecialist.exifOrientation(image.imageOrientation))
        let extent = input.extent
        guard extent.width > 8, extent.height > 8,
              let plan = LocalRetouchPreflight.inspect(width: Int(extent.width), height: Int(extent.height)) else {
            throw RetouchFailure.invalidImage
        }
        var parameters = preset.parameters.scaled(longEdge: max(extent.width, extent.height))
        parameters = Self.applying(strength: adjustments.strength, to: parameters)

        var geometry: FaceGeometry?
        var analysis: SkinAnalysis?
        if let detected = analyzer.detectFace(in: input, context: context) {
            geometry = detected
            analysis = analyzer.analyze(image: input, geometry: detected, context: context)
        }
        let mode = Self.shootingMode(for: preset.category, presetID: preset.id,
                                     hasFace: analysis != nil)

        var work = input
        var appliedEV = 0.0
        if let anchor, let analysis {
            let fix = anchor.correction(for: analysis)
            work = engine.applyCorrection(work, gains: fix.gains, ev: fix.ev)
            appliedEV += fix.ev
        }

        var spots: [BlemishSpot] = []
        if let analysis {
            let detection = engine.detectSpots(in: work, analysis: analysis, parameters: parameters)
            spots = detection.spots
            if !spots.isEmpty {
                work = engine.heal(work, spots: spots, proxy: detection.proxy, parameters: parameters)
            }
            work = engine.smoothSkin(work, analysis: analysis, parameters: parameters)
            work = engine.dodgeAndBurn(work, analysis: analysis, parameters: parameters)
            work = engine.eyes(work, analysis: analysis, parameters: parameters)
            work = engine.underEye(work, analysis: analysis, parameters: parameters)
            work = engine.teeth(work, analysis: analysis, parameters: parameters)
            work = engine.lips(work, analysis: analysis, parameters: parameters)
        }
        // anchored runs must not re-normalise: the anchor already set WB/exposure
        let (toned, toneEV) = engine.tone(work, analysis: analysis, parameters: parameters,
                                          applyWhiteBalance: anchor == nil,
                                          skipExposure: anchor != nil)
        work = toned
        appliedEV += toneEV
        work = engine.grade(work, look: preset.look, parameters: parameters)
        work = engine.finish(work, analysis: analysis, parameters: parameters)
        work = work.cropped(to: extent)

        // QC runs on the retouch itself, before liquify / background work:
        // those two are parameter edits the operator reviews by eye, and a cutout
        // would otherwise fail the structural metrics by design.
        var report = RetouchQualityReport(
            passed: false, metrics: [:],
            notes: ["未检测到可用人脸：已执行全图色调与风格精修，肤质质检跳过，请人工复核成片"])
        if let analysis {
            let remaining = engine.detectSpots(in: work, analysis: analysis, parameters: parameters).spots.count
            let clearance = spots.isEmpty ? 1.0 : max(0.0, min(1.0, 1.0 - Double(remaining) / Double(spots.count)))
            report = gate.review(RetouchQualityGate.Input(original: input, candidate: work,
                                                          skinMask: analysis.skinMask,
                                                          blemishClearance: clearance,
                                                          spotsBefore: spots.count,
                                                          exposureEV: appliedEV,
                                                          whiteBalance: analysis.whiteBalance,
                                                          context: context,
                                                          mode: mode))
        }

        let portraitPreset = ["人像摄影", "婚纱与情侣", "家庭与儿童", "时尚与穿搭"].contains(preset.category)
        if portraitPreset && !adjustments.reshape.isNeutral {
            work = reshapeEngine.apply(work, geometry: geometry, parameters: adjustments.reshape)
            applyStudioNote(&report, "已液化：需目视复核脸型与背景边缘")
        }
        if !adjustments.background.isKeep {
            let mask = backgroundEngine.subjectMask(for: work, geometry: geometry, context: context)
            work = backgroundEngine.apply(work, subjectMask: mask, options: adjustments.background)
            applyStudioNote(&report, "已换底/清理背景：需目视复核发丝边缘")
        }
        if adjustments.cropToIDPhoto, let spec = adjustments.idPhoto {
            if let cropped = backgroundEngine.idPhoto(work, geometry: geometry, spec: spec,
                                                      background: adjustments.background, dpi: 300) {
                work = cropped
                applyStudioNote(&report, "已按证件照规格裁切（\(spec.displayName)）")
            }
        }

        let outputExtent = work.extent
        guard let cg = LocalTiledRenderer.render(work, extent: outputExtent, context: context,
                                                 tileEdge: plan.tier == .standard ? 2048 : 1024) else {
            throw RetouchFailure.processingFailed
        }
        let output = UIImage(cgImage: cg, scale: 1, orientation: .up)
        return RetouchOutcome(image: output, report: report, spotsFound: spots.count,
                              spotsRemaining: 0, look: preset.look, exposureEV: appliedEV,
                              shootingMode: Self.adviceMode(for: mode))
    }

    private func applyStudioNote(_ report: inout RetouchQualityReport, _ note: String) {
        if !report.notes.contains(note) { report.notes.append(note) }
    }

    // MARK: - Manual repair

    /// User-driven spot repair on the current version. The point is normalised in
    /// displayed image space; the engine picks a clean source patch automatically.
    func healSpot(_ image: UIImage, at point: CGPoint) throws -> UIImage {
        guard let cg = image.cgImage, (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw RetouchFailure.invalidImage
        }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        guard let geometry = analyzer.detectFace(in: input, context: context),
              let analysis = analyzer.analyze(image: input, geometry: geometry, context: context) else {
            throw RetouchFailure.processingFailed
        }
        var parameters = RetouchParameters().scaled(longEdge: max(extent.width, extent.height))
        parameters.blemishSensitivity = 1.0
        let detection = engine.detectSpots(in: input, analysis: analysis, parameters: parameters)
        // the UI passes a top-left normalised point; spots use the same convention
        let manual = BlemishSpot(center: CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1)),
                                 radius: max(0.004, min(0.02, 6.0 / max(extent.width, extent.height))),
                                 score: 1.0, kind: "manual")
        let healed = engine.heal(input, spots: [manual] + detection.spots, proxy: detection.proxy, parameters: parameters)
        guard let rendered = LocalTiledRenderer.render(healed, extent: extent, context: context, tileEdge: 2048) else {
            throw RetouchFailure.processingFailed
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    // MARK: - Legacy assessment

    func assess(original: UIImage, result: UIImage) -> RetouchAssessment {
        guard let source = original.cgImage, let output = result.cgImage else {
            return RetouchAssessment(acceptable: false, notes: ["无法读取图像像素，拒绝自动验收"])
        }
        let normalized = CIImage(cgImage: source)
            .oriented(forExifOrientation: RetouchSpecialist.exifOrientation(original.imageOrientation))
        let report = gate.review(RetouchQualityGate.Input(original: normalized,
                                                          candidate: CIImage(cgImage: output),
                                                          skinMask: nil,
                                                          blemishClearance: 1.0,
                                                          spotsBefore: 0,
                                                          exposureEV: 0,
                                                          whiteBalance: SIMD3(1, 1, 1),
                                                          context: context))
        return RetouchAssessment(acceptable: report.passed, notes: report.notes)
    }
}

enum RetouchFailure: LocalizedError {
    case invalidImage, processingFailed, invalidExport
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "图片无法解码"
        case .processingFailed: return "本地图像处理失败"
        case .invalidExport: return "JPEG 导出验证失败"
        }
    }
}

/// Versioned files in Application Support. Original bytes are copied and never overwritten.
final class RetouchVersionStore {
    private let fm = FileManager.default
    private var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CommercialRetouch", isDirectory: true)
    }

    func newJob(originalData: Data, captureDate: Date? = nil) throws -> UUID {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let originalURL = folder.appendingPathComponent("original.bin")
        try originalData.write(to: originalURL, options: .atomic)
        if let captureDate {
            try? fm.setAttributes([.creationDate: captureDate,
                                   .modificationDate: captureDate],
                                  ofItemAtPath: originalURL.path)
        }
        return id
    }

    func versions(job: UUID) -> [URL] {
        let folder = root.appendingPathComponent(job.uuidString, isDirectory: true)
        return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { ["local", "seedream", "fusion"].contains($0.lastPathComponent.components(separatedBy: "-").first ?? "")
                && $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func originalBytes(job: UUID) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(job.uuidString, isDirectory: true)
            .appendingPathComponent("original.bin"))
    }

    func verifyOriginal(job: UUID, expected: Data) -> Bool {
        (try? originalBytes(job: job)) == expected
    }

    func saveJPEG(_ image: UIImage, job: UUID, label: String) throws -> URL {
        guard ["local", "seedream", "fusion"].contains(label) else { throw RetouchFailure.invalidExport }
        let folder = root.appendingPathComponent(job.uuidString, isDirectory: true)
        let temporary = folder.appendingPathComponent("\(label)-\(UUID().uuidString).tmp")
        guard let cg = image.cgImage else { throw RetouchFailure.invalidExport }
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let normalized = CIContext().createCGImage(CIImage(cgImage: cg),
                                                   from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
                                                   format: .RGBA8, colorSpace: rgb) ?? cg
        guard let destinationRef = CGImageDestinationCreateWithURL(temporary as CFURL,
                                                                   UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RetouchFailure.invalidExport
        }
        let capture = captureTimeMetadata(job: job)
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95,
                                           kCGImagePropertyOrientation: 1]
        properties[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifDateTimeOriginal: capture.exifText,
            kCGImagePropertyExifDateTimeDigitized: capture.exifText
        ] as NSDictionary
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFDateTime: capture.exifText
        ] as NSDictionary
        CGImageDestinationAddImage(destinationRef, normalized, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef),
              let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceCreateImageAtIndex(check, 0, nil) != nil else { throw RetouchFailure.invalidExport }
        // Every run creates a new revision; never replace a previous successful version.
        let revision = folder.appendingPathComponent("\(label)-\(UUID().uuidString).jpg")
        try fm.moveItem(at: temporary, to: revision)
        // Share sheets and file-based importers do not all inspect EXIF. Keep the
        // filesystem date aligned with the original capture date as a second,
        // lossless signal. Only time fields are copied; GPS/device metadata is not.
        try? fm.setAttributes([.creationDate: capture.date,
                               .modificationDate: capture.date],
                              ofItemAtPath: revision.path)
        let report = CommercialQualityGate().verifyJPEG(revision, expectedWidth: cg.width, expectedHeight: cg.height)
        if report.decision == .rejected {
            try? fm.removeItem(at: revision)
            throw RetouchFailure.invalidExport
        }
        try RetouchRecovery().record(job: job, url: revision, kind: label, needsHumanReview: label != "local")
        return revision
    }

    /// Reads only the original capture time. AI upload copies deliberately strip
    /// metadata, so the timestamp must come from the locally retained original.
    /// GPS, camera serial number and every unrelated EXIF field stay excluded.
    private func captureTimeMetadata(job: UUID) -> (exifText: String, date: Date) {
        let originalURL = root.appendingPathComponent(job.uuidString, isDirectory: true)
            .appendingPathComponent("original.bin")
        let data = try? Data(contentsOf: originalURL)
        let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        let properties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)

        let fallback = ((try? originalURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate)
            ?? Date()
        if let text, let parsed = Self.parseExifDate(text) {
            return (text, parsed)
        }
        return (Self.formatExifDate(fallback), fallback)
    }

    private static func parseExifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func formatExifDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 兜底合规 pass（只在本文件内使用）

/// 重试循环跑满后仍在门禁外的兜底 pass，只做两件事：
/// 1) 肤色拉回：按皮肤区 Lab 中位数偏差给一条通道增益，把 ΔE00 拉回 2.0 以内；
/// 2) 按需肩/趾压缩：把 >252 与 <3 的裁切从交付像素里去掉（`clipping_full` / `clipping_skin`）。
///
/// 为什么不在重试循环里做：循环退让的是预设参数，退到下限仍然可能超限（客户截图就是这种），
/// 所以需要一个「按最终像素反算」的闭环，而不是继续猜参数。
private enum RetouchCompliance {

    /// 与门禁同一个代理尺度（1100）。只有尺度一样，量到的 ΔE00 才和门禁报告里那个数是同一个数。
    static let proxyLongEdge: CGFloat = 1100

    static let clippingFullMax: Double = 0.0100
    static let clippingSkinMax: Double = 0.002
    static let skinToneHardMax: Double = 3.0
    static let skinToneTargetDE: Float = 2.0

    /// 局部拉回用的是 550 长边代理，不是 1100。
    /// 局部拉回只关心「哪一块偏色」，位置精度 550 已经足够；上 1100 就是白烧一倍 CPU
    /// （逐像素 ΔE00 是这条链上最贵的一步，开销与像素数线性相关）。
    static let localProxyLongEdge: CGFloat = 550
    /// 局部拉回自己的收敛目标：p95 ≤ 4.0 就停。
    /// 门禁线是 6.0，这里留 2.0 余量——550 代理与 1100 门禁代理之间有重采样差异，
    /// 贴着 6.0 收敛会在门禁那边因为几十个像素的误差翻车。
    static let localP95TargetDE: Double = 4.0
    /// 权重平滑的上下沿：ΔE ≤ 3.0 认为「肉眼可接受」完全不动，ΔE ≥ 8.0 认为「明显偏色」全量拉。
    /// 中间用 smoothstep 过渡，避免在 3~8 之间切出一条硬边。
    private static let localWeightLow: Double = 3.0
    private static let localWeightHigh: Double = 8.0
    /// 局部拉回的硬上限轮数：2 轮。不再往上加——增益有 0.85 阻尼，第 3 轮只会在
    /// 已经收敛的区域来回抖，而每多一轮就是一次全代理重算。
    private static let localMaxIterations = 2
    /// 皮肤像素下限：550 代理上 500 个像素（约 0.2% 画面）。比这还少，中位数就是噪声，
    /// 拉回只会把噪声放大，直接原样返回。
    private static let localMinSkinPixels = 500
    /// 参与「局部中位数」的像素下限：权重 > 0.5 的像素太少时，中位数不可信。
    private static let localMinWeightedPixels = 16
    /// 代理短边下限：太小的图（< 64 px）没有局部可言，交给全局那级就够了。
    private static let localMinProxyEdge: CGFloat = 64

    // MARK: - 肩/趾压缩曲线

    /// 分段线性压缩（sRGB gamma 域，对 R/G/B 各自做，alpha 保持）：
    /// * `x <= 0.08` → `0.014 + 0.066*(x/0.08)`：0 抬到 0.014（3.57/255→4），斜率 0.825；
    /// * `0.08..0.92` → `0.080 + 0.838*((x-0.08)/0.84)`：斜率 0.9976，中间调几乎不动；
    /// * `x >= 0.92` → `0.918 + 0.064*((x-0.92)/0.08)`：1.0 压到 0.982（250.4/255→250），斜率 0.8。
    /// 端点保证：任何通道都落在 0.014...0.982，而 rec.709 luma 是通道的凸组合，
    /// 所以 luma*255 一定落在 (3.57, 250.4)，既不会 <3 也不会 >252。
    static func shoulderToe(_ x: Float) -> Float {
        let v = x.isFinite ? min(max(x, 0.0), 1.0) : 0.0
        let kneeLow: Float = 0.08
        let kneeHigh: Float = 0.92
        let floorValue: Float = 0.014
        let midStart: Float = 0.080
        let midEnd: Float = 0.918
        let ceilingValue: Float = 0.982
        if v <= kneeLow {
            return floorValue + (midStart - floorValue) * (v / kneeLow)
        }
        if v >= kneeHigh {
            return midEnd + (ceilingValue - midEnd) * ((v - kneeHigh) / (1.0 - kneeHigh))
        }
        return midStart + (midEnd - midStart) * ((v - kneeLow) / (kneeHigh - kneeLow))
    }

    /// 同一曲线的 Core Image 版本：一次全图，`step` 逐通道选段，输出再夹一次端点。
    private static let shoulderToeKernel = CIColorKernel(source: """
        kernel vec4 shoulderToe(__sample s) {
            vec3 v = clamp(s.rgb, 0.0, 1.0);
            vec3 lo = vec3(0.014) + vec3(0.066) * (v / 0.08);
            vec3 mid = vec3(0.080) + vec3(0.838) * ((v - 0.08) / 0.84);
            vec3 hi = vec3(0.918) + vec3(0.064) * ((v - 0.92) / 0.08);
            vec3 outColor = mix(mix(lo, mid, step(vec3(0.08), v)), hi, step(vec3(0.92), v));
            return vec4(clamp(outColor, 0.014, 0.982), s.a);
        }
        """)

    // MARK: - 入口

    /// 兜底合规：有皮肤遮罩时先把肤色拉回，最后按需做肩/趾压缩。
    /// 顺序不能反：压缩放在最后，才能保证交付像素的端点不被前面的通道增益顶过 252 或压到 3 以下。
    /// 压缩是「按需」的：先在代理上量一遍，已经合规就一个像素都不动（避免无故抬黑压白牵连 SSIM）。
    /// `analysis == nil` 时只做裁切压缩。
    ///
    /// 肤色拉回是两级：
    /// * 第一级 `pullSkinTone`：全局中位数拉回，修「整张脸整体偏色」；
    /// * 第二级 `pullSkinToneLocally`：局部拉回，修「中位数达标但某块区域偏色」。
    /// 第二级只在 550 代理上量到的逐像素 ΔE P95 > 4.0 才跑——没局部色偏就一个像素都不动。
    static func enforce(candidate: CIImage, original: CIImage, analysis: SkinAnalysis?,
                        context: CIContext, exposureEV: Double = 0) -> CIImage {
        var work = candidate
        if let analysis {
            work = pullSkinTone(candidate: candidate, original: original, analysis: analysis,
                                exposureEV: exposureEV, context: context)
            // 轻量评估拿 p95：550 代理自己算一遍就够，绝不在这里调用完整 gate.review
            // （那会在 1100 代理上把纹理/SSIM/接缝全部重算一次，贵一个数量级）。
            let localP95 = skinPixelDEP95(candidate: work, original: original, analysis: analysis,
                                          exposureEV: exposureEV, context: context)
            if localP95 > localP95TargetDE {
                work = pullSkinToneLocally(candidate: work, original: original, analysis: analysis,
                                           exposureEV: exposureEV, context: context, p95: localP95)
            }
        }
        guard needsShoulderToe(work, analysis: analysis, context: context) else {
            return work.cropped(to: candidate.extent)
        }
        return shoulderToeImage(work).cropped(to: candidate.extent)
    }

    /// 是否需要肩/趾压缩：在 1100 代理上按门禁同一条 8 位规则（luma*255 < 3 或 > 252）量一遍。
    /// 阈值取门禁上限的 0.8，留 20% 余量给「代理换算是最近邻/重采样」这类小误差。
    /// 已经有合规的图完全跳过：抬黑 0→4/255 对大面死黑的画面会压低 SSIM，能不动就别动。
    static func needsShoulderToe(_ image: CIImage, analysis: SkinAnalysis?, context: CIContext) -> Bool {
        guard let proxy = PixelKit.renderRGBA8(image, maxEdge: proxyLongEdge, context: context) else { return true }
        let width = proxy.width
        let height = proxy.height
        guard width > 0, height > 0, proxy.bytes.count >= width * height * 4 else { return true }
        var skinPlane: FloatPlane?
        if let analysis,
           let maskRGBA = PixelKit.renderRGBA8(analysis.skinMask, width: width, height: height,
                                               context: context) {
            let plane = PixelKit.luma(maskRGBA)
            if plane.values.count >= width * height { skinPlane = plane }
        }
        let total = width * height
        var hits = 0
        var skinHits = 0
        var skinTotal = 0
        var i = 0
        while i < total {
            let offset = i * 4
            let luma = PixelKit.luma(r: Float(proxy.bytes[offset]) / 255.0,
                                     g: Float(proxy.bytes[offset + 1]) / 255.0,
                                     b: Float(proxy.bytes[offset + 2]) / 255.0) * 255.0
            let clipped = luma < 3.0 || luma > 252.0
            if clipped { hits += 1 }
            if let plane = skinPlane, plane.values[i] > 0.5 {
                skinTotal += 1
                if clipped { skinHits += 1 }
            }
            i += 1
        }
        let fullFraction = Double(hits) / Double(total)
        // 与门禁一致：皮肤区没有像素时，clipping_skin 退回全图比例。
        let skinFraction = skinTotal > 0 ? Double(skinHits) / Double(skinTotal) : fullFraction
        return fullFraction > clippingFullMax * 0.8 || skinFraction > clippingSkinMax * 0.8
    }

    /// 全图肩/趾压缩（CIColorKernel）。kernel 不可用时原样返回，由 8 位兜底接手。
    static func shoulderToeImage(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return image }
        guard let kernel = shoulderToeKernel,
              let output = kernel.apply(extent: extent, arguments: [image]) else { return image }
        return output.cropped(to: extent)
    }

    // MARK: - 肤色拉回

    /// 以 1100 代理为基准量皮肤区 Lab 中位数，与「白平衡+曝光对齐后的原图」比 ΔE00；
    /// 超过 2.0 就按 Lab→sRGB 反解出的通道增益拉一次，最多 2 次（每次重新测量，阻尼 0.85）。
    static func pullSkinTone(candidate: CIImage, original: CIImage, analysis: SkinAnalysis,
                             exposureEV: Double, context: CIContext) -> CIImage {
        let extent = candidate.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 16, extent.height > 16 else { return candidate }
        guard let reference = PixelKit.renderRGBA8(original, maxEdge: proxyLongEdge, context: context) else {
            return candidate
        }
        let width = reference.width
        let height = reference.height
        guard width > 16, height > 16,
              let maskRGBA = PixelKit.renderRGBA8(analysis.skinMask, width: width, height: height,
                                                  context: context) else { return candidate }
        // 皮肤遮罩按门禁的取法：先渲染到代理尺寸，再取 luma（灰度图 luma == R 通道）。
        let maskPlane = PixelKit.luma(maskRGBA)
        var skin = FloatPlane(width: width, height: height, value: 0)
        var skinCount = 0
        let total = min(width * height, maskPlane.values.count)
        var index = 0
        while index < total {
            if maskPlane.values[index] > 0.6 {
                skin.values[index] = 1.0
                skinCount += 1
            }
            index += 1
        }
        // 门禁本身要求 ≥100 个皮肤像素才判肤色；更少就当作无脸，不做拉回。
        guard skinCount >= 100 else { return candidate }

        let alignedOriginal = toneAligned(reference, whiteBalance: analysis.whiteBalance,
                                         exposureEV: exposureEV)
        let referenceLab = PixelKit.lab(alignedOriginal)
        let targetMedian = SIMD3<Float>(PixelKit.median(referenceLab.l, mask: skin),
                                        PixelKit.median(referenceLab.a, mask: skin),
                                        PixelKit.median(referenceLab.b, mask: skin))
        guard targetMedian.x.isFinite else { return candidate }

        var current = candidate
        var iteration = 0
        while iteration < 2 {
            iteration += 1
            // 用未压缩的图像测量：肩/趾压缩在中间调上是恒等映射（斜率 0.9976，ΔL≤0.12），
            // 而且压缩是按需执行的，所以这里量原值，两种情况下都成立。
            guard let rendered = PixelKit.renderRGBA8(current, width: width, height: height,
                                                      context: context) else { break }
            let currentLab = PixelKit.lab(rendered)
            let median = SIMD3<Float>(PixelKit.median(currentLab.l, mask: skin),
                                      PixelKit.median(currentLab.a, mask: skin),
                                      PixelKit.median(currentLab.b, mask: skin))
            let measured = PixelKit.deltaE2000(targetMedian, median)
            guard measured.isFinite, measured > skinToneTargetDE else { break }
            let gains = channelGains(target: targetMedian, current: median)
            current = applyChannelGains(gains, to: current, mask: analysis.skinMask, extent: extent)
        }
        return current
    }

    /// Lab 中位数偏差 → sRGB 三通道增益。
    /// 用 `labToRGB` 把两边中位数各自反解回 RGB 再取比值，L 的偏差自然落到三个通道的共模上，
    /// a（红绿）与 b（黄蓝）的偏差落到 R/G/B 的差模上，不用手工拆 Lab 轴。
    /// 阻尼 0.85 防过冲；第二次迭代重新测量后再收一次。
    static func channelGains(target: SIMD3<Float>, current: SIMD3<Float>) -> SIMD3<Float> {
        let targetRGB = PixelKit.labToRGB(target)
        let currentRGB = PixelKit.labToRGB(current)
        let damping: Float = 0.85
        return SIMD3<Float>(clampedGain(targetRGB.x, currentRGB.x, damping),
                            clampedGain(targetRGB.y, currentRGB.y, damping),
                            clampedGain(targetRGB.z, currentRGB.z, damping))
    }

    private static func clampedGain(_ target: Float, _ current: Float, _ damping: Float) -> Float {
        guard target.isFinite, current.isFinite else { return 1.0 }
        let denominator = max(current, 0.02)
        let raw = min(max(target / denominator, 0.70), 1.45)
        return 1.0 + (raw - 1.0) * damping
    }

    /// 增益只作用在皮肤遮罩内：整图乘增益，再用羽化后的遮罩按亮度混回去。
    /// 只乘不换色，所以遮罩边界处的梯度比（seam_ratio）不会被推高。
    static func applyChannelGains(_ gains: SIMD3<Float>, to image: CIImage, mask: CIImage,
                                  extent: CGRect) -> CIImage {
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return image }
        guard gains.x.isFinite, gains.y.isFinite, gains.z.isFinite else { return image }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: CGFloat(gains.x), y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: CGFloat(gains.y), z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(gains.z), w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let graded = matrix.outputImage else { return image }
        let feathered = PixelKit.scaledMask(0.95, of: mask, extent: extent)
        return PixelKit.blend(graded.cropped(to: extent), over: image, mask: feathered).cropped(to: extent)
    }

    // MARK: - 局部肤色拉回

    /// 一轮局部测量的中间结果（550 代理尺度）。
    /// `referenceLab` 是「白平衡+曝光对齐后的原图」，`candidateLab` 是待检候选；
    /// `deltaE` 只在 `skinHard > 0.5` 的像素上写过值，其余位置保持 0。
    private struct LocalDeltaESample {
        var width: Int
        var height: Int
        var referenceLab: (l: FloatPlane, a: FloatPlane, b: FloatPlane)
        var candidateLab: (l: FloatPlane, a: FloatPlane, b: FloatPlane)
        var deltaE: FloatPlane
        var skinSoft: FloatPlane
        var skinHard: FloatPlane
        var skinCount: Int
    }

    /// 在 550 代理上渲染候选与原图（原图按白平衡+曝光对齐），逐皮肤像素算 ΔE00。
    /// 任何一步拿不到可用数据就返回 nil——上层按「没有局部色偏」处理，绝不抛错。
    private static func localDeltaESample(candidate: CIImage, original: CIImage, analysis: SkinAnalysis,
                                          exposureEV: Double, context: CIContext) -> LocalDeltaESample? {
        guard let reference = PixelKit.renderRGBA8(original, maxEdge: localProxyLongEdge,
                                                   context: context) else { return nil }
        let width = reference.width
        let height = reference.height
        let total = width * height
        guard width > 1, height > 1, total > 0,
              reference.bytes.count >= total * 4 else { return nil }
        // 皮肤遮罩渲染到同一尺寸：门禁与全局拉回都是这个取法，软边数值才可比。
        guard let maskRGBA = PixelKit.renderRGBA8(analysis.skinMask, width: width, height: height,
                                                  context: context) else { return nil }
        guard let candidateProxy = PixelKit.renderRGBA8(candidate, width: width, height: height,
                                                        context: context) else { return nil }
        guard candidateProxy.bytes.count >= total * 4 else { return nil }

        let skinSoft = PixelKit.luma(maskRGBA)
        guard skinSoft.values.count >= total else { return nil }
        var skinHard = FloatPlane(width: width, height: height, value: 0)
        var skinCount = 0
        var index = 0
        while index < total {
            if skinSoft.values[index] > 0.6 {
                skinHard.values[index] = 1.0
                skinCount += 1
            }
            index += 1
        }
        guard skinCount >= localMinSkinPixels else { return nil }

        let alignedOriginal = toneAligned(reference, whiteBalance: analysis.whiteBalance,
                                         exposureEV: exposureEV)
        let referenceLab = PixelKit.lab(alignedOriginal)
        let candidateLab = PixelKit.lab(candidateProxy)
        guard referenceLab.l.values.count >= total, referenceLab.a.values.count >= total,
              referenceLab.b.values.count >= total, candidateLab.l.values.count >= total,
              candidateLab.a.values.count >= total, candidateLab.b.values.count >= total else { return nil }

        var deltaE = FloatPlane(width: width, height: height, value: 0)
        index = 0
        while index < total {
            if skinHard.values[index] > 0.5 {
                let referencePixel = SIMD3<Float>(referenceLab.l.values[index],
                                                  referenceLab.a.values[index],
                                                  referenceLab.b.values[index])
                let candidatePixel = SIMD3<Float>(candidateLab.l.values[index],
                                                  candidateLab.a.values[index],
                                                  candidateLab.b.values[index])
                deltaE.values[index] = PixelKit.deltaE2000(referencePixel, candidatePixel)
            }
            index += 1
        }
        return LocalDeltaESample(width: width, height: height,
                                  referenceLab: referenceLab, candidateLab: candidateLab,
                                  deltaE: deltaE, skinSoft: skinSoft, skinHard: skinHard,
                                  skinCount: skinCount)
    }

    /// 一次轻量评估：550 代理上皮肤区逐像素 ΔE00 的 95 分位。
    /// 只给 `enforce` 判断「要不要跑第二级」用，不替代完整门禁（门禁在 1100 代理上算全套指标）。
    /// 拿不到可用数据时返回 0（= 没有证据表明有局部色偏，不动图）。
    static func skinPixelDEP95(candidate: CIImage, original: CIImage, analysis: SkinAnalysis,
                               exposureEV: Double, context: CIContext) -> Double {
        guard let sample = localDeltaESample(candidate: candidate, original: original,
                                             analysis: analysis, exposureEV: exposureEV,
                                             context: context) else { return 0.0 }
        let value = Double(PixelKit.percentile(sample.deltaE, mask: sample.skinHard, 95))
        return value.isFinite ? value : 0.0
    }

    /// 局部肤色拉回：按 ΔE00 分布加权，只把「明显偏色」的那几块区域往原图拉。
    ///
    /// 权重公式：`weight = smoothstep(3.0, 8.0, ΔE) * skinSoft`
    /// * `smoothstep(lo, hi, x) = t*t*(3-2t)`，`t = clamp((x-lo)/(hi-lo), 0, 1)`；
    /// * 乘上皮肤遮罩的软边值（不是 0/1 二值），边界处权重自然衰减，不会在脸的轮廓上切出硬边。
    ///
    /// 增益来源：取「权重 > 0.5」的像素集合，在同一个集合上分别求候选与原图的 Lab 中位数，
    /// 交给和全局一级完全相同的 `channelGains(target:current:)`（阻尼 0.85、增益夹 0.70...1.45）。
    /// 两边用同一像素集合是关键：目标与现状必须描述同一批像素，否则增益算出来是错的。
    ///
    /// 作用域：权重平面 → `maskImage(from:targetSize:)` 铺到全分辨率 →
    /// `gaussian` 羽化（半径 `max(2, extent.width / 220)`）→ `applyChannelGains` 只乘局部。
    ///
    /// 迭代：最多 2 轮，每轮重新渲染代理重算 p95，`p95 ≤ 4.0` 立刻停。
    static func pullSkinToneLocally(candidate: CIImage, original: CIImage, analysis: SkinAnalysis,
                                    exposureEV: Double, context: CIContext, p95: Double) -> CIImage {
        let extent = candidate.extent
        // 早退 1：extent 不可用或太小（< 64 px），局部没有意义。
        guard !extent.isInfinite, !extent.isNull,
              extent.width >= localMinProxyEdge, extent.height >= localMinProxyEdge else { return candidate }
        // 早退 2：没有局部色偏证据（p95 ≤ 4.0）就一个像素都不动。
        guard p95.isFinite, p95 > localP95TargetDE else { return candidate }

        // 羽化半径随画面走：长边越大，局部块也越大，固定 2 px 在全分辨率上根本糊不开。
        let featherRadius = max(2.0, Double(extent.width) / 220.0)
        var work = candidate
        // 只交付「确实让 p95 变小」的那一版：肤色增益是整块乘法，
        // 某些分布（比如高光/背景里大量极端色）上会连带把 p95 推高，
        // 所以每轮都要重新量，变好才接受，变差就回滚。
        var bestWork = candidate
        var bestP95 = p95
        var iteration = 0
        while iteration < localMaxIterations {
            iteration += 1
            guard let sample = localDeltaESample(candidate: work, original: original,
                                                 analysis: analysis, exposureEV: exposureEV,
                                                 context: context) else { break }
            let measuredP95 = Double(PixelKit.percentile(sample.deltaE, mask: sample.skinHard, 95))
            guard measuredP95.isFinite, measuredP95 > localP95TargetDE else { break }

            var weight = FloatPlane(width: sample.width, height: sample.height, value: 0)
            var selected = FloatPlane(width: sample.width, height: sample.height, value: 0)
            var selectedCount = 0
            let pixelCount = sample.width * sample.height
            var index = 0
            while index < pixelCount {
                if sample.skinHard.values[index] > 0.5 {
                    let de = Double(sample.deltaE.values[index])
                    var t = (de - localWeightLow) / (localWeightHigh - localWeightLow)
                    t = t.isFinite ? min(max(t, 0.0), 1.0) : 0.0
                    let smooth = t * t * (3.0 - 2.0 * t)
                    var soft = Double(sample.skinSoft.values[index])
                    soft = soft.isFinite ? min(max(soft, 0.0), 1.0) : 0.0
                    let combined = Float(smooth * soft)
                    weight.values[index] = combined
                    if combined > 0.5 {
                        selected.values[index] = 1.0
                        selectedCount += 1
                    }
                }
                index += 1
            }
            // 早退 3：权重够的像素太少，中位数不可信，这一轮不做。
            guard selectedCount >= localMinWeightedPixels else { break }

            let targetMedian = SIMD3<Float>(PixelKit.median(sample.referenceLab.l, mask: selected),
                                            PixelKit.median(sample.referenceLab.a, mask: selected),
                                            PixelKit.median(sample.referenceLab.b, mask: selected))
            let currentMedian = SIMD3<Float>(PixelKit.median(sample.candidateLab.l, mask: selected),
                                             PixelKit.median(sample.candidateLab.a, mask: selected),
                                             PixelKit.median(sample.candidateLab.b, mask: selected))
            guard targetMedian.x.isFinite, currentMedian.x.isFinite else { break }

            let gains = channelGains(target: targetMedian, current: currentMedian)
            guard gains.x.isFinite, gains.y.isFinite, gains.z.isFinite else { break }

            let weightMask = PixelKit.maskImage(from: weight, targetSize: extent.size)
            // maskImage 铺出来的是 origin = (0, 0) 的图；候选图的 extent 可能有非零 origin
            // （EXIF 旋转后常见），这里平移过去，后面 `applyChannelGains` 里的
            // `cropped(to: extent)` 才不会裁到空区域。
            let localizedMask = weightMask.transformed(by: CGAffineTransform(translationX: extent.minX,
                                                                            y: extent.minY))
            let feathered = PixelKit.gaussian(localizedMask, radius: featherRadius)
            let proposed = applyChannelGains(gains, to: work, mask: feathered, extent: extent)
            // 量一遍新候选：只有 p95 真的下降才采纳，否则保留上一版并停止。
            guard let verify = localDeltaESample(candidate: proposed, original: original,
                                                 analysis: analysis, exposureEV: exposureEV,
                                                 context: context) else { break }
            let verifiedP95 = Double(PixelKit.percentile(verify.deltaE, mask: verify.skinHard, 95))
            guard verifiedP95.isFinite, verifiedP95 < measuredP95, verifiedP95 < bestP95 else { break }
            work = proposed
            bestWork = proposed
            bestP95 = verifiedP95
        }
        return bestWork
    }

    // MARK: - 参考图对齐

    /// 与 `RetouchQualityGate` 的 `toneAligned` 同一条公式：逐通道白平衡增益 × 曝光，再夹到 0...1。
    /// 不对齐的话，一次刻意的曝光/白平衡修正会被当成肤色错误算进 ΔE00。
    static func toneAligned(_ image: RGBAImage, whiteBalance: SIMD3<Double>,
                            exposureEV: Double) -> RGBAImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, image.bytes.count >= width * height * 4 else { return image }
        let gainR = Float(min(max(whiteBalance.x.isFinite ? whiteBalance.x : 1.0, 0.0), 4.0))
        let gainG = Float(min(max(whiteBalance.y.isFinite ? whiteBalance.y : 1.0, 0.0), 4.0))
        let gainB = Float(min(max(whiteBalance.z.isFinite ? whiteBalance.z : 1.0, 0.0), 4.0))
        let ev = min(max(exposureEV.isFinite ? exposureEV : 0.0, -8.0), 8.0)
        let exposure = Float(exp2(ev))
        var aligned = image
        var i = 0
        let pixels = width * height
        while i < pixels {
            let offset = i * 4
            aligned.bytes[offset] = clampByte(Float(image.bytes[offset]) / 255.0 * gainR * exposure)
            aligned.bytes[offset + 1] = clampByte(Float(image.bytes[offset + 1]) / 255.0 * gainG * exposure)
            aligned.bytes[offset + 2] = clampByte(Float(image.bytes[offset + 2]) / 255.0 * gainB * exposure)
            i += 1
        }
        return aligned
    }

    // MARK: - 8 位兜底（不依赖工作色彩空间）

    /// 在交付像素上直接做肩/趾压缩。门禁量裁切就是用 8 位 sRGB 的 luma，
    /// 所以这一步的结果不受 Core Image 工作色彩空间影响，是 kernel 没生效时的保底路径。
    static func shoulderToeBytes(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 30000, height <= 30000 else { return nil }
        let pixels = width * height
        guard pixels <= 100_000_000 else { return nil }
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height
        guard totalBytes > 0 else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: totalBytes)
        var output: CGImage?
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Void in
            guard let address = buffer.baseAddress,
                  let canvas = CGContext(data: address, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                        space: colorSpace,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            canvas.interpolationQuality = .none
            canvas.setBlendMode(.copy)
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            applyShoulderToeLUT(address.assumingMemoryBound(to: UInt8.self), totalBytes: totalBytes)
            output = canvas.makeImage()
        }
        return output
    }

    /// 256 项 LUT，就地改写 RGBA8（预乘）。alpha == 255 走快路径，
    /// 半透明像素先反预乘再查表，避免透明区域被压出一圈边。
    private static func applyShoulderToeLUT(_ pixels: UnsafeMutablePointer<UInt8>, totalBytes: Int) {
        var table = [UInt8](repeating: 0, count: 256)
        var i = 0
        while i < 256 {
            table[i] = clampByte(shoulderToe(Float(i) / 255.0))
            i += 1
        }
        table.withUnsafeBufferPointer { (lut: UnsafeBufferPointer<UInt8>) in
            guard let lutAddress = lut.baseAddress else { return }
            var offset = 0
            while offset + 3 < totalBytes {
                let alpha = pixels[offset + 3]
                if alpha == 255 {
                    pixels[offset] = lutAddress[Int(pixels[offset])]
                    pixels[offset + 1] = lutAddress[Int(pixels[offset + 1])]
                    pixels[offset + 2] = lutAddress[Int(pixels[offset + 2])]
                } else if alpha > 0 {
                    let inverse = 255.0 / Float(alpha)
                    var channel = 0
                    while channel < 3 {
                        let unpremultiplied = min(max(Float(pixels[offset + channel]) * inverse, 0.0), 255.0)
                        let mapped = lutAddress[Int(unpremultiplied)]
                        let repremultiplied = Float(mapped) * Float(alpha) / 255.0
                        pixels[offset + channel] = UInt8(min(max(repremultiplied, 0.0), 255.0))
                        channel += 1
                    }
                }
                offset += 4
            }
        }
    }

    // MARK: - 报告处理

    /// 裁切是否还需要 8 位兜底。
    static func needsClippingRepair(_ report: RetouchQualityReport) -> Bool {
        (report.metrics["clipping_full"] ?? 0) > clippingFullMax
            || (report.metrics["clipping_skin"] ?? 0) > clippingSkinMax
    }

    /// 裁切严重度排序分，越小越好；两次渲染里取这个分更低的那一版交付。
    static func clippingScore(_ report: RetouchQualityReport) -> Double {
        (report.metrics["clipping_full"] ?? 1.0) + (report.metrics["clipping_skin"] ?? 1.0)
    }

    /// 兜底后仍然不过：不抛错、不换图，只把 notes 改写成「唯一可执行动作」。
    /// `passed` 保持门禁的真实结论，绝不在这里翻案。
    static func actionable(_ report: RetouchQualityReport) -> RetouchQualityReport {
        guard !report.passed else { return report }
        var notes = report.notes
        if (report.metrics["skin_tone_de"] ?? 0) > skinToneHardMax
            || (report.metrics["skin_luma_shift"] ?? 0) > 18.0 {
            append(&notes, "→ 建议把精修强度降到 0.85 以下，或改选商业自然预设")
        }
        if (report.metrics["clipping_full"] ?? 0) > clippingFullMax
            || (report.metrics["clipping_skin"] ?? 0) > clippingSkinMax {
            append(&notes, "→ 建议换用欠曝一档的高光可恢复素材，或在导入前先做高光回收")
        }
        let retention = report.metrics["texture_retention"] ?? 1.0
        if retention < 0.50 || retention > 1.15 {
            append(&notes, "→ 建议把磨皮强度降到 0.85 以下，保留更多皮肤纹理")
        }
        if (report.metrics["ssim"] ?? 1.0) < 0.85 {
            append(&notes, "→ 建议把精修强度降到 0.85 以下，减少整图改动幅度")
        }
        if abs((report.metrics["seam_ratio"] ?? 1.0) - 1.0) > 0.30 {
            append(&notes, "→ 建议关闭换底/背景清理后重试，或换用更规整的皮肤蒙版")
        }
        return RetouchQualityReport(passed: report.passed, metrics: report.metrics, notes: notes)
    }

    private static func append(_ notes: inout [String], _ note: String) {
        if !notes.contains(note) { notes.append(note) }
    }

    /// 与门禁同样的字节夹取（0...1 → 0...255，四舍五入）。
    private static func clampByte(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, 0.0), 1.0) * 255.0 + 0.5
        return UInt8(min(clamped, 255.0))
    }
}
