import SwiftUI
import UIKit
import CoreImage

struct CaptureView: View {
    let isSelected: Bool
    var onNavigate: (Int) -> Void = { _ in }
    @State private var autoPaused = false
    @State private var showingEffects = false
    @State private var comparingOriginal = false
    @State private var targetSelected = false
    @State private var selectedPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var exposureAdjustment = 0.0
    @State private var guidanceText = "寻找主体，点击人物指定拍摄对象"
    @State private var lastGuidanceAt = Date.distantPast
    @AppStorage("quietDirector") private var quietDirector = false
    /// 前置镜像开关，默认 false（不镜像）。只在「前置 + 开关打开」时预览与成片才会翻转。
    @AppStorage("mirrorFrontCamera") private var mirrorFrontCamera = false
    /// 当前布局是否横屏，由下面 GeometryReader 里的 onChange 同步，供宽高比与图标取用。
    @State private var uiIsLandscape = false
    /// 顶栏固定高度；取景框按它预算可用高度，保证不挤压下面的控制区。
    private let layoutTopBarHeight: CGFloat = 52
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var camera: CameraService
    @EnvironmentObject var motion: MotionService
    @EnvironmentObject var analyzer: FrameAnalyzer
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var library: PhotoLibraryService

    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("autoScene") private var autoScene = true
    @AppStorage("autoFilter") private var autoFilter = true
    @AppStorage("autoComposition") private var autoComposition = true
    @AppStorage("autoCapture") private var autoCapture = true
    @AppStorage("saveBoth") private var saveBoth = true
    @AppStorage("highQuality") private var highQuality = true

    @AppStorage("directorLearning") private var directorLearning = true
    @AppStorage("autoDirector") private var autoDirector = true
    @AppStorage("directorFraming") private var directorFraming = "自动"
    @AppStorage("directorComposition") private var directorComposition = "自动"
    @State private var directorController = DirectorController()
    @State private var showZoomControl = false
    @State private var pinchStartZoom: CGFloat?
    @State private var sliderZoom: Double?
    @State private var manualZoomText = "1.00"
    private let requestedZoomRange = 0.10...100.00
    @AppStorage("portraitDepth") private var portraitDepth = false
    @State private var showingSettings = false
    @AppStorage("autoZoom") private var autoZoom = true
    @State private var lastManualZoom = Date.distantPast
    @AppStorage("realtimeEffects") private var realtimeEffects = true
    @AppStorage("liveBeauty") private var liveBeauty = true
    @AppStorage("liveBeautyStrength") private var liveBeautyStrength = 0.16
    @AppStorage("liveBeautyMode") private var liveBeautyModeRaw = "自然"
    private var liveBeautyMode: PortraitBeautyMode { PortraitBeautyMode(rawValue: liveBeautyModeRaw) ?? .natural }
    @AppStorage("filterStrength") private var filterStrength = 0.55
    @State private var shotMetrics: (exposure: Int, sharpness: Int, composition: Int)?
    @State private var captureOptions: PhotoRenderOptions?
    @AppStorage("manualScene") private var manualScene = "风景"
    @AppStorage("manualFilter") private var manualFilterName = "自然"
    private var manualFilter: PhotoFilter { PhotoFilter(rawValue: manualFilterName) ?? .natural }
    @AppStorage("compositionStyle") private var compositionStyle = "自然"
    @State private var autoCaptureArmed = true
    @State private var readySince: Date?
    @State private var readyBox: CGRect = .zero
    @State private var trackedBox: CGRect = .zero
    @State private var trackingSince: Date?
    @State private var trackingUpdatedAt = Date.distantPast
    @State private var subjectSpeed = 0.0
    @State private var zoomRequestedAt = Date.distantPast
    @State private var zoomStart = 1.0
    @State private var zoomPausedUntil = Date.distantPast
    @AppStorage("directorBlur") private var directorBlur = true
    @AppStorage("directorBlurStrength") private var directorBlurStrength = 0.35
    @State private var showReview = false
    @State private var reviewShot: CapturedPhoto?
    @State private var reviewStyled: UIImage?
    @State private var reviewOptions = PhotoRenderOptions()
    @State private var reviewIsBest = false
    @State private var bestScore = 0
    @State private var activeRenders = 0
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var lastToken = UUID()
    @State private var filterGroup: FilterGroup = .basic
    @State private var filterThumbnails: [PhotoFilter: UIImage] = [:]
    @State private var thumbnailBase: UIImage?
    @State private var thumbnailTask: Task<Void, Never>?


    /// 取景框宽高比：竖屏、横屏各取一套，方向变了立刻跟着变。
    private var previewAspect: CGFloat { CaptureLayout.previewAspect(frameAspect: analyzer.frameAspectRatio, landscape: uiIsLandscape) }
    private var landscapePreviewAspect: CGFloat { CaptureLayout.previewAspect(frameAspect: analyzer.frameAspectRatio, landscape: true) }
    private var activeCaptureAspect: CGFloat { CaptureLayout.photoAspect(landscape: camera.isLandscapeCapture) }
    /// Only the camera itself may rotate; settings and review stay portrait.
    private var allowsRotation: Bool { isSelected && !showReview && !showingSettings }
    private var effectiveScene: String { autoScene ? analyzer.detectedScene : manualScene }
    private var effectiveFilter: PhotoFilter {
        guard autoFilter else { return manualFilter }
        if autoDirector { return PhotoFilter(rawValue: analyzer.directorDecision.filter) ?? .natural }
        guard !autoScene || analyzer.sceneConfidence >= 0.65 else { return .natural }
        return PhotoFilter.recommended(scene: effectiveScene, brightness: analyzer.brightness, period: location.periodText)
    }
    private var effectiveGrade: ColorGrade {
        let usesAutoGrade = autoFilter && (!autoScene || analyzer.sceneConfidence >= 0.65)
        var grade = ColorGrade.automatic(scene: effectiveScene, brightness: analyzer.brightness,
                                         period: location.periodText, confidence: autoScene ? analyzer.sceneConfidence : 1)
        if !usesAutoGrade { grade = ColorGrade() }
        if autoDirector && usesAutoGrade {
            let evidence = analyzer.directorObservation
            let measured = evidence.saturation
            let person = evidence.personCount > 0
            grade.saturation = measured > 0.48 ? 1.02 : measured < 0.12 ? 1.04 : person ? 1.08 : 1.16
            grade.temperature = 0 // Do not replace the actual scene light with a preset cast.
            grade.tint = 0
            grade.contrast = evidence.brightness < 0.16 ? 1.03 : 1.08
            grade.highlights = analyzer.directorDecision.protectHighlights ? -6 : 0
            grade.shadows = analyzer.directorDecision.liftShadows ? 3 : 0
        }
        let defaults = UserDefaults.standard
        grade.redSat += defaults.double(forKey: "spectrum_red")
        grade.orangeSat += defaults.double(forKey: "spectrum_orange")
        grade.yellowSat += defaults.double(forKey: "spectrum_yellow")
        grade.greenSat += defaults.double(forKey: "spectrum_green")
        grade.cyanSat += defaults.double(forKey: "spectrum_cyan")
        grade.blueSat += defaults.double(forKey: "spectrum_blue")
        grade.purpleSat += defaults.double(forKey: "spectrum_purple")
        return grade
    }

