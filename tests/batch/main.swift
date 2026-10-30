// tests/batch/main.swift
//
// 纯逻辑测试：只测 ShootAnchor / SkinAnalysis / BatchPhotoStatus 这些不碰像素的行为，
// 不发 UIKit 渲染、不建 CIContext、不写盘。Foundation + CoreImage + simd。
//
// 这里没有 Swift 编译器（Windows），下面是在 macOS / CI 上编译运行的命令。
//
// 关键点：本 harness 自己只用 Foundation + CoreImage，但它要测的 ShootAnchor /
// SkinAnalysis 定义在 RetouchStudioModel.swift / RetouchParameters.swift 里，前者
// `import UIKit`。所以不能像 tests/director、tests/cloud 那样用 macOS 目标直接跑，
// 必须编成 iOS 模拟器可执行文件：
//
//   cd src/OutdoorPhotoAssistant
//   mkdir -p build
//   xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator \
//     -o build/batch-tests \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchParameters.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchMaskKit.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchStudioModel.swift \
//     tests/batch/main.swift
//   xcrun simctl boot "iPhone 15" || true          # 任何一台可用模拟器
//   xcrun simctl bootstatus "iPhone 15" -b
//   xcrun simctl spawn booted build/batch-tests
//
// 如果 CI 想和其他 harness 一样跑 macOS 目标（`xcrun swiftc ... -o build/xxx && build/xxx`），
// 需要先把 ShootAnchor / SkinAnalysis 拆到一个不 import UIKit 的模型文件里，
// 那属于对现有文件的改动，不在本 harness 的范围内。
//
// 成功输出 PASS 行 + 汇总，退出码 0；任意一项失败输出 FAIL 行，退出码 1。

import Foundation
import CoreImage
import CoreGraphics
import simd

#if canImport(Darwin)
import Darwin
#endif

// MARK: - 断言框架（不用 XCTest，swiftc 直接出可执行文件）

var checkCount = 0
var failureCount = 0

func pass(_ name: String) {
    checkCount += 1
    print("PASS  \(name)")
}

func fail(_ name: String, _ detail: String) {
    checkCount += 1
    failureCount += 1
    print("FAIL  \(name)  ->  \(detail)")
}

func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        pass(name)
    } else {
        fail(name, detail.isEmpty ? "条件不成立" : detail)
    }
}

func checkClose(_ actual: Double, _ expected: Double, _ tolerance: Double, _ name: String) {
    let delta = abs(actual - expected)
    if delta <= tolerance {
        pass(name)
    } else {
        fail(name, "期望 \(expected) ± \(tolerance)，实际 \(actual)，差 \(delta)")
    }
}

func checkClose(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>, _ tolerance: Double, _ name: String) {
    let dx = abs(actual.x - expected.x)
    let dy = abs(actual.y - expected.y)
    let dz = abs(actual.z - expected.z)
    if dx <= tolerance && dy <= tolerance && dz <= tolerance {
        pass(name)
    } else {
        fail(name, "期望 \(expected) ± \(tolerance)，实际 \(actual)")
    }
}

func section(_ title: String) {
    print("")
    print("-- \(title)")
}

// MARK: - 构造桩数据

/// 4×4 的灰色 CIImage，只当掩膜占位（这些测试从不读像素）。
func stubMask() -> CIImage {
    CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
}

func stubGeometry() -> FaceGeometry {
    FaceGeometry(box: CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.50),
                 leftEye: nil,
                 rightEye: nil,
                 lips: nil,
                 nose: nil)
}

