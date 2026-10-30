import Foundation

// MARK: - 错误

/// 预设存储的错误：全部走 `LocalizedError`，界面直接拿 `errorDescription` 弹中文提示。
enum LightroomPresetError: LocalizedError {
    /// 文件读不出来（不存在、没权限、编码不认识）
    case unreadable
    /// 不是可识别的 Lightroom 预设（没有 crs: 调整参数）
    case unsupported
    /// 落盘失败（建目录、写文件、编码）
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "预设文件读不出来，请确认文件还在并且有访问权限。"
        case .unsupported:
            return "这个文件不是可识别的 Lightroom 预设（没有找到任何 crs 调色参数）。"
        case .storage(let detail):
            return "预设存储失败：\(detail)"
        }
    }
}

// MARK: - 存储

/// Lightroom 预设的本地仓库。
///
/// 落盘策略：一个预设一个 `<uuid>.json`，字段就是 `LightroomPreset` 本身，
/// 用 `JSONEncoder` 的 `.prettyPrinted + .sortedKeys` 输出（便于人工排查、diff 稳定）。
/// 目录固定为 `Application Support/LightroomPresets`，不存在会自动创建。
///
/// 为什么不用一个大 JSON 数组：坏掉一份预设只丢一条（`all()` 遇到坏 JSON 直接跳过），
/// 不会让整个预设库打不开。
final class LightroomPresetStore {

    static let shared = LightroomPresetStore()

    private let fileManager: FileManager
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 预设目录（`Application Support/LightroomPresets`，测试时可以换成别的目录）。
    var directory: URL { root }

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory = directory {
            self.root = directory
        } else {
            // Application Support 在某些沙盒环境里可能取不到，退到临时目录保证还能用。
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.root = base.appendingPathComponent("LightroomPresets", isDirectory: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    // MARK: - 读取

    /// 内置预设是否已经导入过（一次性，进程内幂等）。
    private static var didSeedBundledPresets = false

    /// 全部预设：先把 App 包里的内置 xmp 导进来，再读仓库。
    func all() -> [LightroomPreset] {
        seedBundledPresetsIfNeeded()
        return loadAll()
    }

    /// 把 `Resources/ACRPresets/*.xmp`（文件夹引用，随包发布）导入到仓库。
    /// 同名跳过，所以用户删掉某个内置预设后不会再被塞回来。
    private func seedBundledPresetsIfNeeded() {
        guard !Self.didSeedBundledPresets else { return }
        Self.didSeedBundledPresets = true
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "xmp",
                                          subdirectory: "ACRPresets") else { return }
        var names = Set(loadAll().map { $0.name })
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let parsed = LightroomPresetParser.parse(contentsOf: url) else { continue }
            if names.contains(parsed.name) { continue }
            if (try? save(parsed)) != nil { names.insert(parsed.name) }
        }
    }

    /// 纯读仓库（不过内置种子），避免 `all()` 与种子互相递归。
    private func loadAll() -> [LightroomPreset] {
        let urls = (try? fileManager.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        var presets: [LightroomPreset] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            // 坏 JSON 直接跳过，不让一条脏数据毁掉整个列表。
            guard let data = try? Data(contentsOf: url),
                  let preset = try? decoder.decode(LightroomPreset.self, from: data) else { continue }
            presets.append(preset)
        }
        return presets.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order == .orderedSame {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return order == .orderedAscending
        }
    }

    func preset(id: UUID?) -> LightroomPreset? {
        guard let id = id else { return nil }
        let url = root.appendingPathComponent(id.uuidString + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LightroomPreset.self, from: data)
    }

    // MARK: - 写入

    /// 从磁盘导入一份预设：解析 → 同名去重 → 落盘 → 返回入库后的预设。
    ///
    /// 同名去重策略：保留旧预设的 id 并覆盖旧文件。
    /// 这样用户重复导入同一套预设不会在列表里出现两个「胶片暖阳」，
    /// 之前挂在这个 id 上的选择状态也不会丢。
    @discardableResult
    func importPreset(from url: URL) throws -> LightroomPreset {
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw LightroomPresetError.unreadable
        }
        guard let parsed = LightroomPresetParser.parse(contentsOf: url) else {
            throw LightroomPresetError.unsupported
        }
        var preset = parsed
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, let existing = all().first(where: { $0.name == name }) {
            preset.id = existing.id
        }
        try save(preset)
        return preset
    }

    /// 单个预设写成一个 `<uuid>.json`（原子写，写一半断电也不会留下半个 JSON）。
    func save(_ preset: LightroomPreset) throws {
        try ensureDirectory()
        let url = root.appendingPathComponent(preset.id.uuidString + ".json")
        do {
            let data = try encoder.encode(preset)
            try data.write(to: url, options: .atomic)
        } catch {
            throw LightroomPresetError.storage(error.localizedDescription)
        }
    }

    /// 删除一个预设。删不掉（文件不在、没权限）就当已经删了，不往上抛。
    func delete(_ id: UUID) {
        let url = root.appendingPathComponent(id.uuidString + ".json")
        try? fileManager.removeItem(at: url)
    }

    // MARK: - 目录

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw LightroomPresetError.storage("预设目录被同名文件占用：\(root.lastPathComponent)")
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw LightroomPresetError.storage(error.localizedDescription)
        }
    }
}
