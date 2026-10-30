import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 保守融合器（V18）。
///
/// 旧实现把两图缩到 128×128 逐像素比 RGB，要求「差 >12 的像素 <8% 且差 >65 的像素必须为 0」，
/// 结果 AI 只要动了光影或肤色就超 8%，融合几乎永远被拒，功能等于不存在，而且 128 像素
/// 根本看不出结构被重绘。
///
/// 现在改成「代理上量、分块投票、全分辨率只混合一次」：
/// 1) 512 长边代理上算 Lab ΔE00（逐像素）与分块结构相关；
/// 2) 16×16 = 256 块逐块投票：结构被重绘（<0.90）或改动过大（meanΔE>14）→ 保留本地像素；
///    完全没变（meanΔE<1.2）→ 权重 0；其余按「结构余量 × 改动余量」给权重；
/// 3) 256 块权重 → 16×16 浮点平面 → 双线性放大 → 高斯羽化 → 与 AI 版按蒙版混合。
///
/// 所有失败路径都返回 `Decision(applied:false)`，不抛错、不崩、不返回半成品。
final class SafeFusion {

    // MARK: - 失败类型

    /// 仍然保留 `renderFailed`：既有调用点用 `guard ... else { throw SafeFusion.Failure.renderFailed }`。
    enum Failure: LocalizedError {
        case invalidImage
        case renderFailed
        case sizeMismatch(String)
        case noValidRegion(String)

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "图像无法解码，融合已取消"
            case .renderFailed:
                return "融合渲染失败"
            case .sizeMismatch(let detail):
                return detail
            case .noValidRegion(let detail):
                return detail
            }
        }
    }

    // MARK: - 决策结果

    struct Decision {
        var applied: Bool
        var merged: UIImage?
        /// 采纳块占比（0...1）
        var acceptedRatio: Double
        /// 采纳区的平均 ΔE00
        var meanDeltaE: Double
        /// 采纳区的平均结构相关（1.0 = 结构完全一致）
        var structureKept: Double
        var rejectedTiles: Int
        var totalTiles: Int
        /// 中文，逐条可读
        var reasons: [String]
        /// 状态栏用
        var notes: [String]
    }

    // MARK: - 参数（照着验收表设，不要随意动）

    private enum Tuning {
        /// 代理长边：128 看不出结构破坏，512 够看结构又够快
        static let proxyLongEdge: CGFloat = 512
        /// 16×16 = 256 块
        static let grid = 16
        static let tileTotal = 256
        /// 长宽比容差 0.5%
        static let aspectTolerance = 0.005
        /// 结构相关下限：低于它就认为结构被重绘
        static let structureFloor = 0.90
        /// 单块平均 ΔE 上限：超过它就超出「只改肤色光影」范围
        static let meanDeltaECeil = 14.0
        /// 单块平均 ΔE 下限：低于它就是没改，权重 0
        static let meanDeltaEFloor = 1.2
        /// 权重斜坡宽度
        static let structureRamp = 0.08
        static let deltaERamp = 6.0
        /// 背景块权重衰减（主体占比 <0.5）
        static let backgroundDamp = 0.35
        /// 纪实/非生成式预设的额外保守系数
        static let conservativeDamp = 0.5
        /// 主体占比门槛
        static let subjectFloor = 0.5
        /// 全局兜底：采纳面积下限、采纳区平均 ΔE 上限
        static let minAcceptedArea = 0.05
        static let acceptedDeltaECeil = 10.0
        /// 结构拒绝块数达到这个值就整体放弃
        static let structureRejectReport = 3
        /// 羽化半径 = 长边 / 300
        static let blurDivisor: CGFloat = 300
        /// 权重小于它就當作不采纳
        static let weightEpsilon = 0.0001
    }

    private let context: CIContext = {
        // 与旧实现保持一致的线性工作色彩空间（混合在线性光下更接近物理正确）；
        // PixelKit 自己会把 8 位 sRGB 字节换算成 Lab，所以代理上的 ΔE00 不受这里影响。
        if let space = CGColorSpace(name: CGColorSpace.linearSRGB) {
            return CIContext(options: [.workingColorSpace: space, .useSoftwareRenderer: false])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - 对外：融合

    /// 保守融合。同步纯计算，不抛错：任何失败都返回 `applied:false` + 中文理由。
    func fuse(local: UIImage, ai: UIImage, subjectMask: UIImage?, allowsGenerative: Bool) -> Decision {
        guard let localCG = Self.cgImage(from: local), let aiCG = Self.cgImage(from: ai) else {
            return rejected("图像无法解码，融合已取消（原图未被改动）")
        }
        let localWidth = localCG.width
        let localHeight = localCG.height
        let aiWidth = aiCG.width
        let aiHeight = aiCG.height
        guard localWidth >= 8, localHeight >= 8, aiWidth >= 8, aiHeight >= 8 else {
            return rejected(String(format: "图像尺寸过小（本地 %dx%d，AI %dx%d），融合已取消",
                                   localWidth, localHeight, aiWidth, aiHeight))
        }

        // 1) 长宽比：比例对不上说明 AI 改了构图，任何逐像素融合都不可信
        let localAspect = Double(localWidth) / Double(localHeight)
        let aiAspect = Double(aiWidth) / Double(aiHeight)
        guard abs(aiAspect - localAspect) / localAspect <= Tuning.aspectTolerance else {
            return rejected(String(format: "AI 版尺寸与原图不一致（%dx%d vs %dx%d）",
                                   aiWidth, aiHeight, localWidth, localHeight))
        }

        var reasons: [String] = []
        // 比例一致但分辨率不同：统一到本地尺寸后再比，这也正是交付时的合成口径
        let aiAligned: CGImage
        if aiWidth == localWidth, aiHeight == localHeight {
            aiAligned = aiCG
        } else {
            guard let resized = Self.resized(aiCG, to: CGSize(width: localWidth, height: localHeight)) else {
                return rejected("AI 版缩放失败，融合已取消（原图未被改动）")
            }
            aiAligned = resized
            reasons.append(String(format: "AI 版分辨率 %dx%d 与本地 %dx%d 不同，已上采样到本地尺寸后按同构图比对",
                                  aiWidth, aiHeight, localWidth, localHeight))
        }

        // 2) 代理上量 + 分块投票（全分辨率上不做任何逐像素统计）
        guard let verdict = evaluate(local: localCG, ai: aiAligned, subjectMask: subjectMask,
                                     allowsGenerative: allowsGenerative) else {
            return rejected("代理图渲染失败，融合已取消（原图与 AI 版均未改动）")
        }
        reasons.append(contentsOf: verdict.notes)
        if let rejection = verdict.rejection {
            // 有完整分析但不采纳：把真实数字一起带回去，UI 才能显示「采纳率/结构相关」而不是 0
            var blockedReasons: [String] = [rejection]
            for item in reasons where item != rejection { blockedReasons.append(item) }
            var blockedNotes: [String] = []
            for item in blockedReasons { blockedNotes.append(item) }
            return Decision(applied: false,
                            merged: nil,
                            acceptedRatio: verdict.analysis.acceptedRatio,
                            meanDeltaE: verdict.analysis.acceptedMeanDeltaE,
                            structureKept: verdict.analysis.acceptedStructure,
                            rejectedTiles: verdict.analysis.structureRejectedTiles
                                + verdict.analysis.overEditTiles,
                            totalTiles: Tuning.tileTotal,
                            reasons: blockedReasons,
                            notes: blockedNotes)
        }
        let analysis = verdict.analysis

        // 3) 256 块权重 → 全分辨率羽化遮罩 → 与 AI 版按蒙版混合
        let extent = CGRect(x: 0, y: 0, width: localWidth, height: localHeight)
        guard let mask = maskImage(for: analysis, extent: extent) else {
            return rejected("融合蒙版生成失败，已保留本地方案")
        }
        let mergedCI = PixelKit.blend(CIImage(cgImage: aiAligned).cropped(to: extent),
                                      over: CIImage(cgImage: localCG).cropped(to: extent),
                                      mask: mask)
            .cropped(to: extent)
        guard let rendered = LocalTiledRenderer.render(mergedCI, extent: extent, context: context,
                                                       tileEdge: 2048) else {
            return rejected("融合渲染失败，已保留本地方案")
        }

        reasons.append("逐块投票通过：结构与改动量都在容差内，只融合 AI 的合规块（拒绝块保留本地像素）")
        let merged = UIImage(cgImage: rendered, scale: local.scale, orientation: .up)
        let note = String(format: "融合采用 %d%%（%d/%d 块）· 平均 ΔE %.1f · 结构相关 %.2f；拒绝：结构 %d 块 / 过度编辑 %d 块",
                          Int((analysis.acceptedRatio * 100).rounded()),
                          analysis.acceptedTiles, Tuning.tileTotal,
                          analysis.acceptedMeanDeltaE, analysis.acceptedStructure,
                          analysis.structureRejectedTiles, analysis.overEditTiles)
        return Decision(applied: true,
                        merged: merged,
                        acceptedRatio: analysis.acceptedRatio,
                        meanDeltaE: analysis.acceptedMeanDeltaE,
                        structureKept: analysis.acceptedStructure,
                        rejectedTiles: analysis.structureRejectedTiles + analysis.overEditTiles,
                        totalTiles: Tuning.tileTotal,
                        reasons: reasons,
                        notes: [note])
    }

    // MARK: - 对外：兼容旧入口

    /// 旧入口：只产遮罩不合成。走同一套投票；整体不采纳时返回全黑遮罩（= 全保留本地），不抛错。
    /// 旧调用点是「AI 改完本地版再融合」，属于生成式改动，所以这里按 `allowsGenerative: true` 处理。
    func conservativeMask(local: UIImage, ai: UIImage) throws -> CIImage {
        guard let localCG = Self.cgImage(from: local), let aiCG = Self.cgImage(from: ai) else {
            throw Failure.invalidImage
        }
        let extent = CGRect(x: 0, y: 0, width: localCG.width, height: localCG.height)
        guard localCG.width >= 8, localCG.height >= 8, aiCG.width >= 8, aiCG.height >= 8 else {
            throw Failure.invalidImage
        }
        let localAspect = Double(localCG.width) / Double(localCG.height)
        let aiAspect = Double(aiCG.width) / Double(aiCG.height)
        guard abs(aiAspect - localAspect) / localAspect <= Tuning.aspectTolerance else {
            // 尺寸/构图不一致：不是错误，就是「没有可融合区域」，给全黑遮罩
            return Self.emptyMask(extent: extent)
        }
        let aiAligned: CGImage
        if aiCG.width == localCG.width, aiCG.height == localCG.height {
            aiAligned = aiCG
        } else if let resized = Self.resized(aiCG, to: CGSize(width: localCG.width, height: localCG.height)) {
            aiAligned = resized
        } else {
            throw Failure.renderFailed
        }
        guard let verdict = evaluate(local: localCG, ai: aiAligned, subjectMask: nil,
                                     allowsGenerative: true) else {
            throw Failure.renderFailed
        }
        guard verdict.rejection == nil else { return Self.emptyMask(extent: extent) }
        guard let mask = maskImage(for: verdict.analysis, extent: extent) else {
            throw Failure.renderFailed
        }
        return mask
    }

    /// 旧入口：mask 白 = 取 AI，黑 = 保留本地。语义不变，只把渲染换成同一套 CI 口径。
    func blend(local: UIImage, ai: UIImage, mask: CIImage) throws -> UIImage {
        guard let localCG = Self.cgImage(from: local), let aiCG = Self.cgImage(from: ai) else {
            throw Failure.invalidImage
        }
        let extent = CGRect(x: 0, y: 0, width: localCG.width, height: localCG.height)
        guard aiCG.width == localCG.width, aiCG.height == localCG.height else {
            throw Failure.sizeMismatch(String(format: "AI 版与本地版尺寸不一致（%dx%d vs %dx%d）",
                                              aiCG.width, aiCG.height, localCG.width, localCG.height))
        }
        guard !mask.extent.isInfinite, !mask.extent.isNull,
              mask.extent.insetBy(dx: -1, dy: -1).contains(extent) else {
            throw Failure.noValidRegion("蒙版覆盖范围小于图像，拒绝全图覆盖")
        }
        let merged = PixelKit.blend(CIImage(cgImage: aiCG).cropped(to: extent),
                                    over: CIImage(cgImage: localCG).cropped(to: extent),
                                    mask: mask.cropped(to: extent))
            .cropped(to: extent)
        guard let rendered = LocalTiledRenderer.render(merged, extent: extent, context: context,
                                                       tileEdge: 2048) else {
            throw Failure.renderFailed
        }
        return UIImage(cgImage: rendered, scale: local.scale, orientation: .up)
    }

    // MARK: - 内部分析

    private struct TileOutcome {
        var weight: Float
        var meanDeltaE: Double
        var maxDeltaE: Double
        var structure: Double
        var rejectedStructure: Bool
        var rejectedOverEdit: Bool
        var noChange: Bool
        var accepted: Bool
    }

    private struct Analysis {
        var tiles: [TileOutcome]
        var acceptedTiles: Int
        var structureRejectedTiles: Int
        var overEditTiles: Int
        var noChangeTiles: Int
        var acceptedRatio: Double
        var acceptedMeanDeltaE: Double
        var acceptedStructure: Double
        var proxyWidth: Int
        var proxyHeight: Int
    }

    private struct Verdict {
        var analysis: Analysis
        var rejection: String?
        var notes: [String]
    }

    /// 代理尺寸上的评估 + 全局兜底判定。返回 nil = 代理渲染失败。
    private func evaluate(local: CGImage, ai: CGImage, subjectMask: UIImage?,
                          allowsGenerative: Bool) -> Verdict? {
        guard let analysis = analyze(local: local, ai: ai, subjectMask: subjectMask,
                                     allowsGenerative: allowsGenerative) else { return nil }
        var notes: [String] = []
        if analysis.noChangeTiles > 0 {
            notes.append(String(format: "无变化块 %d 块（ΔE<%.1f），按 0 权重处理，不计入采纳率",
                                analysis.noChangeTiles, Tuning.meanDeltaEFloor))
        }
        let rejection: String?
        if analysis.acceptedTiles == 0 || analysis.acceptedRatio < Tuning.minAcceptedArea {
            rejection = String(format: "采纳面积仅 %.0f%%（%d/%d 块，要求 ≥%.0f%%），已保留本地方案",
                               analysis.acceptedRatio * 100,
                               analysis.acceptedTiles, Tuning.tileTotal,
                               Tuning.minAcceptedArea * 100)
        } else if analysis.acceptedMeanDeltaE > Tuning.acceptedDeltaECeil {
            rejection = String(format: "采纳区平均 ΔE %.1f 超过 %.0f，改动幅度过大，已保留本地方案",
                               analysis.acceptedMeanDeltaE, Tuning.acceptedDeltaECeil)
        } else if analysis.structureRejectedTiles >= Tuning.structureRejectReport {
            rejection = String(format: "检测到 %d 块结构被重绘（人物/边缘），已保留本地方案",
                               analysis.structureRejectedTiles)
        } else {
            rejection = nil
        }
        return Verdict(analysis: analysis, rejection: rejection, notes: notes)
    }

    /// 代理上逐像素 Lab ΔE00 + 16×16 分块投票。全部分块统计都在这里完成。
    private func analyze(local: CGImage, ai: CGImage, subjectMask: UIImage?,
                         allowsGenerative: Bool) -> Analysis? {
        let longEdge = CGFloat(max(local.width, local.height))
        guard longEdge > 0 else { return nil }
        let scale = min(1.0, Tuning.proxyLongEdge / longEdge)
        let width = max(Tuning.grid, Int((CGFloat(local.width) * scale).rounded()))
        let height = max(Tuning.grid, Int((CGFloat(local.height) * scale).rounded()))
        guard width > 0, height > 0, width * height <= 4096 * 4096 else { return nil }
        guard let localProxy = PixelKit.renderRGBA8(CIImage(cgImage: local), width: width, height: height,
                                                    context: context),
              let aiProxy = PixelKit.renderRGBA8(CIImage(cgImage: ai), width: width, height: height,
                                                 context: context),
              localProxy.bytes.count >= width * height * 4,
              aiProxy.bytes.count >= width * height * 4 else { return nil }

        let localLab = PixelKit.lab(localProxy)
        let aiLab = PixelKit.lab(aiProxy)
        let localLuma = PixelKit.luma(localProxy)
        let aiLuma = PixelKit.luma(aiProxy)
        let needed = width * height
        guard localLab.l.values.count >= needed, localLab.a.values.count >= needed,
              localLab.b.values.count >= needed, aiLab.l.values.count >= needed,
              aiLab.a.values.count >= needed, aiLab.b.values.count >= needed,
              localLuma.values.count >= needed, aiLuma.values.count >= needed else { return nil }

        // 主体遮罩按代理尺寸渲染，用来判断某一块是不是背景
        var subject: FloatPlane?
        if let subjectMask, let maskCG = Self.cgImage(from: subjectMask),
           let rendered = PixelKit.renderRGBA8(CIImage(cgImage: maskCG), width: width, height: height,
                                               context: context) {
            let plane = PixelKit.luma(rendered)
            if plane.values.count >= needed { subject = plane }
        }

        let grid = Tuning.grid
        var tiles: [TileOutcome] = []
        tiles.reserveCapacity(Tuning.tileTotal)

        var acceptedTiles = 0
        var structureRejectedTiles = 0
        var overEditTiles = 0
        var noChangeTiles = 0
        var acceptedDeltaESum = 0.0
        var acceptedStructureSum = 0.0

        var gy = 0
        while gy < grid {
            let y0 = gy * height / grid
            let y1 = (gy + 1) * height / grid
            var gx = 0
            while gx < grid {
                let x0 = gx * width / grid
                let x1 = (gx + 1) * width / grid
                var tile = TileOutcome(weight: 0, meanDeltaE: 0, maxDeltaE: 0, structure: 1,
                                       rejectedStructure: false, rejectedOverEdit: false,
                                       noChange: true, accepted: false)
                if x1 > x0, y1 > y0 {
                    var count = 0.0
                    var sumLocal = 0.0
                    var sumAI = 0.0
                    var sumLocalSquare = 0.0
                    var sumAISquare = 0.0
                    var sumProduct = 0.0
                    var deltaESum = 0.0
                    var deltaEMax = 0.0
                    var y = y0
                    while y < y1 {
                        let row = y * width
                        var x = x0
                        while x < x1 {
                            let index = row + x
                            let lv = Double(localLuma.values[index])
                            let av = Double(aiLuma.values[index])
                            sumLocal += lv
                            sumAI += av
                            sumLocalSquare += lv * lv
                            sumAISquare += av * av
                            sumProduct += lv * av
                            let localColor = SIMD3<Float>(localLab.l.values[index],
                                                          localLab.a.values[index],
                                                          localLab.b.values[index])
                            let aiColor = SIMD3<Float>(aiLab.l.values[index],
                                                       aiLab.a.values[index],
                                                       aiLab.b.values[index])
                            let deltaE = Double(PixelKit.deltaE2000(localColor, aiColor))
                            deltaESum += deltaE
                            if deltaE > deltaEMax { deltaEMax = deltaE }
                            count += 1
                            x += 1
                        }
                        y += 1
                    }
                    if count > 0 {
                        let meanDeltaE = deltaESum / count
                        tile.meanDeltaE = meanDeltaE
                        tile.maxDeltaE = deltaEMax
                        let meanLocal = sumLocal / count
                        let meanAI = sumAI / count
                        var varianceLocal = sumLocalSquare / count - meanLocal * meanLocal
                        var varianceAI = sumAISquare / count - meanAI * meanAI
                        let covariance = sumProduct / count - meanLocal * meanAI
                        if varianceLocal < 0 { varianceLocal = 0 }
                        if varianceAI < 0 { varianceAI = 0 }
                        let sigmaLocal = varianceLocal.squareRoot()
                        let sigmaAI = varianceAI.squareRoot()
                        let epsilon = 1e-6
                        let structure: Double
                        if sigmaLocal < epsilon {
                            // 本地是平块：AI 也平才算结构保住了，否则就是凭空加东西
                            structure = sigmaAI < epsilon ? 1.0 : 0.0
                        } else if sigmaAI < epsilon {
                            // 本地有纹理、AI 却抹平了：结构被毁
                            structure = 0.0
                        } else {
                            structure = min(1.0, max(-1.0, covariance / (sigmaLocal * sigmaAI)))
                        }
                        tile.structure = structure

                        // 逐块投票（顺序判，先结构后改动量）
                        if structure < Tuning.structureFloor {
                            tile.rejectedStructure = true
                            tile.noChange = false
                            structureRejectedTiles += 1
                        } else if meanDeltaE > Tuning.meanDeltaECeil {
                            tile.rejectedOverEdit = true
                            tile.noChange = false
                            overEditTiles += 1
                        } else if meanDeltaE < Tuning.meanDeltaEFloor {
                            tile.noChange = true
                            noChangeTiles += 1
                        } else {
                            var weight = Self.clamp01((structure - Tuning.structureFloor) / Tuning.structureRamp) *
                                Self.clamp01((Tuning.meanDeltaECeil - meanDeltaE) / Tuning.deltaERamp)
                            // 背景块：AI 不许大改背景
                            if let subject {
                                var subjectSum = 0.0
                                var subjectCount = 0.0
                                var sy = y0
                                while sy < y1 {
                                    let row = sy * width
                                    var sx = x0
                                    while sx < x1 {
                                        subjectSum += Double(subject.values[row + sx])
                                        subjectCount += 1
                                        sx += 1
                                    }
                                    sy += 1
                                }
                                let ratio = subjectCount > 0 ? subjectSum / subjectCount : 0.0
                                if ratio < Tuning.subjectFloor { weight *= Tuning.backgroundDamp }
                            }
                            // 纪实/非生成式预设：更保守
                            if !allowsGenerative { weight *= Tuning.conservativeDamp }
                            tile.weight = Float(Self.clamp01(weight))
                            if weight > Tuning.weightEpsilon {
                                tile.noChange = false
                                tile.accepted = true
                                acceptedTiles += 1
                                acceptedDeltaESum += meanDeltaE
                                acceptedStructureSum += structure
                            }
                        }
                    }
                }
                tiles.append(tile)
                gx += 1
            }
            gy += 1
        }

        let acceptedRatio = Double(acceptedTiles) / Double(Tuning.tileTotal)
        let acceptedMeanDeltaE = acceptedTiles > 0 ? acceptedDeltaESum / Double(acceptedTiles) : 0
        let acceptedStructure = acceptedTiles > 0 ? acceptedStructureSum / Double(acceptedTiles) : 0
        return Analysis(tiles: tiles,
                        acceptedTiles: acceptedTiles,
                        structureRejectedTiles: structureRejectedTiles,
                        overEditTiles: overEditTiles,
                        noChangeTiles: noChangeTiles,
                        acceptedRatio: min(1.0, max(0.0, acceptedRatio)),
                        acceptedMeanDeltaE: acceptedTiles > 0 ? acceptedMeanDeltaE : 0,
                        acceptedStructure: acceptedTiles > 0 ? acceptedStructure : 0,
                        proxyWidth: width,
                        proxyHeight: height)
    }

    /// 16×16 权重平面 → 双线性放大到全分辨率 → 高斯羽化。
    private func maskImage(for analysis: Analysis, extent: CGRect) -> CIImage? {
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return nil }
        guard analysis.tiles.count == Tuning.tileTotal else { return nil }
        var plane = FloatPlane(width: Tuning.grid, height: Tuning.grid, value: 0)
        guard plane.values.count == Tuning.tileTotal else { return nil }
        for index in 0..<Tuning.tileTotal {
            plane.values[index] = max(0, min(1, analysis.tiles[index].weight))
        }
        // PixelKit.image 会把平面映射到 extent，CIImage 仿射变换自带双线性插值
        let scaled = PixelKit.image(from: plane, extent: extent)
        let longEdge = max(extent.width, extent.height)
        let radius = max(1.0, min(64.0, Double(longEdge / Tuning.blurDivisor)))
        let feathered = PixelKit.gaussian(scaled, radius: radius)
        return feathered.cropped(to: extent)
    }

    // MARK: - 小工具

    private func rejected(_ reason: String, extra: [String] = []) -> Decision {
        var reasons: [String] = [reason]
        for item in extra where item != reason { reasons.append(item) }
        var notes: [String] = []
        for item in extra where item != reason { notes.append(item) }
        notes.append(reason)
        return Decision(applied: false,
                        merged: nil,
                        acceptedRatio: 0,
                        meanDeltaE: 0,
                        structureKept: 0,
                        rejectedTiles: 0,
                        totalTiles: Tuning.tileTotal,
                        reasons: reasons,
                        notes: notes)
    }

    private static func emptyMask(extent: CGRect) -> CIImage {
        let black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        return CIImage(color: black).cropped(to: extent)
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1.0, max(0.0, value))
    }

    /// 方向归一化后的 CGImage：`.up` 直接返回原图，其余方向用 UIGraphicsImageRenderer 重画。
    private static func cgImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let pointSize = image.size
        guard pointSize.width >= 1, pointSize.height >= 1,
              pointSize.width.isFinite, pointSize.height.isFinite else { return nil }
        let pixelScale = max(image.scale, 1)
        let pixelSize = CGSize(width: (pointSize.width * pixelScale).rounded(),
                               height: (pointSize.height * pixelScale).rounded())
        guard pixelSize.width >= 1, pixelSize.height >= 1,
              pixelSize.width <= 30000, pixelSize.height <= 30000 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        return normalized.cgImage
    }

    /// 比例一致但分辨率不同时的上采样（交付口径就是本地尺寸）。
    private static func resized(_ cg: CGImage, to size: CGSize) -> CGImage? {
        guard size.width >= 1, size.height >= 1,
              size.width.isFinite, size.height.isFinite,
              size.width <= 30000, size.height <= 30000 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }
}