/// 一张合成的分析结果。`ShootAnchor.build` 只看 exposure / longEdge / skinLabMedian /
/// whiteBalance 四个字段，其余给稳定占位值即可。
func makeAnalysis(exposure: Double,
                  skinLab: SIMD3<Double> = SIMD3<Double>(62.0, 12.0, 18.0),
                  whiteBalance: SIMD3<Double> = SIMD3<Double>(1.0, 1.0, 1.0),
                  longEdge: CGFloat = 4000.0,
                  analysisEdge: CGFloat = 640.0) -> SkinAnalysis {
    let mask = stubMask()
    return SkinAnalysis(skinMask: mask,
                        featureMask: mask,
                        noiseSigma: 0.02,
                        geometry: stubGeometry(),
                        skinLabMedian: skinLab,
                        exposure: exposure,
                        whiteBalance: whiteBalance,
                        longEdge: longEdge,
                        analysisEdge: analysisEdge)
}

// MARK: - 1. 中位数与过滤

section("1. ShootAnchor.build(from:) 中位数 / 过滤")

let fiveExposures: [Double] = [0.40, 0.45, 0.50, 0.55, 0.60]
let fiveZ: [Double] = [16.0, 20.0, 18.0, 22.0, 17.0]

var fiveFrames: [SkinAnalysis] = []
for index in 0..<fiveExposures.count {
    let skin = SIMD3<Double>(60.0 + Double(index), 12.0, fiveZ[index])
    fiveFrames.append(makeAnalysis(exposure: fiveExposures[index], skinLab: skin))
}

guard let medianAnchor = ShootAnchor.build(from: fiveFrames) else {
    fail("五帧能建出锚点", "ShootAnchor.build 返回 nil")
    print("")
    print("== 结果：\(checkCount - failureCount)/\(checkCount) 项通过，失败 \(failureCount) 项 ==")
    exit(1)
}
pass("五帧能建出锚点")
check(medianAnchor.frameCount == 5, "frameCount == 5", "实际 \(medianAnchor.frameCount)")
checkClose(medianAnchor.exposure, 0.50, 1e-12, "曝光取中位数 0.50")
checkClose(medianAnchor.skinLabMedian, SIMD3<Double>(62.0, 12.0, 18.0), 1e-12,
           "肤色 Lab 逐通道取中位数 (62, 12, 18)")
checkClose(medianAnchor.whiteBalance, SIMD3<Double>(1.0, 1.0, 1.0), 1e-12,
           "白平衡取中位数 (1, 1, 1)")
checkClose(medianAnchor.maxEV, 0.75, 1e-12, "maxEV 默认 0.75")
checkClose(medianAnchor.maxWB, 0.12, 1e-12, "maxWB 默认 0.12")

// 无效帧必须被过滤：曝光 <= 0.02 或者 longEdge <= 0
var withInvalid = fiveFrames
withInvalid.append(makeAnalysis(exposure: 0.0))
withInvalid.append(makeAnalysis(exposure: 5.0, longEdge: 0.0))
withInvalid.append(makeAnalysis(exposure: 0.015))
if let filtered = ShootAnchor.build(from: withInvalid) {
    pass("混入无效帧仍能建出锚点")
    check(filtered.frameCount == 5, "无效帧被丢弃（frameCount 仍为 5）", "实际 \(filtered.frameCount)")
    checkClose(filtered.exposure, 0.50, 1e-12, "无效帧没有污染曝光中位数")
} else {
    fail("混入无效帧仍能建出锚点", "ShootAnchor.build 返回 nil")
}

// MARK: - 2. 单帧锚点 == 该帧

section("2. 单帧：锚点等于该帧自身")

let singleFrame = makeAnalysis(exposure: 0.55,
                               skinLab: SIMD3<Double>(61.0, 11.0, 17.0),
                               whiteBalance: SIMD3<Double>(1.02, 0.99, 1.00))
