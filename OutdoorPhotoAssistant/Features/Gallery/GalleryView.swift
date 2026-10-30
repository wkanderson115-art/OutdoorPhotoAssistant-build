import SwiftUI
import UIKit
import PhotosUI
import ImageIO
import CryptoKit

struct GalleryView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var filter = "全部照片"
    @State private var pendingDelete: UUID?
    @State private var deleteError: String?
    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 12)]
    private var displayed: [AppPhotoRecord] {
        filter == "AI成片" ? library.records.filter { $0.versions.contains { $0.kind == "seedream" } } : library.records
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("你的照片").font(.title3.bold()).foregroundStyle(AppTheme.ink)
                        Text("\(library.records.count) 张原片 · \(library.records.filter { $0.versions.contains { $0.kind == "seedream" } }.count) 张 AI 成片")
                            .font(.subheadline).foregroundStyle(AppTheme.muted)
                    }
                    Picker("显示版本", selection: $filter) {
                        Text("全部照片").tag("全部照片")
                        Text("AI成片").tag("AI成片")
                        Text("原片").tag("原片")
                    }.pickerStyle(.segmented)
                    if displayed.isEmpty {
                        ContentUnavailableView(filter == "AI成片" ? "还没有 AI 成片" : "还没有照片", systemImage: "photo.on.rectangle", description: Text("拍照后会保存在这里。点开照片可查看原片、建议和精修版本。"))
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(displayed) { record in
                                NavigationLink { GalleryPhotoDetail(photoID: record.id) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        GalleryImage(photoID: record.id, assetID: filter == "原片" ? "original" : filter == "AI成片" ? record.versions.last(where: { $0.kind == "seedream" })?.id.uuidString ?? record.preferredAssetID : record.preferredAssetID, thumbnail: true, revision: record.revision)
                                            .frame(height: 160).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(record.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.ink).lineLimit(1)
                                        if record.jobs.contains(where: { $0.state == "running" }) {
                                            Label("处理中", systemImage: "hourglass").font(.caption2).foregroundStyle(AppTheme.muted)
                                        }
                                    }.padding(8).background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain)
                                .overlay(alignment: .topTrailing) {
                                    Button(role: .destructive) { pendingDelete = record.id } label: {
                                        Image(systemName: "trash").padding(10)
                                            .background(.regularMaterial, in: Circle())
                                    }.padding(8).accessibilityLabel("删除照片")
                                        .disabled(record.jobs.contains { $0.state == "running" })
                                }
                            }
                        }
                    }
                    Text("点开照片查看原片、精修版本与看图建议。").font(.caption).foregroundStyle(AppTheme.muted)
                    if let error = library.lastSaveError { Text(error).font(.footnote).foregroundStyle(.red) }
                    if let error = library.lastExportError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }.padding(16)
            }.background(AppTheme.paper).navigationTitle("我的图库")
                .toolbar { NavigationLink { CloudAPISettingsView() } label: { Image(systemName: "key") }.accessibilityLabel("云端服务") }
                .onAppear { library.loadIfNeeded() }
                .confirmationDialog("删除这张照片？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                    Button("删除原片及全部成片", role: .destructive) {
                        guard let id = pendingDelete else { return }
                        pendingDelete = nil
                        Task {
                            do { try await library.deletePhoto(id) }
                            catch { deleteError = error.localizedDescription }
                        }
                    }
                    Button("取消", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text("将永久删除App图库中的原片、所有版本和建议。已导出到系统相册的照片保留。")
                }
                .alert("删除失败", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                    Button("确定") { deleteError = nil }
                } message: { Text(deleteError ?? "") }
        }
    }
}

private struct GalleryImage: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let photoID: UUID
    let assetID: String
    let thumbnail: Bool
    let revision: Int
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                if thumbnail { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(uiImage: image).resizable().scaledToFit() }
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: assetID + String(revision)) {
            guard let record = library.records.first(where: { $0.id == photoID }),
                  let name = thumbnail ? record.thumbnailName(for: assetID) : record.fileName(for: assetID) else { return }
            let url = library.store.fileURL(photoID: photoID, name: name)
            let bytes = await Task.detached(priority: .utility) {
                try? PhotoImagePreparation.jpeg(from: url, maximumDimension: thumbnail ? 512 : 1600, quality: 0.88)
            }.value
            if !Task.isCancelled { image = bytes.flatMap { UIImage(data: $0) } }
        }
    }
}

