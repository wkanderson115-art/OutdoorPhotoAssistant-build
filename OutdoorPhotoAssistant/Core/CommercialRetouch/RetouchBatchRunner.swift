import Foundation
import UIKit
import CoreImage
import Combine

// MARK: - Errors

enum RetouchBatchError: LocalizedError {
    case emptyJob
    case cancelled
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyJob:
            return "批次里还没有照片，请先导入素材再开始精修"
        case .cancelled:
            return "已取消本次批处理，没做完的照片回到待处理"
        case .storeUnavailable(let detail):
            return "无法创建版本库目录：\(detail)"
        }
    }
}

// MARK: - Concurrency plumbing

/// `Task.detached` 的闭包和返回值都必须是 Sendable，但 `UIImage`、`RetouchOutcome`、
/// `RetouchPipeline`、`RetouchVersionStore` 都不是。这里用一个显式的盒子把值搬进搬出，
/// 让并发检查的结果在任何 Swift 5 工具链上都一样（不依赖 warning 降级）。
///
/// 盒子本身不做同步：每个盒子只有「主线程写入 -> 交给一个 detached 任务 -> 等它回来
/// 之后再读」这一种用法，中间没有任何并发访问。
private final class RetouchValueBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// 把任何 Error 变成一句可以直接显示给摄影师的中文。
/// 故意放在文件级（不做 actor 隔离），detached 任务里也能调用。
private func retouchBatchMessage(for error: Error, fallback: String) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty {
        return description
    }
    let description = error.localizedDescription
    return description.isEmpty ? fallback : description
}

// MARK: - Batch runner

/// Serial batch runner for a 20-photo/day studio workflow.
///
/// Stage 1 (prepare): analyse every frame, build ONE ShootAnchor so the whole set
/// is colour-consistent, estimate per-photo difficulty.
/// Stage 2 (process): retouch each frame against that anchor, serially (a studio
/// iPad must stay responsive and its memory flat), persisting a revision per photo.
///
/// 状态机（`BatchPhotoStatus`，runner 只负责这几种转移）：
///
///     pending   --processOne/process-->  analysing
///     analysing --成功方-->                processed        （resultURL/report/spots 就位）
///     analysing --抛错方-->                failed + errorMessage
///     analysing --cancel()-->              pending
///     failed    --retry-->                 analysing -> processed / failed
///     processed / approved / rejected      终态，runner 不再碰（approved/rejected 归人审）
///
/// 只有 UI 会把 `processed` 改成 `approved` / `rejected`；runner 永远不会写这两个状态。
/// `rejected`（人审淘汰）的照片不参与锚点计算，也不会被重新精修。
@MainActor
final class RetouchBatchRunner: ObservableObject {

    // MARK: Stored collaborators

    private let pipeline: RetouchPipeline
    private let store: RetouchVersionStore

    // MARK: Published state

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var completed: Int = 0
    @Published private(set) var total: Int = 0
    /// "分析中" / "精修中" / "已完成"
    @Published private(set) var phase: String = "已完成"
    @Published var job: BatchJob?

    // MARK: Private state

    /// 当前批次任务。`cancel()` 只 cancel 不置 nil，下一次 prepare/process 会先等它收尾，
    /// 这样永远不会出现两条流水线同时改同一批 photo 的状态。
    private var runTask: Task<Void, Never>?
    private var runGeneration: Int = 0

    /// 每张照片的分析结果，只在 prepare / rebuildAnchor 里填。
    /// 故意不 @Published：20 个 SkinAnalysis 各带两张全尺寸 CIImage，发布给 SwiftUI 只会白占内存。
    private var analyses: [UUID: SkinAnalysis] = [:]

    /// 整批共用的版本库目录（一个 BatchJob = 一个目录）。
    private var storeJobID: UUID?
    /// 这个目录属于哪个 BatchJob，防止换批次时复用旧目录。
    private var storeJobOwner: UUID?

    // MARK: Init

    init(pipeline: RetouchPipeline, store: RetouchVersionStore) {
        self.pipeline = pipeline
        self.store = store
    }

