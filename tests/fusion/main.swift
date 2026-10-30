import Foundation
import CoreGraphics
import CoreImage

// Runtime checks for HybridFusionEngine
// (OutdoorPhotoAssistant/Core/CommercialRetouch/HybridFusion.swift).
//
// Nothing here calls Vision: the quality score, the decision table, the geometry
// fitting and the fallback policy are all pure logic, so this harness runs on a
// headless machine. The person matte and the final masked blend are exercised by
// the app (and by the type-check), not here.
//
// Build and run (Mac Catalyst triple because the engine links UIKit + Vision):
//
//   xcrun --sdk macosx swiftc -target arm64-apple-ios17.6-macabi \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchParameters.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchMaskKit.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/HybridFusion.swift \
//     tests/fusion/main.swift -o build/fusion-tests && build/fusion-tests
//
// On a machine that cannot run a Catalyst binary, validate with
//   xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios17.6 <same files>

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: " + label)
    }
}

func expectClose(_ value: Double, _ expected: Double, _ tolerance: Double, _ label: String) {
    let ok = abs(value - expected) <= tolerance
    checks += 1
    if ok {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: \(label) -> got \(value), expected \(expected) +/- \(tolerance)")
    }
}

func expectThrowsSizeMismatch(_ label: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL: \(label) -> did not throw")
    } catch let error as HybridFusionError {
        switch error {
        case .sizeMismatch:
            print("PASS: " + label)
        default:
            failures += 1
            print("FAIL: \(label) -> threw \(error)")
        }
    } catch {
        failures += 1
        print("FAIL: \(label) -> threw \(error)")
    }
}

/// A report with the full metric set; every argument defaults to its ideal value.
func report(passed: Bool = true,
            texture: Double = 0.80,
            skinTone: Double = 1.5,
            seam: Double = 1.0,
            clippingSkin: Double = 0.0,
            clippingFull: Double = 0.0,
            ssim: Double = 0.95,
            notes: [String] = []) -> RetouchQualityReport {
    let metrics: [String: Double] = [
        "texture_retention": texture,
        "skin_tone_de": skinTone,
        "seam_ratio": seam,
        "clipping_skin": clippingSkin,
        "clipping_full": clippingFull,
        "ssim": ssim,
    ]
    return RetouchQualityReport(passed: passed, metrics: metrics, notes: notes)
}

let context = CIContext(options: [.useSoftwareRenderer: true])
let engine = HybridFusionEngine(context: context)

// MARK: - 1. Weights

print("-- weights --")

expectClose(HybridFusionEngine.textureWeight, 0.35, 1e-9, "texture carries 0.35")
expectClose(HybridFusionEngine.skinToneWeight, 0.25, 1e-9, "skin tone carries 0.25")
expectClose(HybridFusionEngine.seamWeight, 0.15, 1e-9, "seam carries 0.15")
expectClose(HybridFusionEngine.clippingWeight, 0.15, 1e-9, "clipping carries 0.15")
expectClose(HybridFusionEngine.ssimWeight, 0.10, 1e-9, "SSIM carries 0.10")
let weightSum = HybridFusionEngine.textureWeight + HybridFusionEngine.skinToneWeight
    + HybridFusionEngine.seamWeight + HybridFusionEngine.clippingWeight
    + HybridFusionEngine.ssimWeight
expectClose(weightSum, 1.0, 1e-9, "the five weights sum to 1")

// MARK: - 2. Scoring

print("-- scoring --")

expect(engine.score(nil) == 0, "a nil report scores zero")
expect(engine.score(report()) >= 0.95, "a perfect report scores at least 0.95")
expect(engine.score(report()) >= 0.999, "a perfect report scores essentially 1")
let emptyReport = RetouchQualityReport(passed: false, metrics: [:], notes: [])
expect(engine.score(emptyReport) == 0, "a report without metrics scores zero (no evidence)")
let partialReport = RetouchQualityReport(passed: true, metrics: ["texture_retention": 0.30], notes: [])
expectClose(engine.score(partialReport), 0.65, 1e-9,
            "the metrics a partial report does carry still count")
expect(engine.score(report()) == engine.score(report()), "scoring is deterministic")