    // MARK: - 布局：竖屏与横屏共用同一批子视图

    private var topBar: some View {
        HStack(spacing: 0) {
            Menu {
                Button("图库") { onNavigate(1) }
                Button("摄影学院") { onNavigate(2) }
                Button("全部设置") { onNavigate(3) }
            } label: { Image(systemName: "square.grid.2x2").frame(width: 44, height: 44) }
            Button { camera.requestedFlash.toggle() } label: {
                Image(systemName: camera.requestedFlash ? "bolt.fill" : "bolt.slash").frame(width: 44, height: 44)
            }.accessibilityLabel("拍照闪光灯").disabled(!camera.flashAvailable)
            Spacer(minLength: 0)
            Button { camera.switchCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 44, height: 44) }
                .accessibilityLabel("切换前后摄像头")
            // 手动横竖屏兜底：设备没有自动旋转时也能强制横过来拍。
            Button { OrientationPolicy.toggleLandscape() } label: {
                Image(systemName: uiIsLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.system(size: 19))
                    .frame(width: 44, height: 44)
            }.accessibilityLabel("横竖屏切换")
            if camera.cameraPosition == .front {
                // 前置镜像开关：默认关闭，后置摄像头永远不出现这个按钮。
                Button { mirrorFrontCamera.toggle() } label: {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(mirrorFrontCamera ? Color.mint : Color.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("前置镜像")
            }
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20)).frame(width: 44, height: 44)
            }.accessibilityLabel("拍摄设置").foregroundStyle(.white)
                .disabled(activeRenders > 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    private func previewView(width: CGFloat, height: CGFloat) -> some View {
        CameraPreview(camera: camera, options: currentRenderOptions(), effectsEnabled: !comparingOriginal && (realtimeEffects || liveBeauty || effectiveFilter != .natural || (directorBlur && autoDirector)),
                      autoFocusPoint: autoDirector && !camera.focusExposureLocked && Date().timeIntervalSince(analyzer.visionEvidenceAt) < 0.8 ? (targetSelected && analyzer.subject.rect != .zero ? CGPoint(x: analyzer.subject.rect.midX, y: analyzer.subject.rect.midY) : analyzer.visionEvidence.focusPoint) : nil,
                      focusObservationTick: analyzer.observationTick,
                      mirrored: mirrorFrontCamera,
                      onSubjectTap: { point, locked in
                          targetSelected = true; selectedPoint = point; analyzer.selectSubject(at: point)
                          camera.setFocusExposureLock(locked)
                          readySince = nil
                      },
                      onZoomGesture: { scale, finished in
                          if pinchStartZoom == nil { pinchStartZoom = camera.zoom }
                          let start = pinchStartZoom ?? camera.zoom
                          applyManualZoom(Double(start * scale), reportLimit: false)
                          if finished {
                              pinchStartZoom = nil
                              sliderZoom = nil
                          }
                      })
            .frame(width: width, height: height)
            .overlay {
                CompositionOverlay(showGrid: showGrid,
                                   automaticFraming: autoComposition && autoDirector,
                                   subject: analyzer.subject,
                                   composition: directorComposition,
                                   locked: analyzer.autoCaptureReady && camera.controlsSettled && analyzer.visionEvidence.eyes != "closed")
            }
            .overlay {
                GeometryReader { proxy in
                    if targetSelected {
                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                            Slider(value: $exposureAdjustment, in: -2...2)
                                .frame(width: 95)
                                .onChange(of: exposureAdjustment) { _, value in camera.setUserExposure(Float(value)); readySince = nil }
                        }.foregroundStyle(.yellow)
                            .frame(width: 120)
                            .position(x: max(70, min(proxy.size.width - 70, selectedPoint.x * proxy.size.width)),
                                      y: max(35, min(proxy.size.height - 70, (1 - selectedPoint.y) * proxy.size.height + 45)))
                    }
                    if abs(analyzer.horizonAngle) > 0.03 && autoComposition {
                        Capsule().fill(.white.opacity(0.65)).frame(width: 70, height: 2)
                            .rotationEffect(.radians(-analyzer.horizonAngle))
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            .allowsHitTesting(false)
                    }
                }
            }
    }