@MainActor final class PhotoCloudWorkflow: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var phase = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var advice: StoredAdvice?
    @Published private(set) var generatedVersionID: String?
    private var task: Task<Void, Never>?

    func clearSelection() {
        guard !busy else { return }
        advice = nil; generatedVersionID = nil; errorMessage = nil; phase = ""
    }
    func analyze(record: AppPhotoRecord, sourceID: String, instruction: String, library: PhotoLibraryService, force: Bool = false, referenceJPEG: Data? = nil) {
        guard !busy else { return }
        if !force, let cached = record.advice.last(where: { $0.sourceAssetID == sourceID && $0.userInstruction == instruction && $0.policyVersion == NaturalPhotoPolicy.version }) {
            advice = cached; phase = "已载入已有建议，没有新增云端请求。"; errorMessage = nil; return
        }
        if !force, record.jobs.contains(where: { $0.provider == "DeepSeek" && $0.sourceAssetID == sourceID && $0.prompt == instruction && $0.state != "completed" }) {
            errorMessage = "上次分析未完成，无法确认是否已计费。不会自动重发；需要时请明确选择重新分析。"; return
        }
        let key: String
        do {
            key = try CloudHTTP.validatedKey(APIKeyStore.read(.deepseek), provider: "DeepSeek")
            guard instruction.count <= 2000 else { throw CloudAPIError.invalidInput("看图要求请控制在2000字以内。") }
        } catch { errorMessage = error.localizedDescription; return }
        busy = true; phase = "准备选中照片的分析副本…"; errorMessage = nil
        task = Task {
            var jobID: UUID?
            do {
                let jpeg = try await library.store.preparedUpload(photoID: record.id, assetID: sourceID, maximumDimension: 1280)
                try Task.checkCancellation()
                jobID = try await library.beginJob(photoID: record.id, provider: "DeepSeek", sourceAssetID: sourceID, prompt: instruction, model: CloudConfiguration.deepSeekModel)
                try Task.checkCancellation()
                phase = "上传至DeepSeek并生成看图建议…"
                let reply = try await DeepSeekClient().analyze(jpeg: jpeg, instruction: instruction, key: key, model: CloudConfiguration.deepSeekModel, referenceJPEG: referenceJPEG)
                let saved = StoredAdvice(id: UUID(), sourceAssetID: sourceID, userInstruction: instruction, policyVersion: NaturalPhotoPolicy.version, advice: reply.advice,
                                         createdAt: Date(), model: reply.model, usage: reply.usage)
                try await library.saveAdvice(photoID: record.id, value: saved)
                advice = saved
                if let jobID { await library.finishJob(photoID: record.id, jobID: jobID, state: "completed") }
                phase = "建议已保存，是否精修由你决定。"
            } catch {
                errorMessage = Self.message(error)
                if let jobID { await library.finishJob(photoID: record.id, jobID: jobID, state: "failed", message: errorMessage) }
                phase = "本次未继续调用Seedream。"
            }
            busy = false; task = nil
        }
    }
    func edit(record: AppPhotoRecord, sourceID: String, prompt: String, library: PhotoLibraryService, force: Bool = false, output: SeedreamOutputSettings = SeedreamOutputSettings()) {
        guard !busy else { return }
        let model = CloudConfiguration.seedreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = NaturalPhotoPolicy.editPrompt(prompt)
        let outputKey = output.fingerprint
        if !force, let cached = record.versions.last(where: { $0.kind == "seedream" && $0.sourceAssetID == sourceID && $0.prompt == effectivePrompt && $0.model == model && ($0.outputKey == outputKey || $0.outputKey == nil) }) {
            generatedVersionID = cached.id.uuidString; phase = "已有相同要求的修图版本，没有新增云端请求。"; errorMessage = nil; return
        }
        if !force, let pending = record.jobs.last(where: { $0.provider == "Seedream" && $0.sourceAssetID == sourceID && $0.prompt == effectivePrompt && $0.model == model && ($0.outputKey == outputKey || $0.outputKey == nil) && $0.state != "completed" }) {
            if pending.transport == "direct-v1", pending.resultURL != nil {
                retryDownload(record: record, job: pending, library: library)
            } else {
                errorMessage = "上次请求没有可下载的直连结果，无法确认是否已计费。请检查平台记录；确需再修时选择新建任务。"
            }
            return
        }
        let key: String
        do {
            key = try CloudHTTP.validatedKey(APIKeyStore.read(.seedream), provider: "Seedream / 火山方舟")
            try CloudHTTP.checkModel(model)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudAPIError.invalidInput("请先填写修图要求或采用DeepSeek建议。") }
        } catch { errorMessage = error.localizedDescription; return }
        busy = true; phase = "准备选中照片的修图副本…"; errorMessage = nil
        task = Task {
            var jobID: UUID?
            do {
                let jpeg = try await library.store.preparedUpload(photoID: record.id, assetID: sourceID, maximumDimension: 3072)
                try Task.checkCancellation()
                jobID = try await library.beginJob(photoID: record.id, provider: "Seedream", sourceAssetID: sourceID, prompt: effectivePrompt, model: model)
                try Task.checkCancellation()
                phase = "上传至Seedream并编辑照片…"
                let client = SeedreamClient()
                let reply = try await client.edit(jpeg: jpeg, prompt: effectivePrompt, key: key, model: model, output: output)
                guard let id = jobID else { throw CloudAPIError.invalidResponse }
                // Persist the provider's result URL BEFORE download/cancellation; never resend generation to recover a download.
                try await library.saveJobResult(photoID: record.id, jobID: id, url: reply.imageURL.absoluteString, requestID: reply.requestID)
                try Task.checkCancellation()
                phase = "下载并保存修图结果…"
                let data = try await client.download(reply.imageURL)
                let version = try await library.saveGenerated(photoID: record.id, sourceAssetID: sourceID, data: data, prompt: effectivePrompt, model: model, cloudJobID: id)
                generatedVersionID = version.id.uuidString
                await library.finishJob(photoID: record.id, jobID: id, state: "completed")
                phase = "AI修图已存入图库，原片和之前版本均保留。"
            } catch {
                errorMessage = Self.message(error)
                if let jobID { await library.finishJob(photoID: record.id, jobID: jobID, state: "failed", message: errorMessage) }
                phase = "没有自动重试；原片仍保留。"
            }
            busy = false; task = nil
        }
    }
    func retryDownload(record: AppPhotoRecord, job: PhotoCloudJob, library: PhotoLibraryService) {
        guard !busy, job.transport == "direct-v1", let resultURL = job.resultURL, let prompt = job.prompt, let model = job.model else { return }
        busy = true; phase = "只下载已有结果，不重新生成…"; errorMessage = nil
        task = Task {
            var resumed = false
            do {
                let url = try CloudHTTP.safeImageURL(resultURL)
                try await library.resumeDownload(photoID: record.id, jobID: job.id)
                resumed = true
                // Download does not read or attach API keys; it also works after keys are deleted.
                let data = try await SeedreamClient().download(url)
                let version = try await library.saveGenerated(photoID: record.id, sourceAssetID: job.sourceAssetID, data: data, prompt: prompt, model: model, cloudJobID: job.id)
                generatedVersionID = version.id.uuidString
                await library.finishJob(photoID: record.id, jobID: job.id, state: "completed")
                phase = "已有结果已保存，没有重新调用模型。"
            } catch {
                errorMessage = "下载未完成：" + error.localizedDescription + " 本次没有重新生成。"
                if resumed { await library.finishJob(photoID: record.id, jobID: job.id, state: "failed", message: errorMessage) }
            }
            busy = false; task = nil
        }
    }
    func cancel() {
        task?.cancel()
        phase = "正在停止等待。已提交的云端请求可能仍会计费。"
    }
    private static func message(_ error: Error) -> String {
        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
            return "已停止等待。若请求已发出，平台可能仍执行并计费；不会自动重试。"
        }
        if let network = error as? URLError {
            let reason: String
            switch network.code {
            case .timedOut: reason = "等待接口响应超时；可能仍在排队或处理。"
            case .notConnectedToInternet: reason = "当前设备没有可用网络连接。"
            case .cannotFindHost, .dnsLookupFailed: reason = "无法解析接口域名，请检查网络或DNS。"
            case .cannotConnectToHost: reason = "无法建立接口连接，请检查网络线路。"
            case .networkConnectionLost: reason = "传输过程中网络连接中断。"
            case .secureConnectionFailed, .serverCertificateUntrusted: reason = "HTTPS安全连接失败，请检查系统时间和网络代理。"
            default: reason = "网络请求失败，代码：" + String(network.errorCode) + "。"
            }
            return reason + " 不会自动重复付费请求；若已提交，请核对平台用量后再手动重试。"
        }
        return error.localizedDescription + " 请求若已提交但响应中断，平台仍可能计费；不会自动重发。"
    }
}

