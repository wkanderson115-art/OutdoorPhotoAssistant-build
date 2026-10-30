import SwiftUI
import PhotosUI
import UIKit
import Foundation
import CoreImage
import ImageIO

// MARK: - Shared instances and small helpers (file-private)

/// One pipeline / store for this screen. Created once so re-rendering the view
/// does not rebuild a `CIContext` every time the tab is shown.
private enum StudioShared {
    static let pipeline = RetouchPipeline()
    static let store = RetouchVersionStore()
}

private func suggestedStudioPresetID(for data: Data) async -> String {
    await Task.detached(priority: .userInitiated) {
        guard let image = UIImage(data: data) else { return "p25" }
        let (preset, _) = await RetouchPipeline().suggestPreset(image: image)
        return preset.id
    }.value
}

private let studioJobFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

private func studioJobName(now: Date = Date()) -> String {
    return "客片 " + studioJobFormatter.string(from: now)
}

private func studioStatusColor(_ status: BatchPhotoStatus) -> Color {
    switch status {
    case .pending: return Color(red: 0.55, green: 0.56, blue: 0.58)
    case .analysing: return Color.blue
    case .processed: return Color.orange
    case .approved: return Color.green
    case .rejected: return Color.red
    case .failed: return Color(red: 0.45, green: 0.06, blue: 0.06)
    }
}

private func studioColor(_ value: SIMD3<Double>) -> Color {
    return Color(red: min(max(value.x, 0), 1),
                 green: min(max(value.y, 0), 1),
                 blue: min(max(value.z, 0), 1))
}

private func studioBackgroundLabel(_ kind: BackgroundOptions.Kind) -> String {
    switch kind {
    case .keep: return "保留"
    case .clean: return "清理"
    case .solid: return "纯色"
    case .gradient: return "渐变"
    }
}

private func studioCornerLabel(_ corner: DeliveryOptions.WatermarkCorner) -> String {
    switch corner {
    case .bottomRight: return "右下"
    case .bottomLeft: return "左下"
    case .topRight: return "右上"
    case .topLeft: return "左上"
    }
}

private let studioMetricKeysOrder: [String] = [
    "texture_retention",
    "skin_tone_de",
    "skin_luma_shift",
    "skin_pixel_de_p95_info",
    "clipping_skin",
    "clipping_full",
    "seam_ratio",
    "ssim",
    "blemish_clearance",
    "spots_before"
]

private func studioOrderedMetricKeys(_ report: RetouchQualityReport) -> [String] {
    let known = studioMetricKeysOrder.filter { report.metrics[$0] != nil }
    let extra = report.metrics.keys.filter { !studioMetricKeysOrder.contains($0) }.sorted()
    return known + extra
}

private func studioMetricLabel(_ key: String) -> String {
    switch key {
    case "texture_retention": return "纹理保留"
    case "skin_tone_de": return "肤色 ΔE"
    case "skin_luma_shift": return "肤色明度偏移"
    case "skin_pixel_de_p95_info": return "肤色ΔE P95（信息）"
    case "clipping_skin": return "肤色裁切"
    case "clipping_full": return "整体裁切"
    case "seam_ratio": return "接缝比例"
    case "ssim": return "SSIM"
    case "blemish_clearance": return "瑕疵清除率"
    case "spots_before": return "检测瑕疵数"
    default: return key
    }
}

/// Subsampled ImageIO thumbnail: cheap enough to run on the main actor for sixty
/// cells, and never keeps a full-resolution decode alive.
private func studioThumbnail(from data: Data, maxPixel: CGFloat = 320) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return UIImage(data: data)
    }
    return UIImage(cgImage: cg)
}

