import Foundation
import CoreImage

/// 判断一张图是不是「手机截图 / UI 界面图」而不是实拍照片。
///
/// 为什么要判：截图没有「肤色」可言，也不该被套风格 Look。实测同一张截图，
/// 套了调色后 SSIM 从 0.999 掉到 0.914，document 口径的 0.92 下限直接判不过；
/// 所以必须在调色之前就把口径切成 document，而不是靠人工在预设分类里手选。
///
/// 三条独立特征，只有「边框特征」为真、并且（行列恒定性 或 色数）为真，才判截图：
/// 1. 边框带：上下左右各 6% 条带的「近纯黑（luma<0.03）/ 近纯白（luma>0.97）」占比，
///    四边平均 > 0.55 命中 —— 截图的黑边、白底、状态栏都长这样；
/// 2. 行列恒定性：整行 / 整列的标准差 < 0.008 的比例，任一侧 > 0.25 命中 ——
///    UI 的纯色条、白底、黑边会产生大量「一行/一列几乎没变化」；
/// 3. 色数：每通道 5 bit 量化后的唯一 RGB 组合数 < 3000 命中 —— 截图被 UI 压平。
///
/// 阈值不是我拍的，是 `tools/retouch_lab/screenshot_probe.py` 在 7 张真图上校准出来的
/// （复现命令：项目根跑 `python tools/retouch_lab/screenshot_probe.py`，需要 Pillow）：
/// * 截图 wuling_mini_auto：边框 0.661 / 恒定行 0.324 / 色数 1840 → 三项全中；
/// * 6 张实拍：边框最高 0.024、恒定行恒定列全是 0.000，色数 615–4300。
/// 所以边框门槛取 0.55（截图 0.661 有余量、实拍 0.024 差 23 倍），
/// 行列门槛取 0.25（截图 0.324 过线、实拍 0.000）。
///
/// 为什么要「边框 +（行列 或 色数）」：色数单独完全不可靠——缅因猫那张大片平滑地面只有
/// 615 色，旅行窗景 1814、红烧肉 2504，都低于 3000。反过来，带黑边的实拍（电影感、棚拍
/// 黑底）会命中边框，但它们的行列恒定性是 0（噪点与渐变更让每行都在变），色数也高，
/// 两条副证据拿不到，就不会被误杀。
///
/// 纯本地、零依赖，只跑在 550 长边代理（约 20 万像素）上，实测 < 15 ms。
enum ScreenshotDetector {

    /// 一次检测的结论。`reasons` 只放「命中的特征」，每条都带实测数字与阈值，可直接拼进质检报告。
    struct Verdict {
        var isScreenshot: Bool
        var reasons: [String]
        var confidence: Double
    }

    // MARK: - 阈值（与 tools/retouch_lab/screenshot_probe.py 保持一致）

    private enum Tuning {
        /// 代理长边：550 足够看出「整行恒定」，又只要 20 万像素
        static let proxyLongEdge: CGFloat = 550
        /// 边框条带宽度：上下左右各 6%
        static let borderBandRatio: Double = 0.06
        /// 「近纯黑 / 近纯白」的门槛
        static let extremeDark: Float = 0.03
        static let extremeLight: Float = 0.97
        /// 四边近纯黑/纯白占比的平均值门槛：截图实测 0.661，实拍最高 0.024
        static let borderExtremeRatio: Double = 0.55
        /// 一行/一列的 luma 标准差低于它就当「恒定」
        static let flatLineSigma: Float = 0.008
        /// 恒定行（或列）占比门槛：截图实测 0.324，实拍全是 0.000
        static let flatLineRatio: Double = 0.25
        /// 量化色数上限（每通道 5 bit → 最多 32768 种组合）：截图 1840 命中，实拍 3610 起不命中
        static let colorCountCeil = 3000
        static let colorCubeSize = 32768
    }

    // MARK: - 入口

