import SwiftUI

struct SettingsView: View {
    var isPresentedModally = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var analyzer: FrameAnalyzer
    @EnvironmentObject private var camera: CameraService
    @AppStorage("autoDirector") private var autoDirector = true
    @AppStorage("directorLearning") private var directorLearning = true
    @AppStorage("directorFraming") private var directorFraming = "自动"
    @AppStorage("directorComposition") private var directorComposition = "自动"
    @AppStorage("quietDirector") private var quietDirector = false
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("autoScene") private var autoScene = true
    @AppStorage("autoFilter") private var autoFilter = true
    @AppStorage("autoComposition") private var autoComposition = true
    @AppStorage("autoZoom") private var autoZoom = true
    @AppStorage("autoCapture") private var autoCapture = true
    @AppStorage("exportToSystemAlbum") private var exportToSystemAlbum = false
    @AppStorage("saveBoth") private var saveBoth = true
    @AppStorage("directorBlur") private var directorBlur = true
    @AppStorage("portraitDepth") private var portraitDepth = false
    @AppStorage("highQuality") private var highQuality = true
    @AppStorage("manualScene") private var manualScene = "风景"
    @AppStorage("manualFilter") private var manualFilterName = "自然"
    @AppStorage("compositionStyle") private var compositionStyle = "自然"
    @AppStorage("realtimeEffects") private var realtimeEffects = true
    @AppStorage("liveBeauty") private var liveBeauty = true
    @AppStorage("liveBeautyStrength") private var liveBeautyStrength = 0.16
    @AppStorage("filterStrength") private var filterStrength = 0.55
    // 诊断包：生成后的 zip 临时文件地址 / 失败原因
    @State private var diagnosticURL: URL?
    @State private var diagnosticError = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("按你的习惯拍摄").font(.title2.bold()).foregroundStyle(AppTheme.ink)
                        Text("拍摄行为、画面效果、保存和云端服务集中管理。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Label(autoDirector ? "导演开启" : "导演关闭", systemImage: "viewfinder")
                            Label(autoFilter ? "滤镜自动" : "滤镜手动", systemImage: "camera.filters")
                        }.font(.caption).foregroundStyle(AppTheme.muted)
                    }.padding(.vertical, 8)
                }
                Section {
                    Toggle("AI导演自动决策", isOn: $autoDirector)
                    Toggle("根据我的反馈调整", isOn: $directorLearning)
                    Picker("取景目标", selection: $directorFraming) {
                        ForEach(["自动", "环境", "完整人物", "半身", "特写", "合影", "运动", "突出主体"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("构图偏好", selection: $directorComposition) {
                        ForEach(["自动", "居中", "三分"], id: \.self) { Text($0).tag($0) }
                    }
                    NavigationLink("导演知识、决策与学习记录") { DirectorStatusView() }
                } header: { Text("AI导演") } footer: {
                    Text("导演在后台分析并执行，不在拍摄页堆叠提示。偏好来自明确反馈，视觉识别模型不在本机重新训练。")
                }
                Section("云端图片服务") {
                    NavigationLink("云端服务 · API Key与上传说明") { CloudAPISettingsView() }
                    Text("拍照自动存入本机图库；在图库逐张选择看图建议或云端修图，不自动上传或进行云端处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("智能拍摄") {
                    Toggle("自动识别场景", isOn: $autoScene)
                    if !autoScene {
                        Picker("拍摄场景", selection: $manualScene) {
                            ForEach(["人物", "风景", "建筑", "日落", "夜景", "花草", "海边", "汽车", "自拍"], id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Toggle("自动取景", isOn: $autoComposition)
                    Toggle("自动变焦", isOn: $autoZoom).disabled(!autoComposition || !autoDirector)
                    Toggle("构图达标后自动拍摄", isOn: $autoCapture)
                }
                Section {
                    Toggle("实时预览效果", isOn: $realtimeEffects)
                    Toggle("自然人像美颜", isOn: $liveBeauty)
                        .onChange(of: liveBeauty) { _, enabled in
                            if enabled { realtimeEffects = true; if liveBeautyStrength < 0.01 { liveBeautyStrength = 0.16 } }
                        }
                    Text("人像美颜开启时强制启用效果预览；仅在人脸被识别后作用于皮肤。可对准清晰正脸，在0与30%之间对比。")
                        .font(.caption).foregroundStyle(.secondary)
                    if liveBeauty {
                        Slider(value: $liveBeautyStrength, in: 0...0.30) { Text("磨皮强度") }
                        Text("仅在人脸区域轻柔处理，保护眼唇和纹理；不默认改变脸型。低分辨率预览与原尺寸成片可能有轻微差异。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("自动匹配滤镜", isOn: $autoFilter)
                    Text("关闭自动匹配后可选择鲜艳、电影等滤镜。预览与照片应用同一滤镜；强度为0时不生效。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !autoFilter {
                        Picker("滤镜", selection: $manualFilterName) {
                            ForEach(PhotoFilter.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("滤镜强度"); Spacer(); Text("\(Int(filterStrength * 100))%").foregroundStyle(.secondary) }
                        Slider(value: $filterStrength, in: 0...1)
                    }
                    Picker("成片风格", selection: $compositionStyle) {
                        ForEach(["自然", "电影", "主体"], id: \.self) { Text($0).tag($0) }
                    }
                } header: { Text("色彩与风格") } footer: {
                    Text("实时预览与成片共用美颜和调色顺序；预览最高15帧/秒并丢弃积压帧，不降低照片尺寸。滤镜强度为零时不应用调色。")
                }
                Section("导演控制") {
                    Toggle("单人特写实时轻虚化", isOn: $directorBlur)
                    Text("只用于半身、特写、突出主体。使用本机人物分割保护主体；遮罩异常或过热时关闭虚化。")
                    Text("人像自动快门要求可见眼部通过开合检查，无法确认时保留手动拍照；运动自动快门额外检查实际曝光时间和主体位移。")
                }
                Section("实时诊断") {
                    LabeledContent("人物数量", value: String(analyzer.directorObservation.personCount))
                    LabeledContent("眼部估计", value: analyzer.visionEvidence.eyes == "open" ? "睁眼" : analyzer.visionEvidence.eyes == "closed" ? "疑似闭眼" : "未知")
                    LabeledContent("相机控制", value: camera.controlsSettled ? "已稳定" : "调整中")
                    Text(camera.exposureText)
                    Text("位置跟踪与眼部判断在拍摄时更新；打开设置暂停相机，因此这里显示最近一次结果。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("把最近一次拍摄、最近一次精修的质检数据、导演建议、设置快照打包成 zip，方便一次性反馈问题。不包含账号密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        diagnosticURL = nil
                        diagnosticError = ""
                        do {
                            diagnosticURL = try DiagnosticsExporter.shared.export()
                        } catch {
                            diagnosticError = error.localizedDescription
                        }
                    } label: {
                        Label("生成诊断包", systemImage: "shippingbox")
                    }
                    if let url = diagnosticURL {
                        ShareLink(item: url) {
                            Label("分享诊断包", systemImage: "square.and.arrow.up")
                        }
                        Text("\(url.lastPathComponent) · \(diagnosticFileSizeText(url))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !diagnosticError.isEmpty {
                        Text(diagnosticError).font(.caption).foregroundStyle(.red)
                    }
                } header: { Text("诊断包") }
                Section("导演能力边界") {
                    Text("自动执行：连续变焦、曝光补偿、对焦/曝光/变焦状态确认与条件快门。普通场景由系统AE控制；运动模式在硬件支持时请求1/500秒并协调ISO，超出范围则限制在硬件范围。物理光圈不可调。")
                    Text("轻度背景虚化：仅在人像深度采集开启、照片带人物遮罩、单人突出主体时应用；无可靠遮罩保留原景。实时虚化使用人物分割，属于模拟景深。")
                    Text("跟踪使用位置连续性，不识别人脸身份。眼部开合、嘴部姿态、肩线和手腕边缘由关键点估计；遮挡、眼镜和侧脸可能无法判断。")
                }
                Section("滤镜种类") {
                    Text("41 套，分 7 组：基础 / 人像 / 风景 / 时段 / 胶片 / 黑白 / 艺术。拍摄效果面板按组切换Tab，不再横向滚动全部。")
                    Text("自然、鲜艳、暖阳、清冷、柔光、清新、人像、奶油人像、净透肤、玫瑰人像、蜜色人像、风景、森系、海洋、山岳、荒漠、天空、日落、金色时刻、蓝调时刻、夜景、极光、胶片、柯达、拍立得、复古、颗粒、黑白、银盐、黑色电影、高反差黑白、电影、霓虹、黑金、马卡龙、紫梦、青橙、褪色、阴郁、暗角、红外")
                        .font(.caption)
                    Text("自动模式优先保护肤色和高光；油画/动漫/水彩等强风格化属\"云端风格\"分类，走 Seedream 生成。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("色谱 · 各色饱和度") {
                    ForEach(["red", "orange", "yellow", "green", "cyan", "blue", "purple"], id: \.self) { key in
                        SpectrumControl(channel: key)
                    }
                    Text("橙色主要影响肤色；蓝青影响天空和水面；绿色影响植被。默认0，范围±20，预览和成片共用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("画质与保存") {
                    Toggle("最高照片尺寸", isOn: $highQuality)
                    Toggle("采集人像深度", isOn: $portraitDepth)
                    if portraitDepth {
                        Text("深度模式可能缩小系统允许的变焦范围；需要全范围变焦时请关闭此项。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("拍照后同时导出到系统相册", isOn: $exportToSystemAlbum)
                    if exportToSystemAlbum { Toggle("导出时同时保存原片", isOn: $saveBoth) }
                    Text("App图库始终保留原片；本地和AI成片作为不同版本保存。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("拍完留在相机；点击最近照片缩略图进入复盘。")
                }
                Section {
                    Toggle("三分网格", isOn: $showGrid)
                    Toggle("安静导演 · 隐藏文字引导", isOn: $quietDirector)
                } header: { Text("取景辅助") } footer: {
                    Text("拍摄页仅显示一句当前指导；安静模式隐藏文字，以构图标记和轻震动提示。")
                }
                Section("摄影学院") {
                    LabeledContent("课程", value: "24节 · 7个主题")
                    Text("包含原理、实拍练习、常见误区和验收方法；拍摄教练按最近拍摄指标提供本地建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于与许可") {
                    LabeledContent("版本", value: "1.1 (build 27)")
                    Text("实时拍摄分析在本机完成；图库中的DeepSeek建议和Seedream修图按需联网调用。")
                    Text("固定光圈机型通过自动快门、ISO和曝光补偿适应光线。本版未实现可变物理光圈控制。")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Smartcrop · MIT 开源许可") {
                        Text(DirectorLicenses.smartcrop).font(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("KalmanFilter · MIT 开源许可") {
                        Text(DirectorLicenses.kalman).font(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("CainCamera · Apache 2.0 开源许可") {
                        Text("高反差保留与强度混合公式已移植到 Core Image；未接入 Android / Face++ SDK。")
                        Text(CainBeautyKernels.licenseText).font(.caption).textSelection(.enabled)
                    }
                    DisclosureGroup("NextLevel · MIT 开源许可") {
                        Text(NextLevelDeviceControls.licenseText).font(.caption).textSelection(.enabled)
                    }
                }
            }.scrollContentBackground(.hidden)
                .background(AppTheme.paper)
                .navigationTitle("设置")
                .toolbar {
                    if isPresentedModally {
                        ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                    }
                }
                .tint(.mint)
        }
    }

    /// 诊断包体积文案（例如「1.2 MB」）
    private func diagnosticFileSizeText(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}


struct DirectorStatusView: View {
    @EnvironmentObject var analyzer: FrameAnalyzer
    @State private var feedbackCount = 0
    @State private var resetConfirmation = false
    var body: some View {
        List {
            Section("当前能力") {
                Text("视觉识别 + 摄影规则 + 候选构图评分 + 明确反馈形成的本地偏好。")
                Text("已记录 \(feedbackCount) 次反馈").font(.headline)
                Text("至少3次同类反馈后应用；不同场景、人脸/人体与合影分别记录。不会自动下载网络文章或在本机训练摄影大模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(DirectorKnowledge.domains.indices, id: \.self) { i in
                Section(DirectorKnowledge.domains[i].name) {
                    Text(DirectorKnowledge.domains[i].principles)
                }
            }
            Section("最近一次导演决策") {
                if analyzer.directorDecision.evidence.isEmpty {
                    Text("先打开相机，让导演获得可靠画面。")
                }
                ForEach(Array(analyzer.directorDecision.evidence.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.rule).font(.headline)
                        Text(item.observation).font(.caption).foregroundStyle(.secondary)
                        Text(item.action).font(.subheadline)
                    }
                }
            }
            Section {
                Button("清除导演偏好记录", role: .destructive) { resetConfirmation = true }
            } footer: {
                Text("导演偏好只存场景、主体占比和滤镜统计；图库云端服务仅在你点选后上传选中的照片副本。")
            }
        }.navigationTitle("导演知识与学习")
            .onAppear { feedbackCount = DirectorPreferenceStore.shared.feedbackCount }
            .alert("清除导演偏好？", isPresented: $resetConfirmation) {
                Button("清除", role: .destructive) {
                    DirectorPreferenceStore.shared.reset()
                    feedbackCount = 0
                }
                Button("取消", role: .cancel) { }
            } message: { Text("将删除本机积累的取景和滤镜偏好，课程进度与照片不受影响。") }
    }
}

private struct SpectrumControl: View {
    let channel: String
    @AppStorage private var amount: Double
    init(channel: String) {
        self.channel = channel
        self._amount = AppStorage(wrappedValue: 0, "spectrum_" + channel)
    }
    var body: some View {
        VStack {
            HStack {
                Text(["red":"红", "orange":"橙 / 肤色", "yellow":"黄", "green":"绿", "cyan":"青", "blue":"蓝", "purple":"紫"][channel] ?? channel)
                Spacer(); Text(String(format: "%+.0f", amount)).foregroundStyle(.secondary)
            }
            Slider(value: $amount, in: -20...20)
        }
    }
}