    // MARK: - Stage 1: analysis pass + anchor

    func prepare(_ job: BatchJob) async {
        await runTracked { [weak self] in
            guard let self = self else { return }
            await self.performPrepare(job)
        }
    }

    /// 串行分析每一张：`analysis(for:)` 是 Vision + 皮肤掩膜的活，放在 detached 任务里跑，
    /// 主线程只接收结果。分析失败的那张标 `.failed` 并写中文原因，其余回到 `.pending`。
    /// 进度 = 已分析张数 / 总张数。
    private func performPrepare(_ job: BatchJob) async {
        self.job = job
        job.lastError = nil
        total = job.photos.count
        completed = 0
        job.progress = 0
        phase = "分析中"
        isRunning = true
        job.isRunning = true
        analyses.removeAll(keepingCapacity: true)

        var collected: [SkinAnalysis] = []

        for photo in job.photos {
            if Task.isCancelled { break }

            // 人审淘汰的片子不进锚点，也不改状态
            if photo.status == .rejected {
                completed += 1
                job.progress = progressValue()
                continue
            }

            guard let image = photo.originalImage else {
                photo.status = .failed
                photo.errorMessage = "无法读取原图数据（文件可能已损坏或格式不支持）"
                completed += 1
                job.progress = progressValue()
                continue
            }

            let analysis = await analyseOffMain(image)
            if Task.isCancelled { break }

            guard let analysis = analysis else {
                // 风景、建筑、宠物和夜景不需要人脸分析；跳过肤色锚点即可继续精修。
                if photo.status != .processed && photo.status != .approved { photo.status = .pending }
                photo.errorMessage = nil
                completed += 1
                job.progress = progressValue()
                continue
            }

            analyses[photo.id] = analysis
            collected.append(analysis)

            // 已经有结果的片子不降级（结果还有效），其余统一回到待处理
            if photo.status != .processed && photo.status != .approved {
                photo.status = .pending
            }
            photo.errorMessage = nil
            completed += 1
            job.progress = progressValue()
        }

        if !Task.isCancelled {
            let anchor = ShootAnchor.build(from: collected)
            job.anchor = anchor
            // 无人脸批次使用独立照片色调处理；不阻止后续精修。
            if anchor == nil { job.lastError = nil }
        }

        completed = min(completed, total)
        job.progress = progressValue()
        isRunning = false
        job.isRunning = false
        phase = "已完成"
    }

    // MARK: - Stage 2: serial processing

    /// 处理所有还没出结果的片子（`.pending` / `.failed` / 残留的 `.analysing`）。
    /// `.processed` 不重跑，`.approved` / `.rejected` 归人审，这里一概跳过。
    func process(_ job: BatchJob) async {
        await runTracked { [weak self] in
            guard let self = self else { return }
            await self.performProcess(job)
        }
    }

    private func performProcess(_ job: BatchJob) async {
        self.job = job

        guard !job.photos.isEmpty else {
            job.lastError = RetouchBatchError.emptyJob.localizedDescription
            total = 0
            completed = 0
            job.progress = 0
            isRunning = false
            job.isRunning = false
            phase = "已完成"
            return
        }

        // 没有锚点就先补一次分析；还建不起来就带着原因退出（原因已经在 job.lastError 里）
        if job.anchor == nil {
            await performPrepare(job)
        }
        if Task.isCancelled {
            isRunning = false
            job.isRunning = false
            phase = "已完成"
            return
        }

        do {
            try ensureStoreJob(for: job)
        } catch {
            job.lastError = retouchBatchMessage(for: error, fallback: "无法创建版本库目录")
            isRunning = false
            job.isRunning = false
            phase = "已完成"
            return
        }

        total = job.photos.count
        completed = 0
        job.progress = 0
        phase = "精修中"
        isRunning = true
        job.isRunning = true

        for photo in job.photos {
            if Task.isCancelled { break }
            switch photo.status {
            case .processed, .approved, .rejected:
                completed += 1
                job.progress = progressValue()
                continue
            case .pending, .analysing, .failed:
                await performOne(photo, in: job)
                completed += 1
                job.progress = progressValue()
            }
        }

        finishRun(job, cancelled: Task.isCancelled)
    }