if let singleAnchor = ShootAnchor.build(from: [singleFrame]) {
    pass("单帧能建出锚点")
    check(singleAnchor.frameCount == 1, "frameCount == 1", "实际 \(singleAnchor.frameCount)")
    checkClose(singleAnchor.exposure, 0.55, 1e-12, "单帧锚点曝光 == 该帧")
    checkClose(singleAnchor.skinLabMedian, singleFrame.skinLabMedian, 1e-12, "单帧锚点肤色 == 该帧")
    checkClose(singleAnchor.whiteBalance, singleFrame.whiteBalance, 1e-12, "单帧锚点白平衡 == 该帧")

    // 单帧锚点对自己的修正必须是恒等：gain 1、ev 0
    let identity = singleAnchor.correction(for: singleFrame)
    checkClose(identity.gains, SIMD3<Double>(1.0, 1.0, 1.0), 1e-12, "单帧锚点对自身的 gain == 1")
    checkClose(identity.ev, 0.0, 1e-12, "单帧锚点对自身的 ev == 0")
} else {
    fail("单帧能建出锚点", "ShootAnchor.build 返回 nil")
}

// MARK: - 3. 空输入 / 全无效输入 -> nil

section("3. 空输入与全无效输入")

check(ShootAnchor.build(from: []) == nil, "空数组 -> nil")
check(ShootAnchor.build(from: [makeAnalysis(exposure: 0.0),
                               makeAnalysis(exposure: -1.0),
                               makeAnalysis(exposure: 0.5, longEdge: 0.0)]) == nil,
      "全部无效 -> nil")

// MARK: - 4. correction(for:) 的钳位

section("4. correction(for:) 钳位（±maxEV / ±6% WB）")

let referenceFrame = makeAnalysis(exposure: 0.50, skinLab: SIMD3<Double>(62.0, 12.0, 18.0))
guard let clampAnchor = ShootAnchor.build(from: [referenceFrame]) else {
    fail("钳位测试锚点", "ShootAnchor.build 返回 nil")
    print("")
    print("== 结果：\(checkCount - failureCount)/\(checkCount) 项通过，失败 \(failureCount) 项 ==")
    exit(1)
}

// 4a. 明显更亮的一帧：ev 为负（把画面压回来），且不超过 maxEV
let brighter = makeAnalysis(exposure: 0.50, skinLab: SIMD3<Double>(78.0, 12.0, 18.0))
let brightCorrection = clampAnchor.correction(for: brighter)
check(brightCorrection.ev < 0, "更亮的一帧 ev < 0", "实际 \(brightCorrection.ev)")
check(abs(brightCorrection.ev) <= clampAnchor.maxEV + 1e-12,
      "过曝帧 |ev| <= maxEV", "实际 \(brightCorrection.ev)")

// 4b. 明显更暗的一帧：ev 为正
let darker = makeAnalysis(exposure: 0.50, skinLab: SIMD3<Double>(48.0, 12.0, 18.0))
let darkCorrection = clampAnchor.correction(for: darker)
check(darkCorrection.ev > 0, "更暗的一帧 ev > 0", "实际 \(darkCorrection.ev)")
check(abs(darkCorrection.ev) <= clampAnchor.maxEV + 1e-12,
      "欠曝帧 |ev| <= maxEV", "实际 \(darkCorrection.ev)")

// 4c. 把 maxEV 收窄，钳位必须跟着收窄
var tightAnchor = clampAnchor
tightAnchor.maxEV = 0.10
check(abs(tightAnchor.correction(for: brighter).ev) <= 0.10 + 1e-12,
      "maxEV = 0.10 时过曝帧仍被限幅", "实际 \(tightAnchor.correction(for: brighter).ev)")
check(abs(tightAnchor.correction(for: darker).ev) <= 0.10 + 1e-12,
      "maxEV = 0.10 时欠曝帧仍被限幅", "实际 \(tightAnchor.correction(for: darker).ev)")

// 4d. 蓝通道偏色：蓝 gain 抬升，但被 maxWB 限幅；R/G 基本不动
let blueCast = makeAnalysis(exposure: 0.50, skinLab: SIMD3<Double>(62.0, 12.0, 18.0 * 0.70))
let castCorrection = clampAnchor.correction(for: blueCast)
check(castCorrection.gains.z > 1.0, "蓝色偏色帧 gain.z > 1", "实际 \(castCorrection.gains.z)")
check(castCorrection.gains.z <= 1.0 + clampAnchor.maxWB + 1e-12,
      "gain.z 被 maxWB 限幅", "实际 \(castCorrection.gains.z)")