private struct GalleryPhotoDetail: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let photoID: UUID
    @StateObject private var workflow = PhotoCloudWorkflow()
    @AppStorage("cloudUseDeepSeekFirst") private var defaultDeepSeekFirst = true
    @Environment(\.dismiss) private var dismiss
    @State private var stage = "选择"
    @State private var compareResult = false
    @State private var configured = false
    @State private var sourceID = "original"
    @State private var useDeepSeek = true
    @State private var showAdviceRequest = false
    @State private var adviceGoal = ""
    @State private var improvement = "让AI判断"
    @State private var editDegree = "适中"
    @State private var allowCrop = false
    @State private var allowCleanup = false
    @State private var contentScope = ""
    @State private var referenceItem: PhotosPickerItem?
    @State private var referenceJPEG: Data?
    @State private var referenceLoading = false
    @State private var referenceError: String?
    @State private var selectedSteps = Set<Int>()
    @State private var planError: String?
    @State private var adviceFormError: String?
    @State private var adviceStandard = ""
    @State private var advicePreserve = "先识别照片主体；保留真实主体、结构、文字、材质、比例与现场光线。有可见人物时再额外保护身份、五官和肤色。"
    @State private var adviceSourceID = "original"
    @State private var adviceForce = false
    @State private var retouchStyle = "按照片诊断"
    private var retouchPlans: [(String, String)] { RetouchReferenceBank.cards.map { ($0.name, $0.method) } }
    @State private var requestText = "请先识别照片类别与主体，再按本图可见问题提出精修方案；避免过度 HDR、虚构细节或改变真实结构。"
    @State private var editPrompt = ""
    @State private var adoptedAdviceID: UUID?
    @State private var exportStatus: String?
    @State private var seedreamOutput = SeedreamOutputSettings()
    @State private var showingOutputSheet = false
    private var record: AppPhotoRecord? { library.records.first { $0.id == photoID } }
    private var activeAdvice: StoredAdvice? {
        if let value = workflow.advice, value.sourceAssetID == sourceID, value.policyVersion == NaturalPhotoPolicy.version { return value }
        return record?.advice.last(where: { $0.sourceAssetID == sourceID && $0.policyVersion == NaturalPhotoPolicy.version })
    }
    private var isBusy: Bool { workflow.busy || (record?.jobs.contains(where: { $0.state == "running" }) ?? false) }
    private var matchingResult: PhotoVersion? {
        record?.versions.last { $0.kind == "seedream" && $0.sourceAssetID == sourceID }
    }
    private var displayAssetID: String { compareResult ? matchingResult?.id.uuidString ?? sourceID : sourceID }
    private var pageTitle: String { stage == "建议" ? "看图建议" : stage == "精修" ? "照片精修" : "这张照片怎么处理" }
    private var adviceReady: Bool { !useDeepSeek || (activeAdvice?.id == adoptedAdviceID && !editPrompt.isEmpty) }

    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 16) {
                    Text(stage == "建议" ? "第一步 · 看图建议" : stage == "精修" ? "第二步 · 确认精修" : "选择照片版本")
                        .font(.headline).foregroundStyle(AppTheme.ink)
                    Text(stage == "建议" ? "看完建议再决定是否生成成片" : stage == "精修" ? "确认修图要求后才会发起处理" : "选择要查看或处理的版本")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                    GalleryImage(photoID: photoID, assetID: displayAssetID, thumbnail: false, revision: record.revision)
                        .frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 18))
                    if stage == "精修", matchingResult != nil {
                        Picker("原片与AI成片对比", selection: $compareResult) {
                            Text("上传源").tag(false); Text("AI成片").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    versionPicker(record)
                    if isBusy || workflow.errorMessage != nil { taskStatus(record) }
                    if stage == "选择" && !isBusy { cloudControls(record) }
                    if stage == "建议", let value = activeAdvice { adviceCard(value) }
                    if stage == "精修" && !isBusy { editControls(record) }
                    if !isBusy && workflow.errorMessage == nil { taskStatus(record) }
                    Button("导出当前版本到系统相册") {
                        Task {
                            do { try await library.export(photoID: photoID, assetID: displayAssetID); exportStatus = "已导出到系统相册。" }
                            catch { exportStatus = error.localizedDescription }
                        }
                    }.buttonStyle(.bordered).disabled(isBusy)
                    if let exportStatus { Text(exportStatus).font(.footnote).foregroundStyle(.secondary) }
                }.padding(16)
            } else { ContentUnavailableView("照片暂不可用", systemImage: "photo") }
        }.background(AppTheme.paper).navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { NavigationLink { CloudAPISettingsView() } label: { Image(systemName: "key") } }
            .sheet(isPresented: $showAdviceRequest) { adviceRequestSheet }
            .sheet(isPresented: $showingOutputSheet) { seedreamOutputSheet }
            .task(id: referenceItem) {
                referenceJPEG = nil; referenceError = nil
                guard let item = referenceItem else { referenceLoading = false; return }
                referenceLoading = true
                defer { if referenceItem == item { referenceLoading = false } }
                do {
                    guard let raw = try await item.loadTransferable(type: Data.self),
                          let source = CGImageSourceCreateWithData(raw as CFData, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1280] as CFDictionary),
                          let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9), jpeg.count <= 15 * 1024 * 1024 else { throw CloudAPIError.invalidImage }
                    guard !Task.isCancelled, referenceItem == item else { return }
                    referenceJPEG = jpeg
                } catch { if !Task.isCancelled && referenceItem == item { referenceError = "参考图无法读取，请移除或重新选择。" } }
            }
            .onAppear { if !configured { useDeepSeek = defaultDeepSeekFirst; adviceStandard = standardForStyle(retouchStyle); configured = true } }
            .onChange(of: retouchStyle) { _, value in
                adviceStandard = standardForStyle(value)
            }
            .onChange(of: useDeepSeek) { _, enabled in
                if !enabled && editPrompt.isEmpty { editPrompt = requestText }
            }
            .onChange(of: sourceID) { _, _ in
                workflow.clearSelection(); adoptedAdviceID = nil; editPrompt = ""; exportStatus = nil; stage = "选择"; compareResult = false
            }
            .onChange(of: workflow.advice?.id) { _, id in if id != nil { stage = "建议" } }
            .onChange(of: workflow.generatedVersionID) { _, id in if id != nil { stage = "精修"; compareResult = true } }
            .onChange(of: requestText) { _, _ in adoptedAdviceID = nil }
    }
    private func versionPicker(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("上传源", selection: $sourceID) {
                Text("原片").tag("original")
                ForEach(record.versions) { Text($0.title).tag($0.id.uuidString) }
            }.disabled(isBusy)
        }.padding(10).background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 12))
    }
    private func cloudControls(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("精修方案", selection: $retouchStyle) {
                ForEach(retouchPlans, id: \.0) { plan in Text(plan.0).tag(plan.0) }
            }.onChange(of: retouchStyle) { _, value in
                let plan = retouchPlans.first { $0.0 == value }?.1 ?? ""
                requestText = "精修分类：" + value + "。" + plan + " 请先识别本图主体再提出具体方案；保留真实主体、结构、文字、材质和比例，有人物时额外保护身份与五官。"
                editPrompt = ""; adoptedAdviceID = nil
            }
            DisclosureGroup("本分类的精修方法与来源") {
                let card = RetouchReferenceBank.cards.first { $0.name == retouchStyle } ?? RetouchReferenceBank.cards[0]
                Text(card.method).font(.footnote)
                Text("公开流程的编辑归纳，非摄影师原版提示词或效果保证。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(card.sources, id: \.self) { source in
                    if let url = URL(string: source) { Link("查看公开教程 · " + (url.host ?? "来源"), destination: url) }
                }
            }
            Toggle("先让 DeepSeek 看图建议", isOn: $useDeepSeek).tint(AppTheme.mint).disabled(isBusy)
            TextField("你想保留或改善什么？", text: $requestText, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(isBusy)
            if useDeepSeek {
                Button("填写要求并获取 DeepSeek 建议") {
                    adviceSourceID = sourceID; adviceForce = false; showAdviceRequest = true
                }.buttonStyle(AppActionStyle()).disabled(isBusy)
                Text("点击才上传照片并调用DeepSeek。已有相同要求的建议会直接复用。")
                    .font(.caption).foregroundStyle(.secondary)
                if activeAdvice != nil || record.jobs.contains(where: { $0.provider == "DeepSeek" && $0.sourceAssetID == sourceID && $0.state != "completed" }) {
                    Button("重新看图分析（另计一次）") {
                        adviceSourceID = sourceID; adviceForce = true; showAdviceRequest = true
                    }.font(.caption).disabled(isBusy)
                }
            }
            Button("跳过建议，直接填写修图要求") {
                useDeepSeek = false
                if editPrompt.isEmpty { editPrompt = requestText }
                stage = "精修"
            }.buttonStyle(AppActionStyle(primary: false)).disabled(isBusy)
        }.appCard()
    }
    private var styleBoundary: String {
        NaturalPhotoPolicy.styleBoundary(strength: editDegree, allowCrop: allowCrop, allowCleanup: allowCleanup, scope: contentScope)
    }
    private var contentPermissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("风格可以明显，人物与场景仍保持原貌。内容改动只允许下面单独确认的操作。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("允许轻微裁切", isOn: $allowCrop)
            Toggle("允许移除指定杂物", isOn: $allowCleanup)
            if allowCrop || allowCleanup {
                TextField("必须写明范围，例如仅裁掉底部空白；仅移除右下角纸屑", text: $contentScope, axis: .vertical)
                Text("未填写范围时不允许内容改动。不能更换人物、天空、天气或背景。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var finalSeedreamPrompt: String { styleBoundary + "\n已确认修改要求：\n" + editPrompt }
    private var composedAdviceRequest: String {
        "精修分类：" + retouchStyle + "。\n期望成片：" + (adviceGoal.isEmpty ? retouchStyle : adviceGoal.trimmingCharacters(in: .whitespacesAndNewlines))
        + "\n改善重点：" + improvement + "；风格强度：" + editDegree + "\n" + styleBoundary
        + "\n验收标准：" + adviceStandard.trimmingCharacters(in: .whitespacesAndNewlines)
        + "\n必须保留：" + advicePreserve.trimmingCharacters(in: .whitespacesAndNewlines)
        + "\n补充要求：" + requestText
        + (referenceJPEG.map { "\n风格参考图指纹：" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "")
    }
    private var adviceFormProblem: String? {
        if referenceLoading { return "参考图仍在处理中，请稍候。" }
        if referenceItem != nil && referenceJPEG == nil {
            return "参考图读取失败或尚未完成，请移除后重选。"
        }
        if adviceStandard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写至少一条验收标准。"
        }
        if (allowCrop || allowCleanup)
            && contentScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "已允许裁切或移除杂物，请填写具体修改范围。"
        }
        if composedAdviceRequest.count > 2000 {
            return "合计要求超过 2000 字，请缩短后再提交。"
        }
        return nil
    }
    private var adviceRequestSheet: some View {
        NavigationStack {
            Form {
                Section("本次上传的照片") {
                    if let record {
                        GalleryImage(photoID: photoID, assetID: adviceSourceID, thumbnail: true, revision: record.revision)
                            .frame(height: 180).clipped()
                    }
                    LabeledContent("精修分类", value: retouchStyle)
                    Text("上传当前选中版本；如添加风格参考图，也会一并上传供DeepSeek分析。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("选择目标") {
                    Picker("成片风格", selection: $retouchStyle) {
                        ForEach(retouchPlans, id: \.0) { plan in Text(plan.0).tag(plan.0) }
                    }
                    Picker("改善重点", selection: $improvement) {
                        ForEach(["让AI判断", "主体曝光", "色彩与白平衡", "高光与阴影", "建筑线条", "商品材质", "天空与地景", "文字清晰", "动物毛发", "肤色与皮肤", "背景", "构图"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("风格强度", selection: $editDegree) {
                        ForEach(["轻微", "适中", "明显"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("内容改动 · 默认关闭") { contentPermissions }
                Section("补充一句话 · 可不填") {
                    TextField("例如：自然的杂志人像，人物突出，背景色彩克制", text: $adviceGoal, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("按什么标准验收？") {
                    TextField("例如：肤色不偏黄；放大仍有毛孔；眼睛和衣服清楚；背景不过曝", text: $adviceStandard, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("风格参考图 · 可不选") {
                    PhotosPicker(selection: $referenceItem, matching: .images) { Label("选择色彩或光影参考图", systemImage: "photo.badge.plus") }
                    if referenceLoading { ProgressView("处理参考图…") }
                    if let bytes = referenceJPEG, let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 140)
                    }
                    if referenceItem != nil {
                        Button("移除参考图", role: .destructive) { referenceItem = nil; referenceJPEG = nil; referenceError = nil }
                    }
                    if let referenceError { Text(referenceError).foregroundStyle(.red) }
                    Text("只参考色彩、光影与质感，不复制人物、服装或背景。参考图仅在本次页面内暂存，生成建议保存后不会保留参考图原文件。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("哪些地方不能改？") {
                    TextField("填写保留内容或禁止修改范围", text: $advicePreserve, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Text("以上要求与这张照片会在同一次请求中交给DeepSeek。确认只获取建议，不会调用Seedream。")
                    Text(adviceForce ? "本次为重新分析，可能另计一次费用。" : "已有完全相同要求的建议会优先复用。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("合计要求：\(composedAdviceRequest.count)/2000字")
                        .foregroundStyle(composedAdviceRequest.count > 2000 ? .red : .secondary)
                    if let adviceFormError {
                        Label(adviceFormError, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button("确认要求并上传分析") {
                        adviceFormError = nil
                        if let problem = adviceFormProblem {
                            adviceFormError = problem
                            return
                        }
                        guard let record else {
                            adviceFormError = "照片记录暂不可用，请关闭后重新进入。"
                            return
                        }
                        guard !isBusy else {
                            adviceFormError = "已有任务正在处理，请等待完成后再提交。"
                            return
                        }
                        let instruction = composedAdviceRequest
                        let selectedSource = adviceSourceID
                        let force = adviceForce
                        let reference = referenceJPEG
                        adoptedAdviceID = nil
                        showAdviceRequest = false
                        workflow.analyze(record: record, sourceID: selectedSource, instruction: instruction, library: library, force: force, referenceJPEG: reference)
                        if let advice = workflow.advice, advice.sourceAssetID == selectedSource, advice.userInstruction == instruction { stage = "建议" }
                    }
                    .disabled(isBusy || referenceLoading)
                }
            }
            .navigationTitle("告诉DeepSeek你的目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showAdviceRequest = false } } }
            .onAppear {
                adviceFormError = nil
                if adviceStandard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    adviceStandard = standardForStyle(retouchStyle)
                }
            }
            .onChange(of: adviceStandard) { _, _ in adviceFormError = nil }
            .onChange(of: contentScope) { _, _ in adviceFormError = nil }
            .onChange(of: referenceItem) { _, _ in adviceFormError = nil }
        }
    }
    private func adviceCard(_ value: StoredAdvice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DeepSeek 建议").font(.title3.bold())
            Text("我理解你的目标：" + (value.advice.understanding ?? value.userInstruction.components(separatedBy: "\n风格参考图指纹：")[0])).font(.subheadline)
            Button("理解不对，修改需求") { adviceSourceID = sourceID; adviceForce = false; showAdviceRequest = true }
            let steps = value.advice.editSteps ?? value.advice.recommendations
            Text("准备修改的内容 · 可取消不需要的项").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Toggle(step, isOn: Binding(get: { selectedSteps.contains(index) }, set: { enabled in
                    if enabled { selectedSteps.insert(index) } else { selectedSteps.remove(index) }
                }))
            }
            if let planError { Text(planError).foregroundStyle(.red) }
            Text("识别场景：" + value.advice.scene).font(.subheadline).foregroundStyle(AppTheme.muted)
            Text("分析时要求：" + value.userInstruction.components(separatedBy: "\n风格参考图指纹：")[0]).font(.caption).foregroundStyle(.secondary)
            if value.advice.issues.isEmpty { Text("照片没有明显问题，可以直接保留原片。").font(.subheadline) }
            adviceList("画面优点", value.advice.strengths)
            adviceList("可改善的地方", value.advice.issues)
            adviceList("修图建议", value.advice.recommendations)
            adviceList("保留内容", value.advice.preserve)
            Text(value.advice.editPrompt).font(.subheadline).textSelection(.enabled)
            Button("采用建议，编辑修图要求") {
                let steps = value.advice.editSteps ?? value.advice.recommendations
                let selected = steps.enumerated().filter { selectedSteps.contains($0.offset) }.map { $0.element }
                guard !selected.isEmpty else { planError = "未选择修改项，可以保留原片；要修图请至少选择一项。"; return }
                editPrompt = "按以下已确认清单执行，未选中的调整不要进行：\n" + selected.joined(separator: "\n") + "\n保留：" + value.advice.preserve.joined(separator: "；")
                planError = nil
                adoptedAdviceID = value.id
                stage = "精修"
            }.buttonStyle(AppActionStyle()).disabled(isBusy)
            Button("暂不修图，返回图库") { dismiss() }.buttonStyle(AppActionStyle(primary: false))
            Text("采用建议不会调用Seedream。下一步仍由你决定是否生成。")
                .font(.caption).foregroundStyle(AppTheme.muted)
        }.appCard()
            .onAppear { selectedSteps = Set((value.advice.editSteps ?? value.advice.recommendations).indices); planError = nil }
    }
    private func adviceList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text("• " + item).font(.subheadline) }
        }
    }

    private func standardForStyle(_ style: String) -> String {
        switch style {
        case "建筑空间": return "垂直线与透视自然；门窗、招牌和室内结构不变；材质真实；窗景高光有层次。"
        case "风景自然": return "地形、天空、云层和植被真实；高光与暗部有层次；不换天空；色彩不过饱和。"
        case "商品材质": return "商品外形、商标、文字和颜色准确；材质与反射自然；背景干净；不重绘产品。"
        case "美食真实": return "食物颜色、形状、份量和摆盘真实；高光自然；不添加食材；餐具反射不过曝。"
        case "宠物动物": return "毛色、花纹、胡须、眼睛和身体比例真实；毛发有层次；不改变品种或生成毛发。"
        case "文档翻拍": return "文字与线条准确；透视端正；纸张色偏和阴影受控；不修改、生成或删除文字。"
        case "黑白肖像": return "黑白灰阶分明；皮肤与衣物分离；亮暗保留细节。"
        case "复古胶片": return "胶片色彩克制；黑位不蒙灰；颗粒不遮主体细节；真实颜色不脏。"
        case "夜景人像", "夜景场景": return "保留夜间氛围和彩灯；点光源不过曝；暗部不抬成白天；主体细节真实。"
        default: return "主体结构与真实颜色保持；曝光、白平衡和层次自然；清晰但不过锐；不虚构内容。"
        }
    }
    private func editControls(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修图要求").font(.headline)
            Text("基于原片的风格精修：色彩和质感可明显改善，人物与场景保持原貌。")
                .font(.caption).foregroundStyle(AppTheme.muted)
            Picker("风格强度", selection: $editDegree) {
                ForEach(["轻微", "适中", "明显"], id: \.self) { Text($0).tag($0) }
            }.disabled(isBusy)
            contentPermissions.disabled(isBusy)
            TextEditor(text: $editPrompt).frame(minHeight: 135)
                .padding(8).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .disabled(isBusy)
            if editPrompt.isEmpty && !useDeepSeek {
                Button("把我的要求填入修图框") { editPrompt = requestText }.font(.subheadline)
            }
            // 输出规格分类按钮
            Button {
                showingOutputSheet = true
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("输出规格")
                    Spacer()
                    Text(seedreamOutput.summary)
                        .font(.caption).foregroundStyle(AppTheme.muted)
                    Image(systemName: "chevron.right").font(.caption2)
                }.padding(.horizontal, 14).frame(minHeight: 44)
                .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(isBusy)
            Button("用 Seedream 修这张") {
                workflow.edit(record: record, sourceID: sourceID, prompt: finalSeedreamPrompt, library: library, output: seedreamOutput)
            }.buttonStyle(AppActionStyle())
                .disabled(isBusy || editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !adviceReady || ((allowCrop || allowCleanup) && contentScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || finalSeedreamPrompt.count > 4000)
            Button("重新选择处理方式") { stage = "选择" }.buttonStyle(AppActionStyle(primary: false))
            Text("点击才上传并进行云端处理；不会自动逐张修图。相同结果优先复用，原片始终保留。")
                .font(.caption).foregroundStyle(.secondary)
            if let resultID = workflow.generatedVersionID {
                Button("查看刚才的AI修图版本") { sourceID = resultID }.buttonStyle(.bordered).disabled(isBusy)
            }
            DisclosureGroup("需要另一个结果或原任务无法取回？") {
                Button("新建任务重新生成（可能再次计费）") {
                    workflow.edit(record: record, sourceID: sourceID, prompt: finalSeedreamPrompt, library: library, force: true, output: seedreamOutput)
                }.disabled(isBusy || !adviceReady || editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ((allowCrop || allowCleanup) && contentScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || finalSeedreamPrompt.count > 4000)
            }.font(.caption)
        }
    }
    private func taskStatus(_ record: AppPhotoRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isBusy {
                VStack(alignment: .leading, spacing: 12) {
                    Text("正在处理，请稍候…").font(.title3.bold())
                    ProgressView(workflow.phase.isEmpty ? "此照片的云端任务进行中" : workflow.phase)
                    Text("完成后存入本张照片的版本记录，不会处理其他照片。")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                }.appCard(tinted: true)
            }
            else if !workflow.phase.isEmpty { Text(workflow.phase).font(.footnote) }
            if workflow.busy { Button("停止等待") { workflow.cancel() }.buttonStyle(AppActionStyle(primary: false)) }
            if let error = workflow.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            if let pending = record.jobs.last(where: { $0.transport == "direct-v1" && $0.provider == "Seedream" && $0.resultURL != nil && $0.state != "running" && $0.state != "completed" }) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("可以继续下载结果").font(.title3.bold())
                    Text("已保存平台返回的图片链接，只重试下载，不重新生图。链接可能过期，请及时保存。")
                        .font(.subheadline).foregroundStyle(AppTheme.muted)
                    Button("仅重试下载") { workflow.retryDownload(record: record, job: pending, library: library) }
                        .buttonStyle(AppActionStyle()).disabled(isBusy)
                }.appCard()
            }
            if !record.jobs.isEmpty {
                DisclosureGroup("这张照片的云端任务记录") {
                    ForEach(record.jobs.suffix(5).reversed()) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.provider + " · " + job.stateTitle).font(.caption.bold())
                            Text(job.startedAt.formatted()).font(.caption2)
                            if let message = job.message { Text(message).font(.caption2).foregroundStyle(.secondary) }

                        }.padding(.vertical, 3)
                    }
                }
            }
        }
    }
    private var seedreamOutputSheet: some View {
        NavigationStack {
            Form {
                let caps = SeedreamOutputSettings.capabilities(for: CloudConfiguration.seedreamModel)
                Section("画质") {
                    ForEach(SeedreamResolution.allCases) { res in
                        let supported = caps.resolutions.contains(res)
                        Button {
                            if supported { seedreamOutput.resolution = res }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(res.title).foregroundStyle(supported ? .primary : .secondary)
                                    Text(res.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if seedreamOutput.resolution == res { Image(systemName: "checkmark").foregroundStyle(.mint) }
                                if !supported { Text("不支持").font(.caption2).foregroundStyle(.red) }
                            }
                        }.buttonStyle(.plain).disabled(!supported)
                    }
                }
                Section("格式") {
                    ForEach(SeedreamFormat.allCases) { fmt in
                        let supported = caps.formats.contains(fmt)
                        Button {
                            if supported { seedreamOutput.format = fmt }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(fmt.title).foregroundStyle(supported ? .primary : .secondary)
                                    Text(fmt.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if seedreamOutput.format == fmt { Image(systemName: "checkmark").foregroundStyle(.mint) }
                                if !supported { Text("不支持").font(.caption2).foregroundStyle(.red) }
                            }
                        }.buttonStyle(.plain).disabled(!supported)
                    }
                }
                Section("水印") {
                    Toggle("保留 AI 水印（推荐）", isOn: $seedreamOutput.watermark)
                    if !seedreamOutput.watermark {
                        Text("关闭水印后成片不再标注AI生成，请自行标识。").font(.caption).foregroundStyle(.orange)
                    }
                }
                Section { Text("当前模型：\(CloudConfiguration.seedreamModel)") .font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("输出规格").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { showingOutputSheet = false } }
        }.presentationDetents([.medium])
    }
}
