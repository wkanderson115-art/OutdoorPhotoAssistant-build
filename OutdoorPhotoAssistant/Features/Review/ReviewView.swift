import SwiftUI
import UIKit
import CoreImage

struct ReviewView: View {
    let shot: CapturedPhoto
    let styledImage: UIImage
    let renderOptions: PhotoRenderOptions
    @ObservedObject var analyzer: FrameAnalyzer
    @ObservedObject var motion: MotionService
    let scene: String
    let isSessionBest: Bool

    @EnvironmentObject private var library: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    @AppStorage("directorLearning") private var directorLearning = true
    @State private var recordedFeedback = false
    @State private var showingOriginal = false
    @State private var beautyEnabled = true
    @State private var beautyMode: PortraitBeautyMode = .natural
    @State private var skin = 0.10
    @State private var faceDepth = 0.0
    @State private var faceSlim = 0.0
    @State private var eyeLift = 0.04
    @State private var eyeEnlarge = 0.0
    @State private var noseStraighten = 0.0
    @State private var lipEnhance = 0.0
    @State private var skinWhiten = 0.0
    @State private var faceBrighten = 0.0
    @State private var environmentBlend = 0.16
    @State private var eyeshadow = 0.0
    @State private var eyeliner = 0.0
    @State private var doubleEyelid = 0.0

    @State private var preview: UIImage?
    @State private var renderVersion = 0
    @State private var saving = false
    @State private var rendering = false
    @State private var renderTask: Task<Void, Never>?
    @State private var status: String?

