import UIKit

/// Which interface orientations the app may use right now.
/// The camera screen can rotate; every other screen stays portrait, as before.
enum AppOrientation {
    static var mask: UIInterfaceOrientationMask = .portrait
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientation.mask
    }
}

enum OrientationPolicy {
    /// 当前前台窗口场景，找不到前台就退到第一个。
    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// 界面当前是不是横屏（用场景实际几何判断，不看设备方向）。
    static var isLandscapeNow: Bool {
        guard let scene = activeScene else { return false }
        switch scene.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return true
        default: return false
        }
    }

    /// Call on the main thread. Narrowing to `.portrait` also rotates a landscape screen back.
    static func apply(_ mask: UIInterfaceOrientationMask) {
        AppOrientation.mask = mask
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    /// 强制切到指定方向：先改 mask，再让所有 window 的根控制器刷新支持方向，
    /// 然后请求几何更新，完成回调里再刷新一次，保证按钮点下去一定生效。
    static func force(_ mask: UIInterfaceOrientationMask) {
        AppOrientation.mask = mask
        guard let scene = activeScene else { return }
        let windows = scene.windows
        windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
            windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }

    /// 手动兜底：横屏就转回竖屏并把自动旋转还给相机页，否则强制横屏。
    /// 设备跟随旋转失灵（或竖排锁定）时，这个按钮是唯一的出路。
    static func toggleLandscape() {
        if isLandscapeNow {
            force(.portrait)
            // 回到竖屏后再放开方向限制，用户继续晃动手机依然能自动旋转。
            DispatchQueue.main.async {
                if AppOrientation.mask == .portrait { AppOrientation.mask = .allButUpsideDown }
            }
        } else {
            force(.landscapeRight)
        }
    }
}