// Texture: full credit inside 0.60...0.95, decay outside.
expectClose(HybridFusionEngine.textureScore(0.60), 1.0, 1e-9, "texture 0.60 is inside the ideal band")
expectClose(HybridFusionEngine.textureScore(0.95), 1.0, 1e-9, "texture 0.95 is inside the ideal band")
expect(engine.score(report(texture: 0.80)) > engine.score(report(texture: 0.50)),
       "texture below the band lowers the score")
expect(engine.score(report(texture: 0.50)) > engine.score(report(texture: 0.30)),
       "texture retention loss is monotone")
expect(engine.score(report(texture: 1.10)) < engine.score(report(texture: 0.80)),
       "over-smoothed texture above the band lowers the score")
expectClose(HybridFusionEngine.textureScore(0.30), 0.0, 1e-9, "texture 0.30 scores zero")

// Skin tone: ΔE00 <= 3 is perfect.
expect(engine.score(report(skinTone: 1.5)) > engine.score(report(skinTone: 4.0)),
       "skin tone above ΔE00 3 lowers the score")
expect(engine.score(report(skinTone: 4.0)) > engine.score(report(skinTone: 8.0)),
       "skin tone drift is monotone")
expectClose(HybridFusionEngine.skinToneScore(3.0), 1.0, 1e-9, "ΔE00 3 is a perfect skin match")

// Seam: 1.0 is perfect, tolerance ±0.30.
expect(engine.score(report(seam: 1.0)) > engine.score(report(seam: 1.12)),
       "a seam ratio away from 1 lowers the score")
expect(engine.score(report(seam: 1.12)) > engine.score(report(seam: 1.25)),
       "seam deviation is monotone")
expectClose(HybridFusionEngine.seamScore(1.30), 0.0, 1e-9, "a seam ratio of 1.30 scores zero")

// Clipping: 0 is perfect, normalised by the QC gate limits.
expect(engine.score(report(clippingSkin: 0.0)) > engine.score(report(clippingSkin: 0.001)),
       "any clipping lowers the score")
expect(engine.score(report(clippingSkin: 0.001)) > engine.score(report(clippingSkin: 0.0015)),
       "clipping is monotone")
expectClose(HybridFusionEngine.clippingScore(0.002, 0.010), 0.0, 1e-9,
            "clipping at the QC gate limits scores zero")

// SSIM: >= 0.85 is perfect.
expect(engine.score(report(ssim: 0.95)) > engine.score(report(ssim: 0.70)),
       "SSIM below 0.85 lowers the score")
expect(engine.score(report(ssim: 0.70)) > engine.score(report(ssim: 0.55)),
       "SSIM loss is monotone")
expectClose(HybridFusionEngine.ssimScore(0.85), 1.0, 1e-9, "SSIM 0.85 is perfect")

// Clamping and non-finite input.
let extreme = RetouchQualityReport(passed: false,
                                   metrics: ["texture_retention": -5, "skin_tone_de": 100,
                                             "seam_ratio": 100, "clipping_skin": 5,
                                             "clipping_full": 5, "ssim": -1],
                                   notes: [])
expect(engine.score(extreme) == 0, "total failure scores zero")
let nonFinite = RetouchQualityReport(passed: true,
                                     metrics: ["texture_retention": .nan, "skin_tone_de": .nan,
                                               "seam_ratio": .nan, "clipping_skin": .nan,
                                               "clipping_full": .nan, "ssim": .nan],
                                     notes: [])
let nonFiniteScore = engine.score(nonFinite)
expect(nonFiniteScore.isFinite && nonFiniteScore >= 0 && nonFiniteScore <= 1,
       "non-finite metrics still produce a bounded score")

// MARK: - 3. Decision table

print("-- decision table --")

let noCloud = HybridFusionEngine.decision(localScore: 0.90, cloudScore: 0.0,
                                          localPassed: true, cloudPassed: false,
                                          cloudAvailable: false)
expect(noCloud == .local, "no cloud render keeps the local version")

let worseCloud = HybridFusionEngine.decision(localScore: 0.90, cloudScore: 0.70,
                                             localPassed: true, cloudPassed: true,
                                             cloudAvailable: true)
expect(worseCloud == .local, "a cloud score more than 0.10 lower keeps the local version")

