import Foundation

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("FAIL: \(message)") }
    print("PASS: \(message)")
}
let shaky = SmartShutterEngine.decide(stability: 34, isStable: false, exposureScore: 100, sharpnessScore: 100)
expect(shaky.action == .wait, "High image quality cannot override severe camera shake")
let settling = SmartShutterEngine.decide(stability: 57, isStable: false, exposureScore: 100, sharpnessScore: 100)
expect(settling.action == .wait, "A settling camera waits before capture")
let dark = SmartShutterEngine.decide(stability: 100, isStable: true, exposureScore: 0, sharpnessScore: 0)
expect(dark.action == .wait, "Stable but unusable exposure and detail do not trigger capture")
let ready = SmartShutterEngine.decide(stability: 100, isStable: true, exposureScore: 90, sharpnessScore: 90)
expect(ready.action == .shootNow && ready.delay == 0, "A stable, well exposed scene captures immediately")
for exposure in stride(from: -100, through: 200, by: 10) {
    for sharpness in stride(from: -100, through: 200, by: 10) {
        let decision = SmartShutterEngine.decide(stability: 100, isStable: true, exposureScore: exposure, sharpnessScore: sharpness)
        expect((0...100).contains(decision.score), "Decision score stays bounded: \(exposure), \(sharpness)")
    }
}
print("All shutter decision tests passed")

let unstableHighScore = SmartShutterEngine.decide(stability: 90, isStable: false, exposureScore: 100, sharpnessScore: 100)
expect(unstableHighScore.action == .wait, "Unstable motion waits even at high stability score")
