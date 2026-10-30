import Foundation
import CoreGraphics

// Runtime tests for the pure-logic scoring helpers split out of FrameAnalyzer.
// These compile and run on macOS CI without UIKit, Vision or a camera, closing
// the gap that let build 27's undefined-symbol error ship unchecked.

var checks = 0
func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { fatalError("FAIL: " + label) }
    print("PASS: " + label)
}

// composeScore: subject at the rule-of-thirds point should beat a centered one.
let thirds = SubjectInfo(type: "人物", rect: CGRect(x: 0.30, y: 0.30, width: 0.20, height: 0.30))
let centered = SubjectInfo(type: "人物", rect: CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16))
let thirdScore = FrameScoring.composeScore(subject: thirds, brightness: 0.5, horizon: 0)
let centerScore = FrameScoring.composeScore(subject: centered, brightness: 0.5, horizon: 0)
expect(thirdScore > 0 && thirdScore <= 100, "Composition score is bounded 0-100")
expect(thirdScore >= centerScore, "A rule-of-thirds subject scores at least as well as a centered one")

// No subject should still produce a finite, bounded score (the 27-point base).
let empty = SubjectInfo()
let emptyScore = FrameScoring.composeScore(subject: empty, brightness: 0.5, horizon: 0)
expect(emptyScore >= 25 && emptyScore <= 35, "No-subject base score stays near 27")
expect(emptyScore == 27, "No-subject composition score is exactly the 27-point base")

// A tilted horizon must reduce the score relative to a level one at equal subject.
let tilted = FrameScoring.composeScore(subject: thirds, brightness: 0.5, horizon: 0.15)
expect(tilted < thirdScore, "A tilted horizon reduces the composition score")

// Extreme brightness should never yield the maximum exposure quality.
expect(FrameScoring.exposureQuality(0.05) == 40, "Near-black is worst exposure quality")
expect(FrameScoring.exposureQuality(0.98) == 40, "Near-white is worst exposure quality")
expect(FrameScoring.exposureQuality(0.5) == 100, "Mid-tone is best exposure quality")
expect(FrameScoring.exposureQuality(0.20) == 80, "Dim-but-visible light is mid quality")

// qualityLevel boundaries.
expect(FrameScoring.qualityLevel(exposure: 90, composition: 90, sharpness: 90) == "优秀", "All-90 is excellent")
expect(FrameScoring.qualityLevel(exposure: 70, composition: 70, sharpness: 70) == "良好", "All-70 is good")
expect(FrameScoring.qualityLevel(exposure: 50, composition: 50, sharpness: 50) == "需要调整", "All-50 needs adjustment")

// framingHint branches.
expect(FrameScoring.framingHint(subject: SubjectInfo(), scene: "风景") == "寻找前景层次，避免主体贴边",
       "Empty subject in landscape suggests foreground layers")
let leftSubject = SubjectInfo(type: "人物", rect: CGRect(x: 0.10, y: 0.40, width: 0.20, height: 0.30))
expect(FrameScoring.framingHint(subject: leftSubject, scene: "人物").contains("偏左"), "Left-biased subject is flagged left")
let rightSubject = SubjectInfo(type: "人物", rect: CGRect(x: 0.75, y: 0.40, width: 0.20, height: 0.30))
expect(FrameScoring.framingHint(subject: rightSubject, scene: "人物").contains("偏右"), "Right-biased subject is flagged right")

print("Analysis scoring tests passed: \(checks)")