let boundaryCloud = HybridFusionEngine.decision(localScore: 0.90, cloudScore: 0.80,
                                                localPassed: true, cloudPassed: true,
                                                cloudAvailable: true)
expect(boundaryCloud == .hybrid, "a 0.10 gap is still inside the fusion window")

let justOutside = HybridFusionEngine.decision(localScore: 0.90, cloudScore: 0.79,
                                              localPassed: true, cloudPassed: true,
                                              cloudAvailable: true)
expect(justOutside == .local, "a 0.11 gap leaves the fusion window")

let cloudRescue = HybridFusionEngine.decision(localScore: 0.85, cloudScore: 0.90,
                                              localPassed: false, cloudPassed: true,
                                              cloudAvailable: true)
expect(cloudRescue == .cloud, "a failing local render loses to a passing cloud render")

let bothPass = HybridFusionEngine.decision(localScore: 0.90, cloudScore: 0.95,
                                           localPassed: true, cloudPassed: true,
                                           cloudAvailable: true)
expect(bothPass == .hybrid, "two passing renders within the window fuse")

let bothFail = HybridFusionEngine.decision(localScore: 0.40, cloudScore: 0.45,
                                           localPassed: false, cloudPassed: false,
                                           cloudAvailable: true)
expect(bothFail == .local, "two failing renders keep the local version")

let cloudFails = HybridFusionEngine.decision(localScore: 0.90, cloudScore: 0.95,
                                             localPassed: true, cloudPassed: false,
                                             cloudAvailable: true)
expect(cloudFails == .local, "a failing cloud render never replaces a passing local one")

let nonFiniteDecision = HybridFusionEngine.decision(localScore: .nan, cloudScore: 0.90,
                                                    localPassed: true, cloudPassed: true,
                                                    cloudAvailable: true)
expect(nonFiniteDecision == .local, "a non-finite score falls back to the local version")

// MARK: - 4. Geometry fitting

print("-- geometry fitting --")