    /// 判断是不是截图。任何失败都当普通照片处理，绝不抛错、绝不崩。
    static func inspect(_ image: CIImage, context: CIContext) -> Verdict {
        guard let proxy = PixelKit.renderRGBA8(image, maxEdge: Tuning.proxyLongEdge, context: context) else {
            return Verdict(isScreenshot: false, reasons: ["代理渲染失败，按普通照片处理"], confidence: 0)
        }
        let width = proxy.width
        let height = proxy.height
        let total = width * height
        guard width >= 8, height >= 8, total > 0, proxy.bytes.count >= total * 4 else {
            return Verdict(isScreenshot: false, reasons: ["代理尺寸过小，按普通照片处理"], confidence: 0)
        }

        // 灰度只算一遍，后面边框与行列统计都复用它
        let lumaPlane = PixelKit.luma(proxy)
        guard lumaPlane.values.count >= total else {
            return Verdict(isScreenshot: false, reasons: ["代理像素不可用，按普通照片处理"], confidence: 0)
        }

        // ---- 特征 1：边框带里的近纯黑 / 近纯白占比（四边分别算，再取平均）----
        // 与 probe 一致：上下条带取全宽、左右条带取全高（角上的黑边会同时计入，这正是 probe 的口径）
        let bandY = min(height, max(2, Int((Double(height) * Tuning.borderBandRatio).rounded())))
        let bandX = min(width, max(2, Int((Double(width) * Tuning.borderBandRatio).rounded())))

        func stripRatio(_ rows: Range<Int>, _ columns: Range<Int>) -> Double {
            guard columns.upperBound > columns.lowerBound, rows.upperBound > rows.lowerBound else { return 0 }
            var extreme = 0
            var count = 0
            var y = rows.lowerBound
            while y < rows.upperBound {
                let row = y * width
                var x = columns.lowerBound
                while x < columns.upperBound {
                    let value = lumaPlane.values[row + x]
                    if value < Tuning.extremeDark || value > Tuning.extremeLight { extreme += 1 }
                    count += 1
                    x += 1
                }
                y += 1
            }
            return count > 0 ? Double(extreme) / Double(count) : 0
        }

        let topRatio = stripRatio(0..<bandY, 0..<width)
        let bottomRatio = stripRatio((height - bandY)..<height, 0..<width)
        let leftRatio = stripRatio(0..<height, 0..<bandX)
        let rightRatio = stripRatio(0..<height, (width - bandX)..<width)
        let borderExtremeRatio = (topRatio + bottomRatio + leftRatio + rightRatio) / 4.0
        let borderHit = borderExtremeRatio > Tuning.borderExtremeRatio

        // ---- 特征 2：恒定行 / 恒定列占比（总体标准差，ddof=0，与 numpy 默认一致）----
        var flatRows = 0
        var y = 0
        while y < height {
            let row = y * width
            var sum = 0.0
            var sumSquare = 0.0
            var x = 0
            while x < width {
                let value = Double(lumaPlane.values[row + x])
                sum += value
                sumSquare += value * value
                x += 1
            }
            let n = Double(width)
            var variance = sumSquare / n - (sum / n) * (sum / n)
            if variance < 0 { variance = 0 }
            if variance.squareRoot() < Double(Tuning.flatLineSigma) { flatRows += 1 }
            y += 1
        }

        var flatColumns = 0
        var x = 0
        while x < width {
            var sum = 0.0
            var sumSquare = 0.0
            var yy = 0
            while yy < height {
                let value = Double(lumaPlane.values[yy * width + x])
                sum += value
                sumSquare += value * value
                yy += 1
            }
            let n = Double(height)
            var variance = sumSquare / n - (sum / n) * (sum / n)
            if variance < 0 { variance = 0 }
            if variance.squareRoot() < Double(Tuning.flatLineSigma) { flatColumns += 1 }
            x += 1
        }

        let flatRowRatio = Double(flatRows) / Double(height)
        let flatColumnRatio = Double(flatColumns) / Double(width)
        let lineHit = max(flatRowRatio, flatColumnRatio) > Tuning.flatLineRatio

        // ---- 特征 3：5 bit 量化后的唯一色数 ----
        // 量化口径与 probe 完全相同：level = round(byte/255*31)，用 256 项 LUT 免得逐像素做浮点乘
        var level = [Int](repeating: 0, count: 256)
        var lutIndex = 0
        while lutIndex < 256 {
            let raw = Double(lutIndex) / 255.0 * 31.0
            let rounded = Int(raw.rounded())
            level[lutIndex] = min(31, max(0, rounded))
            lutIndex += 1
        }
        var seen = [Bool](repeating: false, count: Tuning.colorCubeSize)
        var uniqueColors = 0
        var index = 0
        while index < total {
            let offset = index * 4
            let key = (level[Int(proxy.bytes[offset])] << 10)
                | (level[Int(proxy.bytes[offset + 1])] << 5)
                | level[Int(proxy.bytes[offset + 2])]
            if key >= 0, key < Tuning.colorCubeSize, !seen[key] {
                seen[key] = true
                uniqueColors += 1
            }
            index += 1
        }
        let colorHit = uniqueColors < Tuning.colorCountCeil

        // ---- 汇总：边框特征必须有，再要行列或色数其中之一 ----
        var reasons: [String] = []
        var hits = 0
        if borderHit {
            hits += 1
            reasons.append(String(format: "边框纯黑/纯白占比 %.1f%%（阈值 %.0f%%）",
                                  borderExtremeRatio * 100, Tuning.borderExtremeRatio * 100))
        }
        if lineHit {
            hits += 1
            reasons.append(String(format: "恒定行 %.1f%% / 恒定列 %.1f%%（阈值 %.0f%%）",
                                  flatRowRatio * 100, flatColumnRatio * 100, Tuning.flatLineRatio * 100))
        }
        if colorHit {
            hits += 1
            reasons.append(String(format: "量化色数 %d（阈值 %d）", uniqueColors, Tuning.colorCountCeil))
        }

        let confidence: Double
        switch hits {
        case 3: confidence = 1.0
        case 2: confidence = 0.75
        case 1: confidence = 0.45
        default: confidence = 0
        }

        // 只有「边框 + 其一」才判截图：边框是实拍的硬门槛，能把带黑边的电影感照片挡在外面。
        let isScreenshot = borderHit && (lineHit || colorHit)
        if hits == 0 {
            // 全都没命中时也给一行完整数字，方便现场核对阈值是不是设歪了
            reasons.append(String(format: "未命中截图特征：边框纯黑/纯白 %.1f%%（阈值 %.0f%%）、恒定行 %.1f%% / 恒定列 %.1f%%（阈值 %.0f%%）、量化色数 %d（阈值 %d）",
                                  borderExtremeRatio * 100, Tuning.borderExtremeRatio * 100,
                                  flatRowRatio * 100, flatColumnRatio * 100, Tuning.flatLineRatio * 100,
                                  uniqueColors, Tuning.colorCountCeil))
        }
        return Verdict(isScreenshot: isScreenshot, reasons: reasons, confidence: confidence)
    }
}