private func studioByteText(_ bytes: Int) -> String {
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - Studio screen

struct RetouchStudioView: View {
    @StateObject private var runner: RetouchBatchRunner

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var presetID: String = "auto"
    @State private var strength: Double = 1.0
    @State private var jobID: UUID?
    @State private var loadedCount: Int = 0
    @State private var failedCount: Int = 0
    @State private var isImporting: Bool = false
    @State private var importMessage: String = ""
    @State private var selectedPhoto: BatchPhoto?
    @State private var showDelivery: Bool = false
    @State private var delivery: DeliveryOptions = DeliveryOptions()
    /// 手动补算建议后用来强制刷新建议卡片（BatchPhoto 的 @Published 不会冒泡到整批视图）。
    @State private var adviceTick: Int = 0

    init() {
        _runner = StateObject(wrappedValue: RetouchBatchRunner(pipeline: StudioShared.pipeline,
                                                             store: StudioShared.store))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("为每张照片找到合适的精修")
                            .font(.title3.weight(.bold))
                        Text("导入照片后按场景选预设，精修完成再逐张审核。原图始终保留。")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.muted)
                    }
                    studioSteps

                    NavigationLink {
                        CommercialRetouchView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.title3)
                                .frame(width: 42, height: 42)
                                .background(AppTheme.mint, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("单张双引擎精修").font(.headline)
                                Text("本地调节 + Seedream AI · 融合结果需人工审核")
                                    .font(.caption).foregroundStyle(AppTheme.muted)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .foregroundStyle(AppTheme.ink)
                        .appCard(tinted: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开单张双引擎精修")

                    importCard

                    if let job = runner.job {
                        StudioActionBar(presetID: $presetID, strength: $strength, job: job, runner: runner)
                        if runner.isRunning || runner.total > 0 {
                            progressCard
                        }
                        studioAdviceCard(job)
                        if job.anchor != nil {
                            StudioAnchorCard(job: job, runner: runner)
                        }
                        StudioPhotoGrid(job: job, runner: runner, selectedPhoto: $selectedPhoto)
                        StudioDeliveryCard(job: job, showDelivery: $showDelivery)
                    } else {
                        emptyState
                    }
                }
                .padding(18)
            }
            .background(AppTheme.paper)
            .navigationTitle("精修工作台")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: pickerItems) { newItems in
                importSelection(newItems)
            }
            .sheet(item: $selectedPhoto) { photo in
                if let job = runner.job {
                    RetouchReviewSheet(photo: photo,
                                       job: job,
                                       runner: runner,
                                       idPhotoSheet: $delivery.idPhotoSheet)
                }
            }
        }
        .sheet(isPresented: $showDelivery) {
            if let job = runner.job {
                RetouchDeliverySheet(job: job, options: $delivery)
            }
        }
    }

    // MARK: Import

    private var studioSteps: some View {
        HStack(spacing: 6) {
            ForEach(["1 导入", "2 精修", "3 审核", "4 交付"], id: \.self) { step in
                Text(step)
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(AppTheme.soft, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("照片").font(.headline)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 60, matching: .images) {
                Label("选择照片", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.isRunning || isImporting)
            Text("最多 60 张；每张独立识别风景、夜景、建筑或人物。")
                .font(.caption).foregroundStyle(AppTheme.muted)

            if isImporting {
                ProgressView(importMessage.isEmpty ? "正在读取照片…" : importMessage)
            } else if !importMessage.isEmpty {
                Text(importMessage).font(.footnote).foregroundStyle(AppTheme.ink)
            }

            if let job = runner.job {
                HStack(spacing: 8) {
                    Text("当前批次：\(job.name)").font(.caption).foregroundStyle(AppTheme.muted)
                    if let jobID {
                        Text("· \(jobID.uuidString.prefix(8))").font(.caption).foregroundStyle(AppTheme.muted)
                    }
                }
            }
            if failedCount > 0 {
                Text("\(failedCount) 张读取失败，已跳过；原图未改动").font(.caption).foregroundStyle(.orange)
            }
        }
        .appCard()
    }

    private func importSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isImporting else { return }
        isImporting = true
        importMessage = "正在读取 \(items.count) 张…"
        let preset = presetID
        let level = strength
        Task {
            var photos: [BatchPhoto] = []
            var failed = 0
            var index = 0
            for item in items {
                index += 1
                do {
                    let data = try await item.loadTransferable(type: Data.self)
                    if let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                       CGImageSourceGetCount(source) > 0 {
                        let photo = BatchPhoto(fileName: String(format: "IMG_%03d.jpg", index),
                                               originalData: data)
                        photo.adjustments.presetID = preset == "auto"
                            ? await suggestedStudioPresetID(for: data) : preset
                        photo.adjustments.strength = level
                        photos.append(photo)
                    } else {
                        failed += 1
                    }
                } catch {
                    failed += 1
                }
            }
            finishImport(photos: photos, failed: failed)
        }
    }

    private func finishImport(photos: [BatchPhoto], failed: Int) {
        isImporting = false
        failedCount = failed
        pickerItems = []
        guard !photos.isEmpty else {
            loadedCount = 0
            importMessage = "没有读到可用的照片，请重新选择"
            return
        }
        let job = BatchJob(name: studioJobName(), photos: photos)
        runner.job = job
        jobID = job.id
        loadedCount = photos.count
        importMessage = failed > 0
            ? "已导入 \(photos.count) 张，\(failed) 张读取失败"
            : "已导入 \(photos.count) 张"
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.phase.isEmpty ? (runner.isRunning ? "处理中" : "等待开始") : runner.phase)
                    .font(.subheadline)
                Spacer()
                Text("\(runner.completed)/\(runner.total)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AppTheme.muted)
            }
            ProgressView(value: Double(runner.completed), total: Double(max(runner.total, 1)))
                .tint(AppTheme.mint)
            if let job = runner.job {
                Text("待处理 \(job.pendingCount) · 待审核 \(job.processedCount) · 已通过 \(job.approvedCount) · 失败 \(job.failedCount)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .appCard(tinted: true)
    }

    // MARK: AI 修图建议（批次汇总）

    /// 批次级建议：单张的逐条建议在审核弹窗里看，这里只回答「几张要再跑 AI、统一用什么参数」。
    /// 汇总文案由 `AIEditAdvisor.batchSummary` 生成，和单张页共用同一套规则与阈值。
    private func studioAdviceCard(_ job: BatchJob) -> some View {
        let advices: [AIEditAdvice] = job.photos.compactMap { $0.advice }
        return VStack(alignment: .leading, spacing: 10) {
            Text("AI 修图建议").font(.headline)
            Text(AIEditAdvisor.batchSummary(advices, photoCount: job.photos.count))
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
            if let first = advices.first {
                Text("单张示例：\(AIEditAdvisor.brief(first))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            Button("为已处理照片生成建议") {
                runner.refreshAdvices(for: job)
                adviceTick += 1
            }
            .buttonStyle(AppActionStyle(primary: false))
            .disabled(runner.isRunning)
            Text("\(runner.needsAICount) 张建议再做一轮 AI")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .appCard()
        .id(adviceTick)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导入今天的客片，20 张左右最合适").font(.headline)
            Text("1 · 分析：读锚点、质检与瑕疵，不产出成片").font(.subheadline).foregroundStyle(AppTheme.muted)
            Text("2 · 审核：逐张看原图与精修对比，通过或淘汰").font(.subheadline).foregroundStyle(AppTheme.muted)
            Text("3 · 导出：只交付通过的照片，附清单与选片页").font(.subheadline).foregroundStyle(AppTheme.muted)
            Text("超过 40 张建议分两批，审核容易漏看。").font(.caption).foregroundStyle(AppTheme.muted)
        }
        .appCard()
    }
}

// MARK: - Shoot settings + batch actions

private struct StudioActionBar: View {
    @Binding var presetID: String
    @Binding var strength: Double
    @ObservedObject var job: BatchJob
    @ObservedObject var runner: RetouchBatchRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("精修方案").font(.headline)
            Picker("场景与预设", selection: $presetID) {
                Text("自动识别每张照片").tag("auto")
                ForEach(RetouchPresetCatalog.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(RetouchPresetCatalog.presets(for: category)) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(runner.isRunning)

            Text(presetID == "auto"
                 ? "自动模式：逐张识别场景；可手动选择风景、夜景、建筑、人像等预设"
                 : "当前预设：\(RetouchPresetCatalog.find(presetID).category) · \(RetouchPresetCatalog.find(presetID).name)")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("精修强度").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", strength))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                }
                Slider(value: $strength, in: 0.4...1.3, step: 0.05)
                    .accessibilityLabel("精修强度")
                    .disabled(runner.isRunning)
                Text("0.40–1.30，商业交付建议 0.90–1.10；改动后需重新精修。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }

            VStack(spacing: 8) {
                Button("开始精修") {
                    Task { await runner.process(job) }
                }
                .buttonStyle(AppActionStyle())
                .disabled(runner.isRunning || job.photos.isEmpty)
                .frame(maxWidth: .infinity)
                HStack {
                    Button("仅分析") { Task { await runner.prepare(job) } }
                        .disabled(runner.isRunning || job.pendingCount == 0)
                    Spacer()
                    Button("取消处理") { runner.cancel() }
                        .disabled(!runner.isRunning)
                }
                .font(.subheadline)
            }

            Text("“开始精修”会自动完成需要的分析；“仅分析”不会生成成片。")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .appCard()
        .onChange(of: presetID) { newValue in
            applyToPending(preset: newValue, level: strength)
        }
        .onChange(of: strength) { newValue in
            for photo in job.photos where photo.status == .pending {
                photo.adjustments.strength = newValue
            }
        }
    }

    private func applyToPending(preset: String, level: Double) {
        for photo in job.photos where photo.status == .pending {
            photo.adjustments.strength = level
            if preset == "auto" {
                Task {
                    let suggested = await suggestedStudioPresetID(for: photo.originalData)
                    if presetID == "auto" && photo.status == .pending {
                        photo.adjustments.presetID = suggested
                    }
                }
            } else {
                photo.adjustments.presetID = preset
            }
        }
    }
}

// MARK: - Anchor card

private struct StudioAnchorCard: View {
    @ObservedObject var job: BatchJob
    let runner: RetouchBatchRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let anchor = job.anchor {
                HStack {
                    Text("整批锚点").font(.headline)
                    Spacer()
                    Text("\(anchor.frameCount) 帧").font(.caption).foregroundStyle(AppTheme.muted)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    cell("肤色 L*", String(format: "%.1f", anchor.skinLabMedian.x))
                    cell("肤色 a*", String(format: "%.1f", anchor.skinLabMedian.y))
                    cell("肤色 b*", String(format: "%.1f", anchor.skinLabMedian.z))
                    cell("目标曝光", String(format: "%.3f", anchor.exposure))
                    cell("白平衡 R", String(format: "%.3f", anchor.whiteBalance.x))
                    cell("白平衡 G", String(format: "%.3f", anchor.whiteBalance.y))
                    cell("白平衡 B", String(format: "%.3f", anchor.whiteBalance.z))
                    cell("曝光上限", String(format: "±%.2f EV", anchor.maxEV))
                }
                Text("整批复用同一锚点：交付色彩一致").font(.caption).foregroundStyle(AppTheme.muted)
                Button("重新计算锚点") {
                    Task { await runner.rebuildAnchor(for: job) }
                }
                .font(.subheadline)
            }
        }
        .appCard()
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(AppTheme.muted)
            Text(value).font(.system(.footnote, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Photo grid

private struct StudioPhotoGrid: View {
    @ObservedObject var job: BatchJob
    @ObservedObject var runner: RetouchBatchRunner
    @Binding var selectedPhoto: BatchPhoto?

    private var columns: [GridItem] {
        return [GridItem(.adaptive(minimum: 92), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("照片").font(.headline)
                Spacer()
                Text("共 \(job.photos.count) 张 · 通过 \(job.approvedCount) · 淘汰 \(rejectedCount)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(job.photos.enumerated()), id: \.element.id) { index, photo in
                    cell(photo: photo, index: index + 1)
                }
            }
            ForEach(job.photos.filter { $0.status == .failed }, id: \.id) { photo in
                Text("\(photo.fileName)：\(photo.errorMessage ?? "精修失败，原因未知")")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("点开审核；长按可直接通过、淘汰或重试。").font(.caption).foregroundStyle(AppTheme.muted)
        }
        .appCard()
    }

    private var rejectedCount: Int {
        return job.photos.filter { $0.status == .rejected }.count
    }

    private func cell(photo: BatchPhoto, index: Int) -> some View {
        Button {
            selectedPhoto = photo
        } label: {
            VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                StudioThumbnail(photo: photo)
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(String(format: "%02d", index))
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(4)
            }
            .overlay(alignment: .bottom) {
                Text(photo.status.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(studioStatusColor(photo.status), in: Capsule())
                    .padding(4)
            }
            Text(RetouchPresetCatalog.find(photo.adjustments.presetID).name)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(AppTheme.muted)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("通过") { photo.status = .approved }
            Button("淘汰") { photo.status = .rejected }
            Button("重试") {
                Task { await runner.processOne(photo, in: job) }
            }
        }
        .accessibilityLabel("第 \(index) 张，\(photo.status.label)")
    }
}

private struct StudioThumbnail: View {
    @ObservedObject var photo: BatchPhoto
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: photo.id) {
            if let ready = photo.thumbnail {
                image = ready
                return
            }
            let data = photo.originalData
            if let made = studioThumbnail(from: data) {
                image = made
            }
        }
    }
}

// MARK: - Delivery entry

private struct StudioDeliveryCard: View {
    @ObservedObject var job: BatchJob
    @Binding var showDelivery: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("交付").font(.headline)
            Text("已通过 \(job.approvedCount) 张 · 待审核 \(job.processedCount) 张 · 全部 \(job.photos.count) 张")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            Button("交付设置与导出") {
                showDelivery = true
            }
            .buttonStyle(AppActionStyle(primary: job.approvedCount > 0))
            .disabled(job.approvedCount == 0)
            if job.approvedCount == 0 {
                Text("先审核通过至少一张，再导出交付包。").font(.caption).foregroundStyle(.orange)
            } else {
                Text("只导出「已通过」的照片，附清单与选片页；淘汰与失败的不会进包。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .appCard()
    }
}

// MARK: - Review sheet

private struct RetouchReviewSheet: View {
    @ObservedObject var photo: BatchPhoto
    @ObservedObject var job: BatchJob
    @ObservedObject var runner: RetouchBatchRunner
    @Binding var idPhotoSheet: Bool

    @Environment(\.dismiss) private var dismiss

    private enum PreviewMode: String, CaseIterable, Identifiable {
        case original = "原图"
        case retouched = "精修"
        case compare = "对比"
        var id: String { rawValue }
    }

    @State private var previewMode: PreviewMode = .retouched
    @State private var hasPendingEdits: Bool = false
    @State private var isReprocessing: Bool = false
    @State private var cachedOriginal: UIImage?
    @State private var cachedResult: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("预览视图", selection: $previewMode) {
                        ForEach(PreviewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    previewArea()

                    if photo.status == .approved || photo.status == .rejected {
                        Text("当前判定：\(photo.status.label)").font(.caption).foregroundStyle(AppTheme.muted)
                    }

                    qcPanel()
                    adviceCard()
                    editControls()
                    actionButtons()

                    if let error = photo.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            .background(AppTheme.paper)
            .navigationTitle(photo.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: photo.adjustments) { _ in
                hasPendingEdits = true
            }
            .onChange(of: photo.resultURL) { _ in
                cachedResult = photo.displayImage
            }
            .task(id: photo.id) {
                cachedOriginal = photo.originalImage
                cachedResult = photo.displayImage
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func previewArea() -> some View {
        switch previewMode {
        case .original:
            previewPane(image: cachedOriginal, title: "原图", height: 320)
        case .retouched:
            previewPane(image: cachedResult, title: "精修", height: 320)
        case .compare:
            HStack(spacing: 8) {
                previewPane(image: cachedOriginal, title: "原图", height: 210)
                previewPane(image: cachedResult, title: "精修", height: 210)
            }
        }
    }

    private func previewPane(image: UIImage?, title: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(AppTheme.muted)
            ZStack {
                AppTheme.soft
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text("暂无图像").font(.caption2).foregroundStyle(AppTheme.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: QC

    @ViewBuilder
    private func qcPanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = photo.report {
                HStack {
                    Text("质检").font(.headline)
                    Spacer()
                    Text(report.passed ? "通过" : "需复核")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(report.passed ? AppTheme.soft : Color.orange.opacity(0.18), in: Capsule())
                }
                Text(report.summary).font(.subheadline)
                let keys = studioOrderedMetricKeys(report)
                if !keys.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(keys, id: \.self) { key in
                            if let value = report.metrics[key] {
                                metricCell(key: key, value: value)
                            }
                        }
                    }
                }
                if !report.notes.isEmpty {
                    Text(report.notes.joined(separator: "；"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
            } else {
                Text("质检").font(.headline)
                Text("尚未精修，暂无质检数据。").font(.caption).foregroundStyle(AppTheme.muted)
            }
            Text("瑕疵：检测 \(photo.spotsFound)／剩余 \(photo.spotsRemaining) · 耗时 \(String(format: "%.1f", photo.processingSeconds)) 秒")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .appCard()
    }

    private func metricCell(key: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(studioMetricLabel(key)).font(.caption2).foregroundStyle(AppTheme.muted)
            Text(String(format: "%.3f", value)).font(.system(.footnote, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: AI 修图建议（单张）

    /// 审核弹窗里的单张建议：逐条 指标 → 现象 → 建议动作 → 建议参数，附可发送提示词。
    /// 提示词只做展示与复制；真正发起 AI 由「打开 AI 修图页」进单张双引擎流程。
    @ViewBuilder
    private func adviceCard() -> some View {
        if let advice = photo.advice {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("AI 修图建议（\(advice.items.count) 条）").font(.headline)
                    Spacer()
                    Text(String(format: "建议强度 %.2f", advice.recommendedStrength))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                Text(advice.headline).font(.subheadline)

                ForEach(advice.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.metric).font(.caption2.weight(.bold))
                        Text("现象：\(item.finding)").font(.caption)
                        Text("建议动作：\(item.action)").font(.caption)
                        Text("建议参数：\(item.parameter)")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))
                }

                Text("可直接发送的提示词").font(.caption.weight(.semibold))
                Text(advice.prompt).font(.caption2).foregroundStyle(AppTheme.muted)

                HStack(spacing: 10) {
                    Button("复制提示词") {
                        UIPasteboard.general.string = advice.prompt
                    }
                    .buttonStyle(AppActionStyle(primary: false))

                    NavigationLink("打开 AI 修图页") {
                        CommercialRetouchView()
                    }
                    .buttonStyle(AppActionStyle(primary: false))
                }
            }
            .appCard()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI 修图建议").font(.headline)
                Text("这张还没有建议：先完成精修，或在批次页点「为已处理照片生成建议」。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            .appCard()
        }
    }

    // MARK: Edits (never auto-reprocess)

    private func editControls() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("参数").font(.headline)
                Spacer()
                if hasPendingEdits {
                    Text("参数已修改，点重新精修生效")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Picker("精修类型", selection: $photo.adjustments.presetID) {
                ForEach(RetouchPresetCatalog.categories, id: \.self) { category in
                    Section(category) {
                        ForEach(RetouchPresetCatalog.presets(for: category)) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
            }
            .pickerStyle(.menu)

            valueSlider("精修强度",
                        value: $photo.adjustments.strength,
                        range: 0.4...1.3,
                        step: 0.05,
                        hint: nil)

            if ["人像摄影", "婚纱与情侣", "家庭与儿童", "时尚与穿搭"].contains(
                RetouchPresetCatalog.find(photo.adjustments.presetID).category) {
            HStack {
                Text("液化").font(.subheadline.weight(.semibold))
                Spacer()
                Button("重置液化") {
                    photo.adjustments.reshape = ReshapeParameters.neutral
                }
                .font(.caption)
            }

            valueSlider("瘦脸", value: $photo.adjustments.reshape.faceWidth, range: 0...1, step: 0.05, hint: nil)
            valueSlider("下颌", value: $photo.adjustments.reshape.jawline, range: 0...1, step: 0.05, hint: nil)
            valueSlider("下巴", value: $photo.adjustments.reshape.chin, range: 0...1, step: 0.05, hint: nil)
            valueSlider("大眼", value: $photo.adjustments.reshape.eyeSize, range: 0...1, step: 0.05, hint: nil)
            valueSlider("鼻翼", value: $photo.adjustments.reshape.noseWidth, range: 0...1, step: 0.05, hint: nil)
            valueSlider("脖子", value: $photo.adjustments.reshape.neckThin, range: 0...1, step: 0.05, hint: nil)
            valueSlider("收腰", value: $photo.adjustments.reshape.waist, range: 0...1, step: 0.05, hint: nil)
            valueSlider("手臂", value: $photo.adjustments.reshape.armThin, range: 0...1, step: 0.05, hint: nil)
            }

            Text("背景").font(.subheadline.weight(.semibold))
            Picker("背景", selection: $photo.adjustments.background.kind) {
                ForEach(BackgroundOptions.Kind.allCases, id: \.self) { kind in
                    Text(studioBackgroundLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 14) {
                swatch("白", base: BackgroundOptions.white)
                swatch("蓝", base: BackgroundOptions.studioBlue)
                swatch("灰", base: BackgroundOptions.studioGray)
            }

            valueSlider("清理强度",
                        value: $photo.adjustments.background.cleanupAmount,
                        range: 0...1,
                        step: 0.05,
                        hint: nil)

            Divider()

            Toggle("证件照裁切", isOn: idPhotoOn)
                .tint(AppTheme.mint)
            if photo.adjustments.idPhoto != nil {
                Picker("证件照规格", selection: idPhotoSpec) {
                    ForEach(IDPhotoSpec.allCases) { spec in
                        Text(spec.displayName).tag(spec)
                    }
                }
            }
            Toggle("六寸相纸排版", isOn: $idPhotoSheet)
                .tint(AppTheme.mint)

            Text("改参数不会自动重算；确认后点「重新精修」。")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .appCard()
    }

    private func valueSlider(_ title: String, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double,
                             hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.muted)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(AppTheme.muted)
            }
        }
    }

    private func swatch(_ title: String, base: BackgroundOptions) -> some View {
        let active = photo.adjustments.background.color == base.color
            && photo.adjustments.background.colorBottom == base.colorBottom
        return Button {
            var background = photo.adjustments.background
            background.color = base.color
            background.colorBottom = base.colorBottom
            if background.kind == .keep {
                background.kind = .solid
            }
            photo.adjustments.background = background
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(studioColor(base.color))
                    .frame(width: 36, height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(active ? AppTheme.ink : Color(.systemGray4),
                                    lineWidth: active ? 2 : 1)
                    )
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(active ? AppTheme.ink : AppTheme.muted)
            }
        }
        .buttonStyle(.plain)
    }

    private var idPhotoOn: Binding<Bool> {
        return Binding(get: {
            photo.adjustments.idPhoto != nil
        }, set: { isOn in
            if isOn {
                photo.adjustments.idPhoto = photo.adjustments.idPhoto ?? IDPhotoSpec.oneInch
                photo.adjustments.cropToIDPhoto = true
            } else {
                photo.adjustments.idPhoto = nil
                photo.adjustments.cropToIDPhoto = false
            }
        })
    }

    private var idPhotoSpec: Binding<IDPhotoSpec> {
        return Binding(get: {
            photo.adjustments.idPhoto ?? IDPhotoSpec.oneInch
        }, set: { spec in
            photo.adjustments.idPhoto = spec
            photo.adjustments.cropToIDPhoto = true
        })
    }

    // MARK: Actions

    private func actionButtons() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("重新精修") {
                guard !isReprocessing else { return }
                isReprocessing = true
                Task {
                    await runner.processOne(photo, in: job)
                    cachedResult = photo.displayImage
                    hasPendingEdits = false
                    isReprocessing = false
                }
            }
            .buttonStyle(AppActionStyle())
            .disabled(isReprocessing || runner.isRunning)

            HStack(spacing: 10) {
                Button("通过") {
                    photo.status = .approved
                }
                .buttonStyle(AppActionStyle())

                Button("淘汰") {
                    photo.status = .rejected
                }
                .buttonStyle(AppActionStyle(primary: false))
            }

            Button("应用到本批") {
                runner.applyAdjustments(from: photo, to: job)
            }
            .buttonStyle(AppActionStyle(primary: false))

            Text("「应用到本批」把这套参数写进整批，不自动重算；需要时回列表点「开始精修」。")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .appCard()
    }
}

// MARK: - Delivery sheet

private enum DeliveryAttempt {
    case success(DeliveryResult)
    case failure(String)
}

private struct RetouchDeliverySheet: View {
    @ObservedObject var job: BatchJob
    @Binding var options: DeliveryOptions

    @Environment(\.dismiss) private var dismiss
    @State private var isExporting: Bool = false
    @State private var attempt: DeliveryAttempt?

    var body: some View {
        NavigationStack {
            Form {
                Section("网页长边") {
                    Stepper("长边 \(options.webLongEdge) px",
                            value: $options.webLongEdge, in: 640...6144, step: 256)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("网页质量")
                            Spacer()
                            Text(String(format: "%.2f", options.webQuality))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $options.webQuality, in: 0.5...1.0, step: 0.01)
                    }
                }

                Section("全尺寸") {
                    Toggle("同时输出全尺寸", isOn: $options.includeFullResolution)
                    Picker("全尺寸格式", selection: $options.printFormat) {
                        ForEach(DeliveryOptions.Format.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                }

                Section("色彩空间") {
                    Picker("色彩空间", selection: $options.colorSpace) {
                        ForEach(DeliveryOptions.ColorSpace.allCases, id: \.self) { space in
                            Text(space.label).tag(space)
                        }
                    }
                }

                Section("水印") {
                    TextField("水印文字（留空则不加）", text: watermarkText)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("透明度")
                            Spacer()
                            Text(String(format: "%.2f", options.watermarkOpacity))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $options.watermarkOpacity, in: 0...1, step: 0.01)
                    }
                    Picker("位置", selection: $options.watermarkCorner) {
                        ForEach(DeliveryOptions.WatermarkCorner.allCases, id: \.self) { corner in
                            Text(studioCornerLabel(corner)).tag(corner)
                        }
                    }
                }

                Section("文件命名") {
                    TextField("文件前缀", text: $options.filePrefix)
                }

                Section("附加") {
                    Toggle("生成选片页", isOn: $options.includeProofingPage)
                    Toggle("六寸相纸排版", isOn: $options.idPhotoSheet)
                }

                Section("导出") {
                    Text("本次将导出已通过 \(job.approvedCount) 张，全部 \(job.photos.count) 张中的通过项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("导出交付包") {
                        exportPackage()
                    }
                    .disabled(isExporting || job.approvedCount == 0)

                    if job.approvedCount == 0 {
                        Text("没有通过审核的照片，先回审核页点「通过」。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let attempt {
                        switch attempt {
                        case .success(let value):
                            ShareLink(item: value.packageURL) {
                                Label("分享交付包", systemImage: "square.and.arrow.up")
                            }
                            Text("文件夹：\(value.folderURL.path)")
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("总大小：\(studioByteText(value.totalBytes))")
                                .font(.caption)
                            Text("张数：已通过 \(job.approvedCount) 张")
                                .font(.caption)
                            if let manifest = value.manifestURL {
                                Text("清单：\(manifest.lastPathComponent)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let proofing = value.proofingURL {
                                Text("选片页：\(proofing.lastPathComponent)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        case .failure(let message):
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("交付设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .overlay {
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.16).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("正在导出交付包…").font(.subheadline)
                            Text("按通过照片逐张渲染，别锁屏。").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    private var watermarkText: Binding<String> {
        return Binding(get: {
            options.watermarkText ?? ""
        }, set: { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            options.watermarkText = trimmed.isEmpty ? nil : text
        })
    }

    private func exportPackage() {
        guard !isExporting else { return }
        guard job.approvedCount > 0 else {
            attempt = .failure("没有通过审核的照片，先审核通过再导出")
            return
        }
        isExporting = true
        attempt = nil
        let snapshot = options
        let targetJob = job
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> DeliveryAttempt in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RetouchDelivery", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let exporter = RetouchDeliveryExporter(context: CIContext())
                    let value = try exporter.export(job: targetJob,
                                                    approvedOnly: true,
                                                    options: snapshot,
                                                    to: directory)
                    return DeliveryAttempt.success(value)
                } catch {
                    return DeliveryAttempt.failure(error.localizedDescription)
                }
            }.value
            attempt = outcome
            isExporting = false
        }
    }
}
