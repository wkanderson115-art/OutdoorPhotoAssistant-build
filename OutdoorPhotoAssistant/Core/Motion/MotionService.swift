import Combine
import CoreMotion
import Foundation

/// 陀螺仪水平与稳定度。Device-motion callbacks run on a dedicated queue and only
/// coalesce onto the main actor at ~10Hz, so a 30Hz sensor no longer drives
/// 30 SwiftUI body evaluations per second.
final class MotionService: ObservableObject {
    private let manager = CMMotionManager()
    private let motionQueue = OperationQueue()

    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isLevel = false
    @Published var isStable = false
    @Published var stabilityScore: Int = 0

    private var lastPublish = -Double.infinity

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        motionQueue.qualityOfService = .userInitiated
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = motion.attitude.roll
            let rotation = hypot(motion.rotationRate.x, hypot(motion.rotationRate.y, motion.rotationRate.z))
            let isLevel = abs(roll) < 0.035
            let isStable = rotation < 0.12
            let stabilityScore = max(0, min(100, Int((1 - min(rotation / 0.6, 1)) * 100)))
            // Publish to the main actor at most ~10Hz; cheap captures of state
            // happen at sensor rate, but @Published churn is throttled.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastPublish >= 0.1 else { return }
            self.lastPublish = now
            DispatchQueue.main.async {
                self.roll = roll
                self.pitch = motion.attitude.pitch
                self.isLevel = isLevel
                self.isStable = isStable
                self.stabilityScore = stabilityScore
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