    // MARK: - One photo

    func processOne(_ photo: BatchPhoto, in job: BatchJob) async {
        await runTracked { [weak self] in
            guard let self = self else { return }
            await self.performSingle(photo, in: job)
        }
    }

    func retry(_ photo: BatchPhoto, in job: BatchJob) async {
        await runTracked { [weak self] in
            guard let self = self else { return }
            // 重试 = 清掉上次的错误信息再走一遍单张流程。
            // 旧版本文件不会被覆盖：saveJPEG 每次写一份新的 local-<UUID>.jpg。
            photo.errorMessage = nil
            if photo.status == .failed || photo.status == .analysing {
                photo.status = .pending
            }
            await self.performSingle(photo, in: job)
        }
    }

    private func performSingle(_ photo: BatchPhoto, in job: BatchJob) async {
        self.job = job
        job.lastError = nil
        total = job.photos.count
        completed = 0
        phase = "精修中"

        if job.anchor == nil {
            await performPrepare(job)
        }
        if Task.isCancelled {
            isRunning = false
            job.isRunning = false
            phase = "已完成"
            return
        }

        do {
            try ensureStoreJob(for: job)
        } catch {
            job.lastError = retouchBatchMessage(for: error, fallback: "无法创建版本库目录")
            isRunning = false
            job.isRunning = false
            phase = "已完成"
            return
        }

        isRunning = true
        job.isRunning = true
        await performOne(photo, in: job)
        completed = job.photos.filter {
            $0.status == .processed || $0.status == .approved || $0.status == .rejected
        }.count
        finishRun(job, cancelled: Task.isCancelled)
    }