check(abs(castCorrection.gains.x - 1.0) < 0.03, "偏色帧 R 基本不动", "实际 \(castCorrection.gains.x)")
check(abs(castCorrection.gains.y - 1.0) < 0.03, "偏色帧 G 基本不动", "实际 \(castCorrection.gains.y)")

// 4e. 蓝通道亏欠：gain 下降，但不会低于 1 - maxWB
let blueDeficit = makeAnalysis(exposure: 0.50, skinLab: SIMD3<Double>(62.0, 12.0, 18.0 / 0.70))
let deficitCorrection = clampAnchor.correction(for: blueDeficit)
check(deficitCorrection.gains.z < 1.0, "蓝色亏欠帧 gain.z < 1", "实际 \(deficitCorrection.gains.z)")
check(deficitCorrection.gains.z >= 1.0 - clampAnchor.maxWB - 1e-12,
      "gain.z 不低于 1 - maxWB", "实际 \(deficitCorrection.gains.z)")

// 4f. 三通道同时离谱：三个 gain 都必须落在 maxWB 区间内，且 ev 被 maxEV 限住
let extreme = makeAnalysis(exposure: 0.50,
                           skinLab: SIMD3<Double>(30.0, 12.0, 18.0 * 1.6))
let extremeCorrection = clampAnchor.correction(for: extreme)
let lower = 1.0 - clampAnchor.maxWB - 1e-12
let upper = 1.0 + clampAnchor.maxWB + 1e-12
let gainsInRange = extremeCorrection.gains.x >= lower && extremeCorrection.gains.x <= upper
    && extremeCorrection.gains.y >= lower && extremeCorrection.gains.y <= upper
    && extremeCorrection.gains.z >= lower && extremeCorrection.gains.z <= upper
check(gainsInRange, "极端帧三个 gain 都在 maxWB 区间内", "实际 \(extremeCorrection.gains)")
check(abs(extremeCorrection.ev) <= clampAnchor.maxEV + 1e-12,
      "极端帧 ev 被 maxEV 限住", "实际 \(extremeCorrection.ev)")

// 4g. maxWB 现在真的参与计算：收紧它，gain 的边界跟着收紧
var tightWB = clampAnchor
tightWB.maxWB = 0.02
let tightCast = tightWB.correction(for: blueCast)
check(tightCast.gains.z <= 1.02 + 1e-12, "maxWB = 0.02 时 gain.z <= 1.02", "实际 \(tightCast.gains.z)")

// MARK: - 5. 一组五帧的修正必须落在同一个区间

section("5. 一致性：五帧修正后都落在锚点 ±maxEV 内")

let setExposures: [Double] = [0.40, 0.45, 0.50, 0.55, 0.60]
let setL: [Double] = [58.0, 60.0, 62.0, 64.0, 66.0]     // 肤色亮度 ±3%，模拟同一套片的曝光漂移

var setFrames: [SkinAnalysis] = []
for index in 0..<setExposures.count {
    setFrames.append(makeAnalysis(exposure: setExposures[index],
                                  skinLab: SIMD3<Double>(setL[index], 12.0, 18.0)))
}