    @State private var aesthetics: Double?
    @State private var composition = 0
    @State private var photoHorizon = 0.0
    @State private var photoSubject = SubjectInfo()
    @State private var selectedFilter: PhotoFilter = .natural
    @State private var filterStrength = 0.55
    @State private var blurStrength = 0.0
    @State private var curveShadow = 0.0
    @State private var curveMid = 0.0
    @State private var curveHighlight = 0.0
    @State private var inspection = "验片分析中"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("先看画面，再决定如何调整")
                        .font(.subheadline).foregroundStyle(AppTheme.muted)
                    previewSection
                    Text(inspection).font(.subheadline).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 16))
                    filterControls
                    curveControls
                    metrics
                    directorReview
                    DisclosureGroup("人像与景深调整") {
                        VStack(spacing: 12) {
                            if shot.depthMask != nil { depthSection }
                            beautyControls
                        }
                    }
                    .padding(16)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18))
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(AppTheme.muted)
                    }
                }
                .padding(16)
                .foregroundStyle(AppTheme.ink)
            }
            .background(AppTheme.paper)
            .navigationTitle("照片复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("原片") {
                        self.rendering = false
                        self.showingOriginal = true
                        self.renderTask?.cancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "保存中…" : "保存成片") {
                        self.save()
                    }
                    .disabled(saving || rendering)
                }
            }
            .toolbarBackground(AppTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .task {
                self.selectedFilter = self.renderOptions.filter
                self.filterStrength = self.renderOptions.filterStrength
                if let b = self.renderOptions.beauty {
                    self.beautyMode = b.mode; self.skin = b.skin; self.skinWhiten = b.skinWhiten
                    self.faceBrighten = b.faceBrighten; self.eyeLift = b.eyeLift
                    self.environmentBlend = b.environmentBlend; self.faceSlim = b.faceSlim
                    self.faceDepth = b.faceDepth; self.eyeEnlarge = b.eyeEnlarge
                    self.noseStraighten = b.noseStraighten; self.lipEnhance = b.lipEnhance
                    self.eyeshadow = b.eyeshadow; self.eyeliner = b.eyeliner; self.doubleEyelid = b.doubleEyelid
                }
                let image = self.styledImage
                let original = self.shot.image
                DispatchQueue.global(qos: .utility).async {
                    if let cg = original.cgImage {
                        let ci = CIImage(cgImage: cg).oriented(PhotoPostProcessor.exifOrientation(original.imageOrientation))
                        let result = DirectorVision.inspectPhoto(ci)
                        DispatchQueue.main.async { self.inspection = result.notes.joined(separator: "；") }
                    }
                }
                self.analyzer.analyzePhoto(image) { aesthetic, score, horizon, subjectInfo in
                    DispatchQueue.main.async {
                        self.aesthetics = aesthetic
                        self.composition = score
                        self.photoHorizon = horizon
                        self.photoSubject = subjectInfo
                    }
                }
                self.scheduleRender()
            }
            .onDisappear {
                self.renderTask?.cancel()
            }
        }
        // Capture is intentionally dark. This sheet uses fixed light paper/card
        // colors, so it must not inherit the camera's white primary text.
        .preferredColorScheme(.light)
        .tint(AppTheme.actionGreen)
    }

    // MARK: - 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自然人像优化").font(.headline)
            Image(uiImage: showingOriginal ? shot.image : (preview ?? styledImage))
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topLeading) {
                    Label("小幅度调整，保留真实纹理", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(10)
                }
            Text("美肤、脸型、眼神与人景色彩融合都是小幅度调整，强度有上限。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var depthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自然背景虚化").font(.headline)
            slider("虚化强度", $blurStrength, 0...1)
            Text("默认保留真实场景；只在有人像遮罩时启用轻度背景模糊，不改变人物大小。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .onChange(of: blurStrength) { _, _ in self.scheduleRender() }
    }

    private var filterControls: some View {
        VStack(alignment: .leading) {
            Picker("滤镜", selection: $selectedFilter) {
                ForEach(PhotoFilter.allCases) { item in Text(item.rawValue).tag(item) }
            }
            slider("滤镜强度", $filterStrength, 0...1)
            Text("取景画面为原始预览，拍后显示滤镜成片。强度为零保留原始色彩。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .onChange(of: selectedFilter) { _, _ in self.scheduleRender() }
        .onChange(of: filterStrength) { _, _ in self.scheduleRender() }
    }

    private var curveControls: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("曲线调色").font(.headline)
                Spacer()
                Button("重置曲线") { curveShadow = 0; curveMid = 0; curveHighlight = 0 }
                    .font(.caption)
            }
            slider("阴影", $curveShadow, -0.35...0.35)
            slider("中间调", $curveMid, -0.35...0.35)
            slider("高光", $curveHighlight, -0.35...0.35)
            Text("正值为提亮，负值为压暗。电影风格自带轻微S曲线。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .onChange(of: curveShadow) { _, _ in self.scheduleRender() }
        .onChange(of: curveMid) { _, _ in self.scheduleRender() }
        .onChange(of: curveHighlight) { _, _ in self.scheduleRender() }
    }

    // MARK: - 指标

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("拍后复盘").font(.title2.bold())
                Spacer()
                Text(scene).foregroundStyle(.secondary)
            }
            if isSessionBest {
                Label("本次拍摄最佳", systemImage: "trophy.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
            }
            self.metric("AI 审美", aesthetics.map { String(format: "%.0f/100", ($0 + 1) * 50) } ?? "分析中")
            self.metric("构图", composition > 0 ? "\(composition)/100" : "分析中")
            self.metric("水平", abs(photoHorizon) < 0.05 ? "良好" : "建议校正")
            self.metric("稳定", motion.isStable ? "良好" : "拍摄时注意稳定")
            self.metric("主体", photoSubject.type == "未知" ? "未识别" : photoSubject.type)
            self.metric("景深", shot.depthMask == nil ? "未生成" : "已生成")
        }
        .padding()
    }

    private var directorReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导演复盘与偏好学习").font(.title3.bold())
            Text(composition == 0 ? "构图分析中；眼部、姿态及图像质量检查结果见上方。" : composition < 65 ? "构图估计偏低，请检查主体完整性、水平和边缘，必要时重拍。" : "构图估计可用；仍请放大检查眼睛、发丝和运动拖影。")
                .font(.subheadline)
            Text("复盘保留拍摄现场依据；评分是估计值，不等于照片一定合格。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(renderOptions.directorEvidence.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.domain + " · " + item.rule).font(.headline)
                    Text(item.observation).font(.caption).foregroundStyle(.secondary)
                    Text(item.action).font(.subheadline)
                }
            }
            if let context = renderOptions.directorContext {
                if recordedFeedback {
                    Label("本次反馈已保存在本机", systemImage: "checkmark.circle")
                    Button("撤销最近一次反馈") { DirectorPreferenceStore.shared.undoLastFeedback(); recordedFeedback = false }
                } else {
                    Button("喜欢这个效果，让导演记住") { learn(context, feedback: "喜欢效果") }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    HStack {
                        Button("主体太小") { learn(context, feedback: "主体太小") }
                        Button("主体太大") { learn(context, feedback: "主体太大") }
                    }.buttonStyle(.bordered)
                        .disabled(!context.automaticFraming || context.subjectFraction <= 0)
                }
                Text(directorLearning ? "反馈会调整同类场景的主体占比、滤镜及强度；至少3次相关反馈后采用偏好。" : "偏好学习已关闭，可在设置中开启。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("本次未使用导演决策，没有可学习的取景记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding().disabled(!directorLearning || rendering)
    }

    private func learn(_ context: DirectorLearningContext, feedback: String) {
        guard directorLearning, !recordedFeedback, !rendering else { return }
        DirectorPreferenceStore.shared.learn(context: context, filter: showingOriginal ? "自然" : selectedFilter.rawValue,
                                             strength: showingOriginal ? 0 : filterStrength, framingFeedback: feedback)
        recordedFeedback = true
    }

    // MARK: - 美颜控制

    private var beautyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("人像精修").font(.title3.bold())
                Spacer()
                Toggle("开启", isOn: $beautyEnabled).labelsHidden()
                    .onChange(of: beautyEnabled) { _, _ in self.scheduleRender() }
                Picker("模式", selection: $beautyMode) {
                    ForEach(PortraitBeautyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(width: 120)
                    .onChange(of: beautyMode) { _, mode in
                        if mode == .commercialNatural {
                            skin = 0.12; skinWhiten = 0; faceBrighten = 0.06
                            faceDepth = 0; faceSlim = 0; eyeLift = 0.03
                            eyeEnlarge = 0; noseStraighten = 0; lipEnhance = 0
                            eyeshadow = 0; eyeliner = 0; doubleEyelid = 0
                            self.scheduleRender()
                            return
                        }
                        let ceiling = mode == .advanced ? 1.0 : 0.30
                        skin = min(skin, ceiling); skinWhiten = min(skinWhiten, ceiling)
                        faceBrighten = min(faceBrighten, ceiling); faceDepth = min(faceDepth, ceiling)
                        faceSlim = min(faceSlim, ceiling); eyeLift = min(eyeLift, ceiling)
                        eyeEnlarge = min(eyeEnlarge, ceiling); noseStraighten = min(noseStraighten, ceiling)
                        lipEnhance = min(lipEnhance, ceiling); eyeshadow = min(eyeshadow, ceiling)
                        eyeliner = min(eyeliner, ceiling); doubleEyelid = min(doubleEyelid, ceiling)
                        self.scheduleRender()
                    }
            }
            // 上限按模式动态：自然封顶 0.30，进阶放开到 1.0
            let ceiling = beautyMode == .advanced ? 1.0 : 0.30
            Section("磨皮 · 肤色") {
                slider("自然美肤", $skin, 0...ceiling)
                slider("美白", $skinWhiten, 0...ceiling)
                slider("面部提亮", $faceBrighten, 0...ceiling)
            }
            Section("五官") {
                slider("眼神提亮", $eyeLift, 0...ceiling)
                slider("大眼", $eyeEnlarge, 0...ceiling)
                slider("挺鼻", $noseStraighten, 0...ceiling)
                slider("唇形", $lipEnhance, 0...ceiling)
            }
            Section("眼妆 · 仅作用于上眼睑") {
                slider("眼影", $eyeshadow, 0...ceiling)
                slider("眼线", $eyeliner, 0...ceiling)
                slider("双眼皮", $doubleEyelid, 0...ceiling)
            }
            Section("轮廓 · 色彩") {
                slider("面部立体", $faceDepth, 0...ceiling)
                slider("瘦脸", $faceSlim, 0...ceiling)
                slider("人景融合", $environmentBlend, 0...0.50)
            }

            Button("恢复自然默认") {
                self.beautyMode = .natural
                self.skin = 0.10
                self.skinWhiten = 0
                self.faceBrighten = 0
                self.eyeLift = 0.04
                self.eyeEnlarge = 0
                self.noseStraighten = 0
                self.lipEnhance = 0
                self.faceDepth = 0
                self.faceSlim = 0
                self.environmentBlend = 0.16
                self.eyeshadow = 0
                self.eyeliner = 0
                self.doubleEyelid = 0
                self.scheduleRender()
            }
            .buttonStyle(.bordered)

            Text("面部微调只在检测到人脸时生效。自然模式强度封顶 30%，保留纹理；进阶模式放开到 100%，由你自负其美。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onChange(of: skin) { _, _ in self.scheduleRender() }
        .onChange(of: skinWhiten) { _, _ in self.scheduleRender() }
        .onChange(of: faceBrighten) { _, _ in self.scheduleRender() }
        .onChange(of: faceDepth) { _, _ in self.scheduleRender() }
        .onChange(of: faceSlim) { _, _ in self.scheduleRender() }
        .onChange(of: eyeLift) { _, _ in self.scheduleRender() }
        .onChange(of: eyeEnlarge) { _, _ in self.scheduleRender() }
        .onChange(of: noseStraighten) { _, _ in self.scheduleRender() }
        .onChange(of: lipEnhance) { _, _ in self.scheduleRender() }
        .onChange(of: environmentBlend) { _, _ in self.scheduleRender() }
        .onChange(of: eyeshadow) { _, _ in self.scheduleRender() }
        .onChange(of: eyeliner) { _, _ in self.scheduleRender() }
        .onChange(of: doubleEyelid) { _, _ in self.scheduleRender() }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue * 100))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - 渲染与保存

    private func scheduleRender() {
        renderTask?.cancel()
        self.showingOriginal = false
        self.rendering = true
        var options = renderOptions
        options.filter = selectedFilter
        options.filterStrength = filterStrength
        // 只清场景调色，保留构图风格
        if selectedFilter != renderOptions.filter { options.grade = ColorGrade() }
        options.grade.curveShadow += curveShadow
        options.grade.curveMid += curveMid
        options.grade.curveHighlight += curveHighlight
        options.beauty = beautyEnabled ? PortraitBeautySettings(mode: beautyMode,
                                                skin: skin,
                                                clarity: 0.08,
                                                faceDepth: faceDepth,
                                                faceSlim: faceSlim,
                                                eyeLift: eyeLift,
                                                eyeEnlarge: eyeEnlarge,
                                                noseStraighten: noseStraighten,
                                                lipEnhance: lipEnhance,
                                                skinWhiten: skinWhiten,
                                                faceBrighten: faceBrighten,
                                                environmentBlend: environmentBlend,
                                                eyeshadow: eyeshadow,
                                                eyeliner: eyeliner,
                                                doubleEyelid: doubleEyelid) : nil
        let mask = shot.depthMask
        let blur = blurStrength
        let original = shot.image
        let fallback = styledImage
        renderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let rendered: UIImage? = await Task.detached(priority: .userInitiated) {
                let colored = PhotoPostProcessor.render(original: original, options: options)
                return colored.flatMap { DepthPortraitProcessor.apply(image: $0, mask: mask, strength: blur) }
            }.value
            guard !Task.isCancelled else { return }
            self.preview = rendered ?? fallback
            self.rendering = false
        }
    }

    private func save() {
        let output = preview ?? styledImage
        self.saving = true
        self.library.saveShot(originalData: shot.originalData,
                              styledImage: output,
                              keepOriginal: false, photoID: shot.id) { success in
            self.saving = false
            if success {
                self.status = "已保存成片到图库"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.dismiss()
                }
            } else {
                self.status = self.library.lastSaveError ?? "保存失败"
            }
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