    /// 单张流水线：.analysing -> 像素处理（detached）-> 写盘（detached）-> .processed / .failed。
    ///
    /// 锚点就是在这里应用的：`anchor` 原样传给 `pipeline.process(_:preset:adjustments:anchor:)`，
    /// runner 自己不碰曝光/白平衡（`RetouchAdjustments` 也没有这两个字段），
    /// 保证「全批同一套颜色」只有 pipeline 一个决策点。
    private func performOne(_ photo: BatchPhoto, in job: BatchJob) async {
        guard !Task.isCancelled else { return }

        let anchor = job.anchor
        photo.status = .analysing
        photo.errorMessage = nil
        photo.processingSeconds = 0

        guard let image = photo.originalImage else {
            photo.status = .failed
            photo.errorMessage = "无法读取原图数据（文件可能已损坏或格式不支持）"
            return
        }
        guard let storeJob = storeJobID else {
            photo.status = .failed
            photo.errorMessage = "版本库目录还没有准备好，请重新开始本批次"
            return
        }

        let preset = RetouchPresetCatalog.find(photo.adjustments.presetID)
        let adjustments = photo.adjustments
        let started = CFAbsoluteTimeGetCurrent()

        // ---- 第一段：像素处理，最重的一段，完全离开主线程 ----
        let pipelineBox = RetouchValueBox<RetouchPipeline>(pipeline)
        let imageBox = RetouchValueBox<UIImage>(image)
        let presetBox = RetouchValueBox<RetouchPreset>(preset)
        let adjustmentsBox = RetouchValueBox<RetouchAdjustments>(adjustments)
        let anchorBox = RetouchValueBox<ShootAnchor?>(anchor)
        let outcomeBox = RetouchValueBox<RetouchOutcome?>(nil)
        let failureBox = RetouchValueBox<Error?>(nil)

        await Task.detached(priority: .userInitiated) {
            do {
                let outcome = try pipelineBox.value.process(imageBox.value,
                                                            preset: presetBox.value,
                                                            adjustments: adjustmentsBox.value,
                                                            anchor: anchorBox.value)
                outcomeBox.value = outcome
            } catch {
                failureBox.value = error
            }
        }.value

        // 取消检查放在写盘之前：detached 任务本身没法被取消，所以这里直接丢弃结果，
        // 状态回到待处理，磁盘上不会多出一份没人认领的 revision。
        if Task.isCancelled {
            photo.status = .pending
            photo.processingSeconds = CFAbsoluteTimeGetCurrent() - started
            return
        }

        if let failure = failureBox.value {
            photo.status = .failed
            photo.errorMessage = retouchBatchMessage(for: failure, fallback: "本张精修失败，可单张重试")
            photo.processingSeconds = CFAbsoluteTimeGetCurrent() - started
            return
        }

        guard let outcome = outcomeBox.value else {
            photo.status = .failed
            photo.errorMessage = "精修没有返回结果（内部输出为空），可单张重试"
            photo.processingSeconds = CFAbsoluteTimeGetCurrent() - started
            return
        }

        // ---- 第二段：写盘（JPEG 编码 + 质检 + 版本记录），同样不占主线程 ----
        let storeBox = RetouchValueBox<RetouchVersionStore>(store)
        let outputBox = RetouchValueBox<UIImage>(outcome.image)
        let savedBox = RetouchValueBox<URL?>(nil)
        let saveFailureBox = RetouchValueBox<Error?>(nil)

        await Task.detached(priority: .userInitiated) {
            do {
                savedBox.value = try storeBox.value.saveJPEG(outputBox.value, job: storeJob, label: "local")
            } catch {
                saveFailureBox.value = error
            }
        }.value

        guard let savedURL = savedBox.value else {
            let detail: String
            if let saveFailure = saveFailureBox.value {
                detail = retouchBatchMessage(for: saveFailure, fallback: "版本写入失败")
            } else {
                detail = "版本写入失败"
            }
            photo.status = .failed
            photo.errorMessage = "精修结果无法写入版本库：\(detail)"
            photo.processingSeconds = CFAbsoluteTimeGetCurrent() - started
            return
        }

        photo.resultURL = savedURL
        photo.report = outcome.report
        photo.spotsFound = outcome.spotsFound
        photo.spotsRemaining = outcome.spotsRemaining
        // 精修结果一落盘就生成 AI 修图建议：报告、瑕疵数与本次实际生效的预设/强度都在手上，
        // 不需要再回头重算一遍质检。纯查表 + 字符串拼装，主线程写回，和上面几个字段同一批更新。
        photo.advice = AIEditAdvisor.makeAdvice(report: outcome.report,
                                                look: preset.look,
                                                presetID: preset.id,
                                                strength: adjustments.strength,
                                                spotsFound: outcome.spotsFound,
                                                spotsRemaining: outcome.spotsRemaining,
                                                shootingMode: outcome.shootingMode)
        // 刻意不缓存全尺寸结果图：20 张 24MP 的 UIImage 同时驻留会直接把 iPad 内存打满。
        // BatchPhoto.displayImage 已经是「先读 resultURL，再退回 thumbnail/original」的顺序。
        photo.processingSeconds = CFAbsoluteTimeGetCurrent() - started
        photo.status = .processed
        photo.errorMessage = nil
    }

    // MARK: - Cancellation

    /// 立刻停：取消当前任务，并把还在 `.analysing` 的片子翻回 `.pending`。
    ///
    /// 注意 `runTask` 不在这里置 nil —— 让下一次 prepare/process 自己等旧任务收尾。
    /// detached 的像素任务无法被取消，所以最多再多算一张；它回来时看到 `Task.isCancelled`
    /// 会丢弃结果，不会写状态也不会写盘。
    func cancel() {
        runTask?.cancel()
        if let current = job {
            for photo in current.photos where photo.status == .analysing {
                photo.status = .pending
            }
            current.isRunning = false
            current.lastError = RetouchBatchError.cancelled.localizedDescription
        }
        isRunning = false
        phase = "已完成"
    }

    // MARK: - Studio "统一风格"

    /// Copies one photo's adjustments to every other photo in the batch (studio "统一风格").
    /// 只改参数、不改状态：要看到效果必须重新跑一次精修（旧 revision 永远不会被覆盖）。
    func applyAdjustments(from photo: BatchPhoto, to job: BatchJob) {
        let source = photo.adjustments
        for other in job.photos where other.id != photo.id {
            other.adjustments = source
        }
    }

