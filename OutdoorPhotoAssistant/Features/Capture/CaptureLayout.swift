import CoreGraphics

/// Pure layout maths for the camera screen, kept free of SwiftUI so it can be tested.
enum CaptureLayout {
    /// Shutter sizes are part of the layout contract. Portrait is intentionally
    /// smaller because it sits inside the viewfinder above the filter controls.
    static let portraitShutterDiameter: CGFloat = 58
    static let landscapeShutterDiameter: CGFloat = 64
    static let portraitControlRailWidth: CGFloat = 42
    static let portraitControlOpacity: Double = 0.18
    static let portraitSelectedControlOpacity: Double = 0.48
    static let portraitSliderTintOpacity: Double = 0.65

    static func isLandscape(_ size: CGSize) -> Bool { size.width > size.height }

    /// The delivered still frame is always 4:3.  Keep the viewfinder on that
    /// ratio so that a transient analysis buffer never changes the composition.
    static func photoAspect(landscape: Bool) -> CGFloat {
        landscape ? 4.0 / 3.0 : 3.0 / 4.0
    }

    /// The rotation coordinator may briefly emit fractional values while the
    /// phone moves.  AVCapture connections need a stable quarter turn.
    static func normalizedRotationAngle(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 90 }
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        let quarterTurn = (positive / 90).rounded() * 90
        return quarterTurn >= 360 ? 0 : quarterTurn
    }

    static func isLandscape(rotationAngle: CGFloat) -> Bool {
        let angle = normalizedRotationAngle(rotationAngle)
        return angle == 0 || angle == 180
    }

    /// Width / height the preview should take. The analysis frame can lag behind a rotation by a
    /// moment, so a frame in the "wrong" orientation is flipped instead of trusted.
    static func previewAspect(frameAspect: CGFloat, landscape: Bool) -> CGFloat {
        _ = frameAspect
        return photoAspect(landscape: landscape)
    }

    /// Largest rectangle with `aspect` (width / height) that fits `available`.
    /// 除零与非法值一律返回 `.zero`，调用方再兜一个最小尺寸，布局不会算出 NaN。
    static func fit(aspect: CGFloat, in available: CGSize) -> CGSize {
        guard aspect.isFinite, aspect > 0,
              available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0 else { return .zero }
        let width = min(available.width, available.height * aspect)
        guard width.isFinite, width > 0 else { return .zero }
        let height = width / aspect
        guard height.isFinite, height > 0 else { return .zero }
        return CGSize(width: width, height: height)
    }

    // MARK: - 取景框规划（可单测）
    //
    // 为什么要有这个：取景框大小以前是「可用高度 − 若干魔数」硬算的，
    // 大字号 / 横竖屏 / 不同机型上会飘，出现过「预览被压小」和「内容装不下」。
    // 这里把「给多少空间、扣掉什么、取景框多大、有没有溢出」变成纯函数，
    // 由 tests/layout/main.swift 逐机型断言，UI 只负责把数字用上。

    struct Plan: Equatable {
        /// 取景框最终尺寸（已按 aspect 等比缩放）。
        var preview: CGSize
        /// 扣掉顶栏与控制区之后，取景框可用的高度（供 UI 做对齐）。
        var previewArea: CGSize
        /// > 0 表示内容装不下（会被压缩或裁切），单位 pt。
        var overflow: CGFloat
        /// 取景框面积 / 可用区域面积，越接近 1 越像系统相机的「满屏取景」。
        var fillRatio: Double
    }

    /// 横屏时控制区是**浮层**（不占布局高度），所以 `bottomBar` 传 0；
    /// 竖屏时控制区在布局流里，必须扣掉它的实测高度。
    static func plan(available: CGSize, landscape: Bool, aspect: CGFloat,
                     topBar: CGFloat, bottomBar: CGFloat,
                     horizontalPadding: CGFloat = 8, spacing: CGFloat = 8) -> Plan {
        guard available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0 else {
            return Plan(preview: .zero, previewArea: .zero, overflow: 0, fillRatio: 0)
        }
        let top = topBar.isFinite && topBar > 0 ? topBar : 0
        let bottom = bottomBar.isFinite && bottomBar > 0 ? bottomBar : 0
        let side = max(0, horizontalPadding * 2)
        let usableHeight = max(0, available.height - top - bottom - spacing)
        let area = CGSize(width: max(0, available.width - side), height: usableHeight)
        let preview = fit(aspect: aspect, in: area)
        let consumed = top + bottom + spacing + preview.height
        return Plan(preview: preview,
                    previewArea: area,
                    overflow: max(0, consumed - available.height),
                    fillRatio: (preview.width * preview.height) / max(1, available.width * available.height))
    }
}