if let setAnchor = ShootAnchor.build(from: setFrames) {
    pass("五帧能建出统一锚点")
    check(setAnchor.frameCount == 5, "frameCount == 5", "实际 \(setAnchor.frameCount)")
    checkClose(setAnchor.skinLabMedian.x, 62.0, 1e-9, "锚点肤色 L 取中位数 62")

    var maxAbsEV = 0.0
    for index in 0..<setFrames.count {
        let frame = setFrames[index]
        let correction = setAnchor.correction(for: frame)
        check(abs(correction.ev) <= setAnchor.maxEV + 1e-12,
              "帧 \(index) |ev| <= maxEV", "实际 \(correction.ev)")
        check(abs(correction.gains.x - 1.0) <= setAnchor.maxWB + 1e-12
              && abs(correction.gains.y - 1.0) <= setAnchor.maxWB + 1e-12
              && abs(correction.gains.z - 1.0) <= setAnchor.maxWB + 1e-12,
              "帧 \(index) gain 在 maxWB 内", "实际 \(correction.gains)")
        maxAbsEV = max(maxAbsEV, abs(correction.ev))
    }
    // 同一套片里的曝光漂移必须被修到很小的范围内
    check(maxAbsEV <= 0.30, "五帧的曝光修正量都不超过 0.30 EV（一致性）", "实际最大 \(maxAbsEV) EV")

    // 首尾两帧的修正方向必须相反（一帧压、一帧提）
    let firstEV = setAnchor.correction(for: setFrames[0]).ev
    let lastEV = setAnchor.correction(for: setFrames[4]).ev
    check(firstEV > 0 && lastEV < 0, "最暗帧提亮、最亮帧压暗", "首 \(firstEV) 尾 \(lastEV)")
} else {
    fail("五帧能建出统一锚点", "ShootAnchor.build 返回 nil")
}

// MARK: - 6. 持久化 / 状态簿记

section("6. 锚点 Codable 往返 + 状态标签")

if let medianAnchorForCoding = ShootAnchor.build(from: fiveFrames) {
    do {
        let encoded = try JSONEncoder().encode(medianAnchorForCoding)
        let decoded = try JSONDecoder().decode(ShootAnchor.self, from: encoded)
        pass("ShootAnchor 可以 JSON 编解码")
        check(decoded.frameCount == medianAnchorForCoding.frameCount,
              "往返后 frameCount 不变",
              "期望 \(medianAnchorForCoding.frameCount)，实际 \(decoded.frameCount)")
        checkClose(decoded.exposure, medianAnchorForCoding.exposure, 1e-12, "往返后 exposure 不变")
        checkClose(decoded.skinLabMedian, medianAnchorForCoding.skinLabMedian, 1e-12,
                   "往返后 skinLabMedian 不变")
        checkClose(decoded.whiteBalance, medianAnchorForCoding.whiteBalance, 1e-12,
                   "往返后 whiteBalance 不变")
        checkClose(decoded.maxEV, medianAnchorForCoding.maxEV, 1e-12, "往返后 maxEV 不变")
        checkClose(decoded.maxWB, medianAnchorForCoding.maxWB, 1e-12, "往返后 maxWB 不变")
    } catch {
        fail("ShootAnchor 可以 JSON 编解码", "\(error)")
    }
} else {
    fail("ShootAnchor 可以 JSON 编解码", "ShootAnchor.build 返回 nil")
}

let allStatuses: [BatchPhotoStatus] = [.pending, .analysing, .processed, .approved, .rejected, .failed]
let statusLabels = allStatuses.map { $0.label }
check(statusLabels.count == 6, "六个状态都有 label", "实际 \(statusLabels.count)")
check(statusLabels.allSatisfy { !$0.isEmpty }, "状态 label 都不是空串", "\(statusLabels)")
check(Set(statusLabels).count == 6, "状态 label 互不相同", "\(statusLabels)")
check(BatchPhotoStatus.processed.label != BatchPhotoStatus.approved.label,
      "processed（待审核）与 approved（已通过）是不同标签，runner 不会替人审下结论",
      "\(BatchPhotoStatus.processed.label) / \(BatchPhotoStatus.approved.label)")

// MARK: - 汇总

print("")
let passed = checkCount - failureCount
print("== 结果：\(passed)/\(checkCount) 项通过，失败 \(failureCount) 项 ==")
if failureCount == 0 {
    print("== 全部通过 ==")
}
exit(failureCount == 0 ? 0 : 1)