    // MARK: - AI 修图建议

    /// 建议里还有未合规项的照片数（批量审批时用来决定「要不要再跑一轮 AI」）。
    var needsAICount: Int {
        job?.photos.filter { $0.needsAI }.count ?? 0
    }

    /// 给已经出过质检报告的照片补算 AI 修图建议，不重新渲染、不写盘、不改状态。
    ///
    /// 用在「早先版本处理过、`photo.advice` 还是 nil」或者用户手改过参数之后：
    /// 只挑 `processed` / `approved` 且有 `report` 的照片重算一遍文案，成本是纯字符串拼装。
    @MainActor func refreshAdvices(for job: BatchJob) {
        self.job = job
        for photo in job.photos {
            guard photo.status == .processed || photo.status == .approved else { continue }
            guard let report = photo.report else { continue }
            let preset = RetouchPresetCatalog.find(photo.adjustments.presetID)
            photo.advice = AIEditAdvisor.makeAdvice(report: report,
                                                    look: preset.look,
                                                    presetID: preset.id,
                                                    strength: photo.adjustments.strength,
                                                    spotsFound: photo.spotsFound,
                                                    spotsRemaining: photo.spotsRemaining)
        }
    }

    // MARK: - Anchor rebuild

    /// Recomputes the anchor after photos were removed/added.
    /// 已缓存的分析结果优先复用，只有没见过的照片（或缓存被清掉的）才重新分析。
    func rebuildAnchor(for job: BatchJob) async {
        await runTracked { [weak self] in
            guard let self = self else { return }
            await self.performRebuildAnchor(job)
        }
    }

    private func performRebuildAnchor(_ job: BatchJob) async {
        self.job = job
        job.lastError = nil
        total = job.photos.count
        completed = 0
        job.progress = 0
        phase = "分析中"
        isRunning = true
        job.isRunning = true

        let liveIDs = Set(job.photos.map { $0.id })
        analyses = analyses.filter { liveIDs.contains($0.key) }

        let previousAnchor = job.anchor
        var collected: [SkinAnalysis] = []

        for photo in job.photos {
            if Task.isCancelled { break }

            if photo.status == .rejected {
                completed += 1
                job.progress = progressValue()
                continue
            }

            if let cached = analyses[photo.id] {
                collected.append(cached)
                completed += 1
                job.progress = progressValue()
                continue
            }

            guard let image = photo.originalImage else {
                completed += 1
                job.progress = progressValue()
                continue
            }

            let analysis = await analyseOffMain(image)
            if Task.isCancelled { break }

            guard let analysis = analysis else {
                completed += 1
                job.progress = progressValue()
                continue
            }

            analyses[photo.id] = analysis
            collected.append(analysis)
            completed += 1
            job.progress = progressValue()
        }

        if Task.isCancelled {
            finishRun(job, cancelled: true)
            return
        }

        let anchor = ShootAnchor.build(from: collected)
        job.anchor = anchor
        if anchor == nil {
            job.lastError = "重新计算基准失败：没有一张照片能解析出可靠肤色"
        } else if let previous = previousAnchor, previous != anchor {
            let hasProcessed = job.photos.contains { $0.status == .processed || $0.status == .approved }
            if hasProcessed {
                job.lastError = "基准已重新计算，之前精修的片子需要重跑一次才能完全对齐"
            }
        }

        finishRun(job, cancelled: false)
    }

    // MARK: - Difficulty estimate (doc-comment stage 1 promise, read-only)

    /// 0...1 的难度估计，给 UI 排期/预警用（闭眼、糊片、色偏大的先人工看）。
    /// 需要先 `prepare` 过才有值。
    func estimatedDifficulty(for photo: BatchPhoto) -> Double? {
        guard let analysis = analyses[photo.id], let anchor = job?.anchor else { return nil }
        let correction = anchor.correction(for: analysis)
        let evDistance = abs(correction.ev) / max(anchor.maxEV, 1e-3)
        let gainSpread = max(abs(correction.gains.x - 1.0),
                             abs(correction.gains.y - 1.0),
                             abs(correction.gains.z - 1.0)) / 0.06
        let noise = min(1.0, max(0.0, analysis.noiseSigma / 0.04))
        let value = 0.45 * evDistance + 0.35 * gainSpread + 0.20 * noise
        return min(1.0, max(0.0, value))
    }