let localImage = CIImage(color: CIColor(red: 0.40, green: 0.50, blue: 0.60, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
let cloudSmall = CIImage(color: CIColor(red: 0.80, green: 0.70, blue: 0.60, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
let cloudSquare = CIImage(color: CIColor(red: 0.70, green: 0.70, blue: 0.70, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 600, height: 600))
let zeroImage = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    .cropped(to: CGRect.zero)
let tinyImage = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

let fittedSmall = HybridFusionEngine.fitting(cloudSmall, into: localImage.extent)
expect(fittedSmall != nil, "a differently sized cloud render is fitted")
expect(fittedSmall?.extent == localImage.extent,
       "the fitted cloud render matches the local extent exactly")
let fittedSquare = HybridFusionEngine.fitting(cloudSquare, into: localImage.extent)
expect(fittedSquare?.extent == localImage.extent,
       "a square cloud render is centre-cropped onto the local extent")
expect(HybridFusionEngine.fitting(zeroImage, into: localImage.extent) == nil,
       "a zero sized cloud render cannot be fitted")
expect(HybridFusionEngine.fitting(cloudSmall, into: CGRect.zero) == nil,
       "a zero sized local extent cannot receive a cloud render")

let sameSize = HybridFusionEngine.fitting(localImage, into: localImage.extent)
expect(sameSize?.extent == localImage.extent, "an equally sized cloud render passes through")

// MARK: - 5. Fusion error and fallback policy

print("-- fusion fallback policy --")

expectThrowsSizeMismatch("a zero sized local image throws sizeMismatch") {
    _ = try engine.fuse(local: zeroImage, cloud: cloudSmall, analysis: nil, context: context)
}
expectThrowsSizeMismatch("a zero sized cloud image throws sizeMismatch") {
    _ = try engine.fuse(local: localImage, cloud: zeroImage, analysis: nil, context: context)
}

let tinyFusion = try? engine.fuse(local: tinyImage, cloud: cloudSmall, analysis: nil, context: context)
expect(tinyFusion != nil, "a 1x1 local image still returns a result instead of throwing")
expect(tinyFusion?.source == .local, "a 1x1 local image degrades to the local render")

let degraded = try? engine.fuse(local: localImage, cloud: cloudSmall, analysis: nil, context: context)
expect(degraded != nil, "a valid pair always returns a result")
if let degraded {
    expect(degraded.source == .local || degraded.source == .hybrid,
           "fusion never silently delivers the cloud render")
    expect(degraded.image.extent == localImage.extent,
           "the fused image keeps the local extent")
    expect(!degraded.reason.isEmpty, "the fusion result explains itself")
    expect(degraded.metrics["local_score"] != nil && degraded.metrics["cloud_score"] != nil,
           "fusion metrics carry both quality scores")
    expect(degraded.metrics["edge_weight"] != nil, "fusion metrics carry the edge weight")
    expect(degraded.metrics["feather_px"] != nil, "fusion metrics carry the feather radius")
}

expectClose(HybridFusionEngine.subjectEdgeWeight, 0.35, 1e-9, "the subject keeps a 0.35 local weight")
expectClose(Double(HybridFusionEngine.seamFeatherPx), 2.0, 1e-9, "the seam is feathered by 2 px")

// MARK: - 6. Selection end to end

print("-- selection --")

let strongReport = report()
let weakReport = report(texture: 0.30)
let nearReport = report(ssim: 0.80)
let failingLocal = report(passed: false, notes: ["未通过：结构相似度低于下限"])

let noCloudResult = engine.select(local: localImage, cloud: nil,
                                  localReport: strongReport, cloudReport: nil)
expect(noCloudResult.source == .local, "select without a cloud render keeps the local version")
expect(!noCloudResult.reason.isEmpty, "the local decision explains itself")
expect(noCloudResult.metrics["local_score"] != nil && noCloudResult.metrics["cloud_score"] != nil,
       "select metrics carry both scores")
let roundedScore = noCloudResult.metrics["local_score"] ?? -1
expect(abs(roundedScore * 1000 - (roundedScore * 1000).rounded()) < 1e-9,
       "reported scores carry three decimals")

let missingLocalResult = engine.select(local: localImage, cloud: cloudSmall,
                                       localReport: emptyReport, cloudReport: strongReport)
expect(missingLocalResult.source == .local,
       "missing local QC data never hands the delivery to the cloud render")

let worseCloudResult = engine.select(local: localImage, cloud: cloudSmall,
                                     localReport: strongReport, cloudReport: weakReport)
expect(worseCloudResult.source == .local,
       "a much worse cloud report keeps the local render")
expect(worseCloudResult.reason.contains("云端版质检分更低"),
       "the local decision names the lower cloud score")

let rescueResult = engine.select(local: localImage, cloud: cloudSmall,
                                 localReport: failingLocal, cloudReport: strongReport)
expect(rescueResult.source == .cloud, "a failing local render is replaced by a passing cloud one")
expect(rescueResult.image.extent == localImage.extent,
       "the delivered cloud render is fitted to the local extent")
expect(rescueResult.reason.contains("云端版"),
       "the cloud decision explains itself")

let tieResult = engine.select(local: localImage, cloud: cloudSmall,
                              localReport: strongReport, cloudReport: nearReport)
expect(tieResult.source != .cloud, "a tie never falls back to the raw cloud render")
expect(tieResult.image.extent == localImage.extent, "a tie keeps the local extent")

let tieAgain = engine.select(local: localImage, cloud: cloudSmall,
                             localReport: strongReport, cloudReport: nearReport)
expect(tieResult.source == tieAgain.source, "selection is deterministic")
expect(tieResult.metrics == tieAgain.metrics, "selection metrics are deterministic")

let nearScore = engine.score(nearReport)
expect(nearScore < engine.score(strongReport), "a slightly weaker cloud pass scores lower")

// MARK: - 7. Source labels

print("-- source labels --")

expect(HybridFusionSource.local.rawValue == "local", "the local source keeps its raw name")
expect(HybridFusionSource.cloud.rawValue == "cloud", "the cloud source keeps its raw name")
expect(HybridFusionSource.hybrid.rawValue == "hybrid", "the hybrid source keeps its raw name")
expect(!HybridFusionSource.hybrid.displayName.isEmpty, "the hybrid source has a display name")

if failures == 0 {
    print("\nALL PASS (\(checks) checks)")
} else {
    print("\nFAILURES: \(failures) of \(checks) checks")
    exit(1)
}
