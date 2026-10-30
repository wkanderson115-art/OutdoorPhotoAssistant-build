import SwiftUI

@main
struct OutdoorPhotoAssistantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var camera = CameraService()
    @StateObject private var motion = MotionService()
    @StateObject private var analyzer = FrameAnalyzer()
    @StateObject private var location = LocationService()
    @StateObject private var library = PhotoLibraryService()

    init() {
        if UserDefaults.standard.string(forKey: "deepSeekModel") == "deepseek-v4-flash" {
            UserDefaults.standard.set(CloudConfiguration.deepSeekDefault, forKey: "deepSeekModel")
        }
        // One-time upgrade for installations that inherited build 8's off-by-default
        // capture features. After this migration, Settings remains authoritative.
        let defaults = UserDefaults.standard
        let migrationKey = "captureFixBuild11Applied"
        if !defaults.bool(forKey: migrationKey) {
            ["autoDirector", "autoComposition", "autoZoom", "autoCapture",
             "realtimeEffects", "liveBeauty", "showGrid"].forEach {
                defaults.set(true, forKey: $0)
            }
            if defaults.object(forKey: "liveBeautyStrength") == nil {
                defaults.set(0.16, forKey: "liveBeautyStrength")
            }
            defaults.set(true, forKey: migrationKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(camera)
                .environmentObject(motion)
                .environmentObject(analyzer)
                .environmentObject(location)
                .environmentObject(library)
                .onAppear {
                    APIKeyStore.removeLegacyBackendSession()
                    let analyzerRef = self.analyzer
                    self.camera.onFrame = { buffer, position in
                        analyzerRef.analyze(buffer, position: position)
                    }
                }
        }
    }
}