    // MARK: - Persistence

    /// 整批只建一个版本库 job 目录。
    ///
    /// `RetouchVersionStore.newJob(originalData:)` 的实际作用只有两件：建目录 + 落一份
    /// `original.bin`。所以这里**只调用一次**，传批次里第一张照片的原始字节：
    /// - 目录 UUID 由版本库生成，在本 runner 里缓存成 `storeJobID`；这一批 20 张照片的
    ///   所有 revision 都落在同一个目录里，`versions(job:)` / `RetouchRecovery` 照旧能扫到；
    /// - 每张照片自己的原始字节仍然由 UI 导入时建立的 `BatchPhoto.originalData` 持有，
    ///   目录里的 `original.bin` 只是本次批次的占位锚点，不是第二份素材库；
    /// - 写盘统一走 `saveJPEG(_:job:label:)`，`label` 固定 `"local"`，与单张流程完全一致，
    ///   版本历史和恢复逻辑不需要任何改动就能读到这批 revision；
    /// - 每次 `saveJPEG` 都生成新的 `local-<UUID>.jpg`，旧版本永远不会被覆盖，
    ///   每张照片当前用哪个 revision 由 `BatchPhoto.resultURL` 指向。
    private func ensureStoreJob(for job: BatchJob) throws {
        if storeJobID != nil && storeJobOwner == job.id { return }
        guard let first = job.photos.first else {
            throw RetouchBatchError.emptyJob
        }
        guard !first.originalData.isEmpty else {
            throw RetouchBatchError.storeUnavailable("批次里第一张照片没有原始字节")
        }
        do {
            let identifier = try store.newJob(originalData: first.originalData)
            storeJobID = identifier
            storeJobOwner = job.id
        } catch {
            storeJobID = nil
            storeJobOwner = nil
            throw RetouchBatchError.storeUnavailable(
                retouchBatchMessage(for: error, fallback: "目录写入失败")
            )
        }
    }

    // MARK: - Plumbing

    /// 所有入口共用的「同一时间只有一个批次在跑」逻辑。
    ///
    /// 起一个 MainActor 上的子任务来干活，把句柄存进 `runTask` 供 `cancel()` 用；
    /// 新的一次运行会先取消并等上一次真正退出，避免两条流水线交错改状态。
    private func runTracked(_ body: @escaping @MainActor () async -> Void) async {
        if let previous = runTask {
            previous.cancel()
            await previous.value
        }
        runGeneration += 1
        let generation = runGeneration
        let task: Task<Void, Never> = Task { await body() }
        runTask = task
        await task.value
        if runGeneration == generation {
            runTask = nil
        }
    }

    /// 串行的单张分析，跑在 detached 任务里，主线程只收结果。
    private func analyseOffMain(_ image: UIImage) async -> SkinAnalysis? {
        let pipelineBox = RetouchValueBox<RetouchPipeline>(pipeline)
        let imageBox = RetouchValueBox<UIImage>(image)
        let analysisBox = RetouchValueBox<SkinAnalysis?>(nil)
        await Task.detached(priority: .userInitiated) {
            analysisBox.value = pipelineBox.value.analysis(for: imageBox.value)
        }.value
        return analysisBox.value
    }

    private func progressValue() -> Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(completed) / Double(total))
    }

    private func finishRun(_ job: BatchJob, cancelled: Bool) {
        if cancelled {
            for photo in job.photos where photo.status == .analysing {
                photo.status = .pending
            }
            job.lastError = RetouchBatchError.cancelled.localizedDescription
        }
        completed = min(completed, total)
        job.progress = progressValue()
        isRunning = false
        job.isRunning = false
        phase = "已完成"
    }
}