    /// 竖屏第 1 行：滤镜图标胶囊（不再带标题行）+ 右侧「更多」入口。
    private var filterRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip(icon: "sparkles", title: "自动", selected: autoFilter) {
                        autoFilter = true
                        readySince = nil
                    }
                    ForEach(PhotoFilter.filters(in: filterGroup)) { filter in
                        filterChip(icon: filter.icon, title: filter.rawValue,
                                   selected: !autoFilter && manualFilter == filter) {
                            autoFilter = false
                            manualFilterName = filter.rawValue
                            readySince = nil
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            Button { autoPaused = true; showingEffects = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("更多效果")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("拍照滤镜")
    }

    /// 单个滤镜：只留图标（名字进 accessibilityLabel），38pt 高度让控制区能压到两行。
    private func filterChip(icon: String, title: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(width: 38, height: 38)
                .background(selected ? Color.mint : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 横屏左上：滤镜入口，点一下直接开现有的更多效果 sheet。
    private var filterEntryCapsule: some View {
        Button { autoPaused = true; showingEffects = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "camera.filters").font(.system(size: 12))
                Text(filterGroup.rawValue).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 10)
            .background(.black.opacity(0.40), in: Capsule())
            .foregroundStyle(.white)
        }
        .accessibilityLabel("滤镜")
    }

    /// 竖屏第 2 行：变焦快捷胶囊 + 当前倍率 + 意图 Menu + 效果前预览长按。
    private var zoomAndIntentRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                zoomChips.padding(.horizontal, 2)
            }
            currentZoomButton
            intentMenuCapsule
            exposurePreviewCapsule
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    /// 意图从 Picker 收成一个 Menu 胶囊（原来那行 Picker 太占高度）；「安静/显示引导」也收进来。
    private var intentMenuCapsule: some View {
        Menu {
            ForEach(["自动", "环境", "完整人物", "半身", "特写", "合影", "运动", "突出主体"], id: \.self) { item in
                Button {
                    directorFraming = item
                } label: {
                    if directorFraming == item { Label(item, systemImage: "checkmark") } else { Text(item) }
                }
            }
            Divider()
            Button(quietDirector ? "显示导演引导" : "安静模式（只看数据）") { quietDirector.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "scope").font(.system(size: 12))
                Text(directorFraming).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(minWidth: 44, minHeight: 32)
            .padding(.horizontal, 9)
            .background(Color.white.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("拍摄意图")
    }

    /// 效果前预览：按住临时关掉实时效果做对比。
    private var exposurePreviewCapsule: some View {
        Image(systemName: "eye")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 38, height: 32)
            .background(comparingOriginal ? Color.mint.opacity(0.45) : Color.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                comparingOriginal = pressing
                if pressing { readySince = nil }
            }, perform: {})
            .accessibilityLabel("按住查看效果前预览")
    }

    /// 主体已选 + 曝光滑杆：只在 targetSelected 时作为取景框内的浮层出现，不占布局高度。
    private var subjectOverlay: some View {
        HStack(spacing: 8) {
            Text(camera.focusExposureLocked ? "主体与AE/AF锁定" : "已选择主体")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Button("恢复自动") {
                targetSelected = false
                analyzer.selectSubject(at: nil)
                camera.setFocusExposureLock(false)
                camera.setUserExposure(nil)
                exposureAdjustment = 0
                lastManualZoom = .distantPast
            }
            .font(.system(size: 11, weight: .semibold))
            Image(systemName: "sun.max").font(.system(size: 11))
            Slider(value: $exposureAdjustment, in: -2...2)
                .frame(width: 110)
                .onChange(of: exposureAdjustment) { _, value in
                    camera.setUserExposure(Float(value))
                    readySince = nil
                }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }

    /// 横屏单行导演条：贴取景框底部居中，不压快门。
    private var directorOverlayLine: some View {
        HStack(spacing: 8) {
            if !quietDirector {
                Text(directorCompositionText).lineLimit(1).truncationMode(.tail)
            }
            Text(directorCurrentText).lineLimit(1).monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
        .frame(maxWidth: 380)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("导演提示")
    }

    /// 取景框：尺寸完全由 CaptureLayout.plan 算，UI 不再自己扣魔数。
    private func previewBox(_ plan: CaptureLayout.Plan) -> some View {
        let size = plan.preview.width > 1 && plan.preview.height > 1
            ? plan.preview
            : CGSize(width: 200, height: 200 / max(0.1, previewAspect))
        return previewView(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)
    }

    /// Portrait uses a full-area preview. The top bar, right controls and shutter
    /// are transparent edge overlays and no longer consume preview height.
    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        let width = max(1, geo.size.width)
        let height = max(1, geo.size.height)
        return ZStack {
            previewView(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            topBar
                .frame(height: layoutTopBarHeight)
                .background(
                    LinearGradient(colors: [.black.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .overlay(alignment: .trailing) {
            portraitRightControlRail
                .padding(.trailing, 9)
                .padding(.top, layoutTopBarHeight + 12)
                .padding(.bottom, 96)
        }
        .overlay(alignment: .bottom) {
            if targetSelected { subjectOverlay.padding(.bottom, 86) }
        }
        .overlay(alignment: .bottom) {
            directorOverlayLine
                .padding(.horizontal, 70)
                .padding(.bottom, 80)
        }
        .overlay(alignment: .bottom) {
            portraitViewfinderControls
        }
    }

    /// 竖屏右侧控制栏：滤镜与变焦沿取景框边缘纵向排列。窄栏与透明底
    /// 只保证按钮可辨认，取景画面仍连续铺满整个拍摄页。
    private var portraitRightControlRail: some View {
        let rail = CaptureLayout.portraitControlRailWidth
        // Two quick filters plus “more” keep the filter and zoom sections separate
        // even on the shortest supported iPhone screen.
        let quickFilters = Array(PhotoFilter.filters(in: filterGroup).prefix(2))

        return VStack(spacing: 5) {
            portraitRailButton(icon: "sparkles", title: "自动滤镜", selected: autoFilter) {
                autoFilter = true
                readySince = nil
            }
            ForEach(quickFilters) { filter in
                portraitRailButton(icon: filter.icon, title: filter.rawValue,
                                   selected: !autoFilter && manualFilter == filter) {
                    autoFilter = false
                    manualFilterName = filter.rawValue
                    readySince = nil
                }
            }
            portraitRailButton(icon: "ellipsis", title: "更多滤镜", selected: false) {
                autoPaused = true
                showingEffects = true
            }

            Divider()
                .overlay(.white.opacity(0.25))
                .frame(width: rail - 12)

            portraitInlineZoomControl

            portraitIntentRailButton
            portraitCompareRailButton
        }
        .foregroundStyle(.white)
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .background(.black.opacity(CaptureLayout.portraitControlOpacity), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 3)
        .accessibilityElement(children: .contain)
    }

    private func portraitRailButton(icon: String, title: String, selected: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(width: CaptureLayout.portraitControlRailWidth, height: 33)
                .background(selected ? Color.mint.opacity(CaptureLayout.portraitSelectedControlOpacity) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(selected ? 0 : 0.45), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 取景框内连续变焦：拖动为对数变焦，上下按钮每次精确调整 0.01×；
    /// 点击当前倍率可展开数字输入与完整控制面板。
    private var portraitInlineZoomControl: some View {
        let low = max(requestedZoomRange.lowerBound, Double(camera.minimumZoom))
        let high = min(requestedZoomRange.upperBound,
                       max(Double(camera.minimumZoom), Double(camera.maximumZoom)))

        return VStack(spacing: 2) {
            Button { nudgeManualZoom(by: 0.01) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: CaptureLayout.portraitControlRailWidth, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("增加0.01倍变焦")

            if high > low {
                Slider(value: zoomSliderBinding,
                       in: log(low)...log(high),
                       onEditingChanged: { editing in
                           if editing {
                               autoZoom = false
                               lastManualZoom = Date()
                           } else {
                               sliderZoom = nil
                           }
                       })
                    .tint(.mint.opacity(CaptureLayout.portraitSliderTintOpacity))
                    .frame(width: 72, height: 18)
                    .rotationEffect(.degrees(-90))
                    .frame(width: CaptureLayout.portraitControlRailWidth, height: 72)
                    .accessibilityLabel("屏幕内连续变焦")
                    .accessibilityValue(String(format: "%.2f倍", Double(camera.zoom)))
            }

            Button { showZoomControl = true } label: {
                Text(String(format: "%.2f×", Double(camera.zoom)))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.7)
                    .frame(width: CaptureLayout.portraitControlRailWidth, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开手动变焦输入")

            Button { nudgeManualZoom(by: -0.01) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: CaptureLayout.portraitControlRailWidth, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("减少0.01倍变焦")
        }
    }

    private var portraitIntentRailButton: some View {
        Menu {
            ForEach(["自动", "环境", "完整人物", "半身", "特写", "合影", "运动", "突出主体"], id: \.self) { item in
                Button {
                    directorFraming = item
                } label: {
                    if directorFraming == item { Label(item, systemImage: "checkmark") }
                    else { Text(item) }
                }
            }
            Divider()
            Button(quietDirector ? "显示导演引导" : "安静模式") { quietDirector.toggle() }
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: CaptureLayout.portraitControlRailWidth, height: 31)
        }
        .accessibilityLabel("拍摄意图")
    }

    private var portraitCompareRailButton: some View {
        Image(systemName: "eye")
            .font(.system(size: 14, weight: .semibold))
            .frame(width: CaptureLayout.portraitControlRailWidth, height: 31)
            .background(comparingOriginal ? Color.mint.opacity(CaptureLayout.portraitSelectedControlOpacity) : Color.clear,
                        in: Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                comparingOriginal = pressing
                if pressing { readySince = nil }
            }, perform: {})
            .accessibilityLabel("按住查看效果前预览")
    }

    /// 横屏：系统相机形态 —— 取景框居中（左右黑边是 4:3 在宽屏里的必然结果），
    /// 控件全部是 .overlay 浮层、不占布局高度，所以 bottomBar 传 0 给 plan。
    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        let plan = CaptureLayout.plan(available: geo.size,
                                      landscape: true,
                                      aspect: landscapePreviewAspect,
                                      topBar: layoutTopBarHeight,
                                      bottomBar: 0,
                                      horizontalPadding: 8,
                                      spacing: 8)
        let size = plan.preview.width > 1 && plan.preview.height > 1
            ? plan.preview
            : CGSize(width: 300, height: 225)
        return ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                topBar.frame(height: layoutTopBarHeight)
                previewView(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topTrailing) {
                        Label("横拍 4:3", systemImage: "rectangle.landscape")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        if targetSelected { subjectOverlay.padding(.bottom, 36) }
                    }
                    .overlay(alignment: .bottom) {
                        directorOverlayLine.padding(.bottom, 8)
                    }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 左上（顶栏下方）：滤镜入口 / 意图
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                filterEntryCapsule
                intentMenuCapsule
            }
            .padding(.leading, 16)
            .padding(.top, layoutTopBarHeight + 8)
        }
        // 左下：相册缩略图
        .overlay(alignment: .bottomLeading) {
            galleryThumb
                .padding(.leading, 24)
                .padding(.bottom, 37)
        }
        // 右下：变焦快捷胶囊 + 当前倍率（在快门上方，带半透明底，压在画面上也能看清）
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 6) {
                zoomChips
                currentZoomButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(.trailing, 28)
            .padding(.bottom, CGFloat(24 + 72 + 12))
        }
        // 右下：快门
        .overlay(alignment: .bottomTrailing) {
            shutterButton
                .padding(.trailing, 28)
                .padding(.bottom, 24)
        }
        // 快门左侧：自动拍摄 暂停/恢复
        .overlay(alignment: .bottomTrailing) {
            autoShutterButton
                .padding(.trailing, CGFloat(28 + 72 + 16))
                .padding(.bottom, CGFloat(24 + 13))
        }
    }

    /// 竖屏控制区：压到 2 行 —— 第 1 行滤镜，第 2 行变焦 + 意图 + 效果前预览。
    private var controlStrip: some View {
        VStack(spacing: 6) {
            filterRow
            zoomAndIntentRow
        }
        .layoutPriority(1)
    }

    // MARK: - 导演信息条（移到取景框外，永不压住人脸）

    private var directorSubjectText: String {
        if analyzer.directorObservation.personCount > 0 {
            return "人物 ×\(analyzer.directorObservation.personCount)"
        }
        return analyzer.subject.rect == .zero ? "未锁定主体" : "已锁定主体"
    }

    private var directorCompositionText: String {
        let framing = analyzer.directorDecision.evidence.first(where: { $0.domain == "构图" })?.action ?? ""
        let cameraMove = analyzer.directorDecision.evidence.first(where: { $0.domain == "机位" })?.action ?? ""
        let joined = [framing, cameraMove].filter { !$0.isEmpty }.joined(separator: " · ")
        return joined.isEmpty ? analyzer.framingHint : joined
    }

    private var directorCurrentText: String {
        let zoom = String(format: "%.2f×", Double(camera.zoom))
        let stability = motion.isStable ? "稳定" : "请稳"
        return zoom + " · " + camera.exposureText + " · " + stability
    }

    private var directorGuidanceLine: String {
        let guidance = guidanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !guidance.isEmpty { return guidance }
        let instruction = analyzer.directorInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return instruction.isEmpty ? "等待导演分析" : instruction
    }

    private var directorStrip: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if !quietDirector {
                    Text(directorSubjectText).lineLimit(1)
                    Text(directorCompositionText).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(directorCurrentText)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .font(.caption2)
            if !quietDirector {
                Text(directorGuidanceLine)
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("导演提示")
    }

    // MARK: - 变焦：快捷胶囊常驻，连续滑杆收进弹层

    /// 变焦快捷胶囊：竖屏第 2 行与横屏右下浮层共用。
    private var zoomChips: some View {
        HStack(spacing: 6) {
            ForEach(camera.availableZooms.filter { $0 <= max(2, camera.nativeMaximumZoom) }, id: \.self) { value in
                Button {
                    autoZoom = false
                    lastManualZoom = Date()
                    manualZoomText = String(format: "%.2f", Double(value))
                    camera.setZoom(value)
                } label: {
                    Text(String(format: "%g×", Double(value)))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minWidth: 40, minHeight: 32)
                        .background(abs(camera.zoom - value) < 0.08 ? Color.white.opacity(0.24) : Color.clear,
                                    in: Capsule())
                }
                .accessibilityLabel(String(format: "变焦 %g 倍", Double(value)))
            }
        }
        .foregroundStyle(.white)
    }

    /// 当前倍率按钮：点开连续变焦 sheet。
    private var currentZoomButton: some View {
        Button { showZoomControl = true } label: {
            Text(String(format: "%.2f×", Double(camera.zoom)))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(minWidth: 54, minHeight: 32)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .accessibilityLabel("展开连续变焦")
        .disabled(camera.maximumZoom <= camera.minimumZoom)
    }

    private var zoomSliderBinding: Binding<Double> {
        Binding(
            get: {
                let low = Double(camera.minimumZoom)
                let high = max(low, Double(camera.maximumZoom))
                let current = Double(sliderZoom ?? Double(camera.zoom))
                return log(max(max(requestedZoomRange.lowerBound, low), min(high, current)))
            },
            set: { value in
                let target = roundedZoom(exp(value))
                sliderZoom = target
                applyManualZoom(target, reportLimit: false)
            }
        )
    }

    private func roundedZoom(_ value: Double) -> Double {
        let limited = min(requestedZoomRange.upperBound,
                          max(requestedZoomRange.lowerBound, value))
        return (limited * 10).rounded() / 10   // 0.1 步进
    }

    /// Public UI range is 0.10×...100.00× with 0.01× precision. AVCapture can
    /// only render the active device's real range, so unsupported endpoints are
    /// clamped and reported instead of pretending that the image reached them.
    private func applyManualZoom(_ requested: Double, reportLimit: Bool) {
        guard requested.isFinite else { return }
        let normalized = roundedZoom(requested)
        // 先按 UI 公开区间夹，再交给设备夹取；避免相机边界退化时把用户输入夹回 1.0。
        let low = requestedZoomRange.lowerBound
        let high = requestedZoomRange.upperBound
        let target = min(high, max(low, normalized))
        autoZoom = false
        lastManualZoom = Date()
        manualZoomText = String(format: "%.2f", target)
        camera.setZoom(CGFloat(target))
        if reportLimit, abs(target - normalized) >= 0.005 {
            showToast(String(format: "本机支持 %.2f×–%.2f×，已调整为 %.2f×", low, high, target))
        }
    }

    private func nudgeManualZoom(by amount: Double) {
        let base = Double(manualZoomText) ?? Double(camera.zoom)
        applyManualZoom(base + amount, reportLimit: true)
    }

    private func applyManualZoomText() {
        guard let entered = Double(manualZoomText), entered.isFinite else { return }
        applyManualZoom(entered, reportLimit: true)
    }

    /// 连续变焦弹层：对数滑杆、上下限、手动倍率输入、恢复自动，全在弹层里，永不覆盖滤镜。
    private var zoomSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("连续变焦", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f×", Double(camera.zoom)))
                    .font(.subheadline.monospacedDigit())
                Button("完成") { showZoomControl = false }.font(.subheadline)
            }
            Picker("变焦模式", selection: $autoZoom) {
                Text("手动").tag(false)
                Text("自动").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: autoZoom) { _, enabled in
                if enabled { lastManualZoom = .distantPast; directorController.reset() }
                else { lastManualZoom = Date(); manualZoomText = String(format: "%.2f", Double(camera.zoom)) }
            }
            if min(requestedZoomRange.upperBound, Double(camera.maximumZoom))
                > max(requestedZoomRange.lowerBound, Double(camera.minimumZoom)) {
                let lowZoom = max(requestedZoomRange.lowerBound, Double(camera.minimumZoom))
                let highZoom = min(requestedZoomRange.upperBound, Double(camera.maximumZoom))
                HStack(spacing: 10) {
                    Text(String(format: "%.2f×", Double(camera.minimumZoom))).font(.caption2)
                    Slider(value: zoomSliderBinding,
                           in: log(max(requestedZoomRange.lowerBound, lowZoom))...log(highZoom),
                           onEditingChanged: { editing in if !editing { sliderZoom = nil } })
                        .accessibilityLabel("连续变焦")
                        .accessibilityValue(String(format: "%.2f倍", Double(camera.zoom)))
                    Text(String(format: "%.2f×", Double(camera.maximumZoom))).font(.caption2)
                }
                HStack(spacing: 10) {
                    Text("倍率").font(.caption)
                    TextField("0.10–100.00", text: $manualZoomText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .accessibilityLabel("输入手动变焦倍率，精确到0.01倍")
                    Button("应用") { applyManualZoomText() }.buttonStyle(.bordered)
                }
                Text(String(format: "可输入 0.10×–100.00×，精度 0.01×；本机实际支持 %.2f×–%.2f×。",
                            Double(camera.minimumZoom), min(100, Double(camera.maximumZoom))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前镜头不支持连续变焦，请用上面的快捷倍率。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("恢复自动变焦") {
                    autoZoom = true
                    lastManualZoom = .distantPast
                    directorController.reset()
                }.buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .presentationDetents([.height(310)])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
    }

    /// Keep the camera surface separate from lifecycle modifiers. This avoids
    /// a single SwiftUI expression growing beyond the compiler's inference
    /// budget as controls are added to the capture screen.
    private var captureSurface: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                Group {
                    if CaptureLayout.isLandscape(geo.size) { landscapeLayout(geo) } else { portraitLayout(geo) }
                }
                .onChange(of: CaptureLayout.isLandscape(geo.size), initial: true) { _, value in
                    if uiIsLandscape != value { uiIsLandscape = value }
                }
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                }
                .transition(.opacity)
            }

            if camera.authorizationDenied {
                PermissionHint(title: "需要相机权限",
                               message: "请在系统设置中允许「户外拍照助手」使用相机。",
                               actionTitle: "打开设置") {
                    self.openAppSettings()
                }
            } else if let error = camera.errorMessage {
                VStack {
                    Text(error)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.75))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.top, 90)
            }
        }
    }

    private var capturePresented: some View {
        captureSurface
        .sheet(isPresented: $showZoomControl) { zoomSheet }
        .sheet(isPresented: $showingEffects) { effectsPanel }
        .onChange(of: allowsRotation, initial: true) { _, allowed in
            _ = allowed
            OrientationPolicy.apply(.allButUpsideDown)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(isPresentedModally: true).preferredColorScheme(.light)
        }
    }

    private var captureLifecycle: some View {
        capturePresented
        .onAppear {
            guard self.isSelected else { return }
            OrientationPolicy.apply(.allButUpsideDown)
            self.camera.setDepthDelivery(self.portraitDepth)
            self.camera.setHighQualityMode(self.highQuality)
            self.camera.start()
            self.motion.start()
            self.location.start()
            self.analyzer.setPeriod(self.location.periodText)
            self.syncMirrorSettings()
        }
        .onDisappear {
            OrientationPolicy.apply(.portrait)
            comparingOriginal = false
            self.camera.stop()
            self.motion.stop()
            self.location.stop()
            self.toastTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && self.isSelected && !self.showingSettings && !self.showReview {
                self.camera.start()
                self.motion.start()
                self.location.start()
            } else {
                self.camera.stop()
                self.motion.stop()
                self.location.stop()
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected && self.scenePhase == .active && !self.showingSettings && !self.showReview {
                self.camera.start()
                self.motion.start()
                self.location.start()
            } else {
                self.camera.stop()
                self.motion.stop()
                self.location.stop()
            }
        }
        .onChange(of: showReview) { _, showing in
            if showing {
                camera.stop()
            } else if isSelected && scenePhase == .active && !showingSettings { camera.start() }
        }
        .onChange(of: showingSettings) { _, showing in
            if showing {
                camera.stop()
            } else if isSelected && scenePhase == .active { camera.start() }
        }
    }

    var body: some View {
        captureLifecycle
        .onChange(of: camera.photoToken) { _, _ in
            self.processLatestPhoto()
        }
        .onChange(of: analyzer.observationTick) { _, _ in
            refreshDirector(); attemptAutoCapture()
            if Date().timeIntervalSince(lastGuidanceAt) > 1 {
                guidanceText = waitingReason
                lastGuidanceAt = Date()
            }
        }
        .onChange(of: analyzer.autoCaptureReady) { _, ready in
            if ready && quietDirector { UISelectionFeedbackGenerator().selectionChanged() }
        }
        .onChange(of: autoDirector) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: directorFraming) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: directorComposition) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: autoZoom) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: analyzer.autoCaptureReady) { _, ready in
            if !ready {
                self.autoCaptureArmed = true
                self.readySince = nil
            }
        }
        .onChange(of: location.periodText) { _, period in
            self.analyzer.setPeriod(period)
        }
        .onChange(of: autoCapture) { _, enabled in
            if !enabled {
                self.autoCaptureArmed = true
            } else if self.analyzer.autoCaptureReady {
                self.attemptAutoCapture()
            }
        }
        .onChange(of: portraitDepth) { _, enabled in camera.setDepthDelivery(enabled) }
        .onChange(of: mirrorFrontCamera) { _, _ in syncMirrorSettings() }
        .onChange(of: camera.cameraPosition) { _, _ in
            sliderZoom = nil
            pinchStartZoom = nil
            directorController.reset()
            targetSelected = false; analyzer.selectSubject(at: nil); camera.setFocusExposureLock(false)
            analyzer.directorObservation = DirectorObservation()
            syncMirrorSettings()
        }
        .onChange(of: highQuality) { _, value in
            self.camera.setHighQualityMode(value)
        }
        .onChange(of: library.lastSaveError) { _, error in
            if let error {
                self.showToast("保存失败：\(error)")
            }
        }
        .sheet(isPresented: $showReview) {
            if let shot = self.reviewShot, let styled = self.reviewStyled {
                ReviewView(shot: shot,
                           styledImage: styled,
                           renderOptions: self.reviewOptions,
                           analyzer: self.analyzer,
                           motion: self.motion,
                           scene: self.effectiveScene,
                           isSessionBest: self.reviewIsBest)
                    .environmentObject(self.library)
            }
        }
    }

    private var waitingReason: String {
        if targetSelected && analyzer.subject.rect == .zero { return "选中主体已离开，请重新点击或恢复自动" }
        if analyzer.brightness < 0.16 { return "光线不足，请靠近光源或稳住手机" }
        if camera.zoom > camera.nativeMaximumZoom * 1.5 { return "高倍率细节可能下降，可拉近拍摄距离或手动降低倍率" }
        if !camera.controlsSettled { return "正在对焦、测光或变焦，请稍候" }
        if autoPaused { return "自动拍摄已暂停，可手动拍照" }
        if analyzer.directorObservation.personCount > 0 && analyzer.visionEvidence.eyes == "unknown" { return "眼部无法确认，可调整角度或手动拍摄" }
        if analyzer.visionEvidence.eyes == "closed" { return "疑似闭眼，等待合适时机" }
        if !motion.isStable { return "请稳住手机" }
        return analyzer.directorInstruction
    }
    private var effectsPanel: some View {
        NavigationStack {
            Form {
                Section("滤镜 · 点击实时预览") {
                    Toggle("自动匹配", isOn: $autoFilter)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(FilterGroup.allCases) { group in
                                Button { filterGroup = group } label: {
                                    Text(group.rawValue)
                                        .font(.subheadline.weight(filterGroup == group ? .semibold : .regular))
                                        .foregroundStyle(filterGroup == group ? .white : .secondary)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(filterGroup == group ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 2)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(PhotoFilter.filters(in: filterGroup)) { filter in
                                Button { autoFilter = false; manualFilterName = filter.rawValue } label: {
                                    VStack {
                                        if let image = filterThumbnails[filter] {
                                            Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                        } else {
                                            RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)).frame(width: 64, height: 80).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                                        }
                                        Text(filter.rawValue).font(.caption)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .task(id: filterGroup) { await refreshThumbnails() }
                    Slider(value: $filterStrength, in: 0...1) { Text("滤镜强度") }
                }
                Section("人像") {
                    Toggle("实时美颜", isOn: $liveBeauty)
                    if liveBeauty {
                        Picker("模式", selection: $liveBeautyModeRaw) {
                            ForEach(PortraitBeautyMode.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                        }.pickerStyle(.segmented).frame(width: 140)
                        let ceiling = liveBeautyMode == .advanced ? 1.0 : 0.30
                        Slider(value: $liveBeautyStrength, in: 0...ceiling) { Text("美颜度") }
                        Text("单一美颜度控制磨皮、美白、提亮、瘦脸等全部参数。自然模式封顶30%。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("单人突出主体轻虚化", isOn: $directorBlur)
                    Slider(value: $directorBlurStrength, in: 0...0.65) { Text("虚化强度") }
                }
                Section {
                    Text("按住下方按钮看效果前预览；松开恢复。这里不是RAW。")
                    Text("自动拍摄暂时暂停，关闭面板后可用快门旁按钮恢复。")
                }
            }.navigationTitle("拍摄效果")
                .toolbar { Button("完成") { showingEffects = false } }
                .onAppear { filterThumbnails.removeAll() }
        }
        .presentationDetents([.medium, .large])
    }
    private func refreshThumbnails() async {
        thumbnailTask?.cancel()
        let base = camera.previewThumbnail
        guard let cg = base?.cgImage else { return }
        let group = filterGroup
        let filters = PhotoFilter.filters(in: group)
        let cached = filterThumbnails
        let toGenerate = filters.filter { cached[$0] == nil }
        guard !toGenerate.isEmpty else { return }
        let input = CIImage(cgImage: cg)
        let scale = min(1, 120 / max(input.extent.width, input.extent.height))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let result = await Task.detached(priority: .userInitiated) {
            var generated: [PhotoFilter: UIImage] = [:]
            for filter in toGenerate {
                if Task.isCancelled { break }
                let output = PhotoFilterEngine.apply(filter, to: small)
                if let cgOut = ImagePipeline.context.createCGImage(output, from: output.extent) {
                    generated[filter] = UIImage(cgImage: cgOut)
                }
            }
            return generated
        }.value
        if !Task.isCancelled { filterThumbnails.merge(result) { _, new in new } }
    }

    // MARK: - 快门：竖屏内嵌取景框，横屏右下浮层

    /// 最近照片缩略图：竖屏快门条与横屏左下浮层共用。
    private var galleryThumb: some View {
        Button { openGallery() } label: {
            if let image = reviewStyled {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                Image(systemName: "photo").font(.system(size: 20)).frame(width: 46, height: 46)
            }
        }
        .accessibilityLabel("最近照片与图库")
    }

    /// White shutter with a fixed outer diameter. The portrait version is 58pt
    /// and sits inside the viewfinder; landscape keeps a slightly larger 64pt.
    private func shutterButton(diameter: CGFloat) -> some View {
        let outer = max(44, diameter)
        let inner = max(34, outer - 10)
        return Button { takePhoto() } label: {
            ZStack {
                Circle().fill(.black.opacity(0.22)).frame(width: outer + 4, height: outer + 4)
                Circle().stroke(.white, lineWidth: 3).frame(width: outer, height: outer)
                Circle().fill(.white).frame(width: inner, height: inner)
                if activeRenders > 0 { ProgressView().tint(.black) }
            }
        }
        .accessibilityLabel("拍照")
        .disabled(!camera.isRunning || activeRenders > 0)
    }

    private var shutterButton: some View {
        shutterButton(diameter: CaptureLayout.landscapeShutterDiameter)
    }

    /// 自动拍摄 暂停/恢复。
    private var autoShutterButton: some View {
        Button { toggleAutoShutter() } label: {
            Image(systemName: autoPaused || !autoCapture ? "play.circle" : "pause.circle")
                .font(.system(size: 28)).frame(width: 46, height: 46)
        }
        .accessibilityLabel(autoPaused ? "恢复自动拍摄" : "暂停自动拍摄")
    }

    /// Portrait controls float inside the bottom edge of the camera image. This
    /// removes the old full-width shutter bar that covered filters and zoom.
    private var portraitViewfinderControls: some View {
        HStack {
            galleryThumb
            Spacer(minLength: 0)
            shutterButton(diameter: CaptureLayout.portraitShutterDiameter)
            Spacer(minLength: 0)
            autoShutterButton
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(.black.opacity(0.18), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
    }

    private func openGallery() {
        if let shot = reviewShot, reviewStyled != nil {
            reviewShot = shot
            showReview = true
        } else {
            onNavigate(1)
        }
    }

    private func toggleAutoShutter() {
        if !autoCapture {
            autoCapture = true
            autoPaused = false
        } else {
            autoPaused.toggle()
        }
        readySince = nil
    }

    /// 镜像只对前置生效：后置永远按真实方向预览与拍摄。
    private func syncMirrorSettings() {
        let enabled = mirrorFrontCamera && camera.cameraPosition == .front
        camera.setPreviewMirror(enabled)
        camera.setCaptureMirror(enabled)
    }


    // MARK: - 拍照结果处理（全部在后台渲染）

    private func processLatestPhoto() {
        guard camera.photoToken != lastToken else { return }
        lastToken = camera.photoToken
        guard let shot = camera.latestPhoto else { return }

        self.activeRenders += 1

        var options = captureOptions ?? currentRenderOptions()
        captureOptions = nil
        // The actual EXIF-aware photo orientation wins over any UI frame that
        // was still rotating at shutter time.  This prevents a 4:3 landscape
        // original from being rendered as a portrait crop.
        let capturedAspect = Double(shot.displayAspect)
        if capturedAspect.isFinite, capturedAspect > 0 {
            options.outputAspect = min(2, max(0.5, capturedAspect))
        }
        let exposure = analyzer.qualityExposure
        let composition = analyzer.compositionScore
        let sharpness = analyzer.qualitySharpness
        let keepsOriginal = saveBoth
        let depthStrength = min(1, max(0, directorBlurStrength))
        let useMatteDepth = shot.depthMask != nil && options.directorEvidence.contains { $0.domain == "自动景深" }
        if useMatteDepth { options.backgroundBlur = 0 }

        enqueueRender(PendingRender(shot: shot, options: options,
                                    useMatteDepth: useMatteDepth, depthStrength: depthStrength,
                                    exposure: exposure, composition: composition,
                                    sharpness: sharpness, keepsOriginal: keepsOriginal))
    }

    private struct PendingRender {
        let shot: CapturedPhoto
        let options: PhotoRenderOptions
        let useMatteDepth: Bool
        let depthStrength: CGFloat
        let exposure: Int
        let composition: Int
        let sharpness: Int
        let keepsOriginal: Bool
        var score: Int {
            Int((Double(composition) * 0.45 + Double(exposure) * 0.25 + Double(sharpness) * 0.30).rounded())
        }
    }

    private func enqueueRender(_ task: PendingRender) {
        let completion: (UIImage?) -> Void = { [self, task] styled in
            completeRender(shot: task.shot, styled: styled, score: task.score,
                           options: task.options, keepsOriginal: task.keepsOriginal)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let styled = Self.render(task: task)
            DispatchQueue.main.async { completion(styled) }
        }
    }

    private func completeRender(shot: CapturedPhoto, styled: UIImage?, score: Int,
                                options: PhotoRenderOptions, keepsOriginal: Bool) {
        activeRenders = max(0, activeRenders - 1)
        guard let styled else { showToast("图像处理失败"); return }
        finish(shot: shot, styled: styled, score: score, options: options, keepsOriginal: keepsOriginal)
    }

    private static func render(task: PendingRender) -> UIImage? {
        guard let rendered = PhotoPostProcessor.render(original: task.shot.image, options: task.options) else { return nil }
        guard task.useMatteDepth else { return rendered }
        return DepthPortraitProcessor.apply(image: rendered, mask: task.shot.depthMask, strength: task.depthStrength)
    }

    private func finish(shot: CapturedPhoto,
                        styled: UIImage,
                        score: Int,
                        options: PhotoRenderOptions,
                        keepsOriginal: Bool) {
        let metrics = shotMetrics ?? (analyzer.qualityExposure, analyzer.qualitySharpness, analyzer.compositionScore)
        UserDefaults.standard.set(metrics.0, forKey: "lastShotExposure")
        UserDefaults.standard.set(metrics.1, forKey: "lastShotSharpness")
        UserDefaults.standard.set(metrics.2, forKey: "lastShotComposition")
        UserDefaults.standard.set(Date().formatted(date: .abbreviated, time: .shortened), forKey: "lastShotDate")
        let isBest = score >= bestScore
        if isBest { self.bestScore = score }

        self.library.saveShot(originalData: shot.originalData,
                              styledImage: styled,
                              keepOriginal: keepsOriginal, photoID: shot.id) { success in
            if success {
                self.showToast(shot.isLandscape ? "横拍 4:3 已保存到图库" : "竖拍 3:4 已保存到图库")
            } else {
                self.showToast("保存失败：\(self.library.lastSaveError ?? "未知错误")")
            }
        }

        self.reviewShot = shot
        self.reviewStyled = styled
        self.reviewOptions = options
        self.reviewIsBest = isBest

        // 诊断包记录点：最近一次拍摄的质检指标、导演建议与降采样后的原片/成片。
        DiagnosticsCenter.shared.recordShot(ShotDiagnostics(recordedAt: Date(),
                                                           exposure: metrics.0,
                                                           sharpness: metrics.1,
                                                           composition: metrics.2,
                                                           score: score,
                                                           scene: effectiveScene,
                                                           filter: effectiveFilter.rawValue,
                                                           zoom: Double(camera.zoom),
                                                           cameraTelemetry: camera.exposureText,
                                                           directorSummary: analyzer.directorInstruction,
                                                           directorEvidence: analyzer.directorDecision.evidence.map { "\($0.domain)|\($0.rule)|\($0.observation)|\($0.action)" },
                                                           appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-",
                                                           buildNumber: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-"),
                                                originalJPEG: shot.originalData,
                                                styledImage: styled)
    }

    private func showToast(_ message: String) {
        self.toast = message
        self.toastTask?.cancel()
        self.toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: - 自动取景 / 自动拍摄

    private func currentRenderOptions() -> PhotoRenderOptions {
        PhotoRenderOptions(filter: effectiveFilter, grade: effectiveGrade,
                           style: compositionStyle, beauty: liveBeauty ? BeautyPreset(intensity: liveBeautyStrength).settings(mode: liveBeautyMode) : nil,
                           outputAspect: Double(activeCaptureAspect),
                           filterStrength: autoDirector && autoFilter ? min(filterStrength, analyzer.directorDecision.maximumFilterStrength) : filterStrength,
                           backgroundBlur: directorBlur && autoDirector && analyzer.directorObservation.personCount == 1 && ["半身", "特写", "突出主体"].contains(directorFraming) ? directorBlurStrength : 0,
                           directorContext: autoDirector ? analyzer.directorDecision.context : nil,
                           directorEvidence: autoDirector ? analyzer.directorDecision.evidence : [])
    }

    private func takePhoto() {
        guard !showingSettings, !showReview, camera.isRunning, activeRenders == 0 else { return }
        shotMetrics = (analyzer.qualityExposure, analyzer.qualitySharpness, analyzer.compositionScore)
        var options = currentRenderOptions()
        if autoDirector && portraitDepth && analyzer.directorObservation.personCount == 1 && ["半身", "特写", "突出主体"].contains(directorFraming) {
            options.directorEvidence.append(DirectorEvidence(domain: "自动景深", rule: "单人突出主体", observation: "请求轻度背景分离", action: "仅当成片存在人物遮罩时轻度虚化；缺少遮罩时保留原景"))
        }
        options.directorEvidence.append(DirectorEvidence(domain: "设备执行", rule: "实际控制状态", observation: camera.exposureText + String(format: " · %.2f×", Double(camera.zoom)), action: camera.controlsSettled ? "系统对焦、曝光与变焦已稳定" : "本次为手动快门或控制尚未稳定"))
        options.directorEvidence.append(DirectorEvidence(domain: "画幅方向", rule: "照片随设备方向输出", observation: camera.orientationLabel, action: camera.isLandscapeCapture ? "保存横向 4:3 成片（宽大于高）" : "保存竖向 3:4 成片（高大于宽）"))
        captureOptions = options
        camera.capture()
    }

    private func refreshDirector() {
        guard isSelected, scenePhase == .active, camera.isRunning, !showingSettings, !showReview else { return }
        camera.applyMotionExposure(enabled: autoDirector && directorFraming == "运动")
        guard autoDirector else {
            camera.applyExposureCompensation(brightness: analyzer.brightness)
            return
        }
        let box = analyzer.subject.rect
        let now = Date()
        let intersection = box.intersection(trackedBox)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = box.width * box.height + trackedBox.width * trackedBox.height - intersectionArea
        if box == .zero || now.timeIntervalSince(trackingUpdatedAt) > 0.8 || intersectionArea / max(0.00001, unionArea) < 0.35 {
            trackingSince = box == .zero ? nil : now
            readySince = nil
        }
        let dt = now.timeIntervalSince(trackingUpdatedAt)
        subjectSpeed = dt > 0.05 && dt < 0.8 && trackedBox != .zero ? Double(hypot(box.midX - trackedBox.midX, box.midY - trackedBox.midY)) / dt : 0
        trackedBox = box; trackingUpdatedAt = now
        let observation = analyzer.directorObservation
        var input = DirectorInput(observation: observation, scene: effectiveScene,
                                  sceneConfidence: autoScene ? analyzer.sceneConfidence : 1,
                                  zoom: Double(camera.zoom), minimumZoom: Double(camera.minimumZoom),
                                  maximumZoom: Double(camera.maximumZoom), nativeMaximumZoom: Double(camera.nativeMaximumZoom),
                                  stable: motion.isStable, framing: directorFraming,
                                  composition: directorComposition, preference: nil)
        input.preference = directorLearning ? DirectorPreferenceStore.shared.preference(for: DirectorEngine.context(input)) : nil
        let manualHold = lastManualZoom != .distantPast
        if Date().timeIntervalSince(zoomRequestedAt) > 2 && Date().timeIntervalSince(zoomRequestedAt) < 3 && abs(Double(camera.zoom) - zoomStart) < 0.02 {
            zoomPausedUntil = Date().addingTimeInterval(8)
        }
        let allow = autoZoom && autoComposition && !manualHold && activeRenders == 0 && Date() > zoomPausedUntil
        let decision = directorController.evaluate(input, now: Date.timeIntervalSinceReferenceDate, allowAutomaticZoom: allow)
        analyzer.directorDecision = decision
        analyzer.recommendedZoom = decision.targetZoom
        analyzer.directorTitle = "AI导演 · 摄影知识决策"
        analyzer.directorInstruction = decision.summary
        analyzer.framingHint = decision.evidence.first(where: { $0.domain == "构图" })?.action ?? "等待可靠主体"
        camera.applyExposureCompensation(brightness: observation.brightness, directorBias: Float(decision.exposureBias))
        if decision.shouldZoom {
            zoomRequestedAt = Date(); zoomStart = Double(camera.zoom)
            camera.setZoom(CGFloat(decision.targetZoom))
        }
        if Date() < zoomPausedUntil { analyzer.directorInstruction = "镜头未响应变焦，已暂停重试；请移动机位或手动选倍率" }
        else if Date().timeIntervalSince(analyzer.visionEvidenceAt) < 0.8 {
            if analyzer.visionEvidence.eyes == "closed" { analyzer.directorInstruction = "检测到可能闭眼，等待睁眼后再拍" }
            else if !analyzer.visionEvidence.poseHint.isEmpty { analyzer.directorInstruction = analyzer.visionEvidence.poseHint }
        }
        // Every new observation revalidates the whole shutter gate. There is no
        // fixed delay: the first frame where composition, zoom, exposure,
        // sharpness and motion are simultaneously ready fires immediately.
        if analyzer.autoCaptureReady { attemptAutoCapture() }
    }

    private func attemptAutoCapture() {
        guard !showingSettings, !showReview, isSelected, scenePhase == .active,
              autoCapture, !autoPaused, !showingEffects, !comparingOriginal, autoCaptureArmed, analyzer.autoCaptureReady,
              pinchStartZoom == nil, sliderZoom == nil else { return }
        guard
              Date().timeIntervalSince(trackingUpdatedAt) < 0.8,
              Date().timeIntervalSince(trackingSince ?? Date()) > 1,
              camera.controlsSettled,
              Date().timeIntervalSince(camera.controlsUpdatedAt) < 0.8 else { readySince = nil; return }
        let manualHold = lastManualZoom != .distantPast
        let zoomRatio = max(0.01, analyzer.directorDecision.targetZoom) / max(0.01, Double(camera.zoom))
        let zoomSettled = manualHold || !autoDirector || !autoZoom || abs(log(zoomRatio)) < 0.05
        guard zoomSettled, !analyzer.directorDecision.shouldZoom, analyzer.autoCaptureHeld else { readySince = nil; return }

        let hasPeople = analyzer.directorObservation.personCount > 0
        if hasPeople {
            guard Date().timeIntervalSince(analyzer.visionEvidenceAt) < 0.8,
                  analyzer.visionEvidence.eyes == "open" else { readySince = nil; return }
        }
        let motionExposure = directorFraming == "运动" ? 1.0 / 500 : 1.0 / 125
        guard camera.exposureSeconds <= motionExposure,
              subjectSpeed * camera.exposureSeconds < 0.0015 else { readySince = nil; return }
        let shutter = SmartShutterEngine.decide(stability: motion.stabilityScore,
                                                 isStable: motion.isStable,
                                                 exposureScore: analyzer.qualityExposure,
                                                 sharpnessScore: analyzer.qualitySharpness)
        guard shutter.action == .shootNow, motion.isStable,
              analyzer.subject.rect != .zero else { readySince = nil; return }
        let box = analyzer.subject.rect
        if directorFraming != "运动" && (abs(box.midX - readyBox.midX) > 0.04 || abs(box.midY - readyBox.midY) > 0.04 || abs(box.height - readyBox.height) > 0.05) {
            readySince = nil
        }
        if readySince == nil { readySince = Date(); readyBox = box }
        // Continuous valid observations, not a scheduled shutter or countdown.
        guard Date().timeIntervalSince(readySince ?? Date()) >= (directorFraming == "运动" ? 0.4 : 1.5) else { return }
        readySince = nil

        autoCaptureArmed = false
        takePhoto()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 子视图

private struct PermissionHint: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(title).font(.headline)
            Text(message).font(.footnote).multilineTextAlignment(.center)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(32)
    }
}
