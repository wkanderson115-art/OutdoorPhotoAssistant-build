import Foundation

/// 最小可用 ZIP 打包器（store 模式，method 0，不压缩）。
///
/// 为什么自己写：iOS 没有内置 zip API，本项目也不引入第三方库，
/// 这里按 PKWARE APPNOTE 手写字节布局即可。
///
/// 为什么只做 store：诊断包里是 JSON 文本 + 本来就已经是 JPEG 的图片，
/// 再 deflate 一次的收益很低；不压缩换来字节布局 100% 可读、零依赖、
/// macOS 访达和 Windows 资源管理器都能直接打开。
///
/// 关键约定：
/// - 所有多字节字段一律小端；
/// - 文件名按 UTF-8 编码并置通用标志位 0x0800，解压端据此还原中文名；
/// - 时间戳用固定合法值（2024-01-01 00:00:00），避免设备时区导致字段越界；
/// - 支持空文件（size 0、crc 0）。
struct ZipArchiveBuilder {

    /// 中央目录需要的一条记录：本地文件头已经按同样内容写进 `buffer`。
    private struct Entry {
        var nameBytes: [UInt8]
        var crc32: UInt32
        var size: UInt32
        var offset: UInt32
    }

    // 三个固定签名（小端写：50 4B 03 04 / 50 4B 01 02 / 50 4B 05 06）。
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let eocdSignature: UInt32 = 0x0605_4b50

    // 固定时间戳 2024-01-01 00:00:00。
    // DOS 时间格式：time = 时<<11 | 分<<5 | (秒/2)；date = (年-1980)<<9 | 月<<5 | 日。
    // 2024-01-01 是合法日期：(2024-1980)=44 → 44<<9 = 22528，月 1 → 1<<5 = 32，日 1 → 1，
    // 合计 22561 = 0x5821。
    private static let fixedDOSTime: UInt16 = 0
    private static let fixedDOSDate: UInt16 = (44 << 9) | (1 << 5) | 1

    private var buffer = Data()      // 连续区：每条目的本地头 + 文件数据
    private var entries: [Entry] = []
    private let crcTable: [UInt32]   // CRC32 查表，init 里建一次

    init() {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        self.crcTable = table
    }

    /// 追加一个文件。
    /// - Parameters:
    ///   - name: 条目名（建议纯 ASCII；中文按 UTF-8 写入并置标志位，不会乱码）
    ///   - data: 文件内容，允许为空
    mutating func addFile(name: String, data: Data) {
        let nameBytes = Array(name.utf8)
        let crc = crc32(of: data)
        // 诊断包远小于 4GB，用 clamping 保证超限时也不会崩，而不是强行截断计算出的值。
        let size = UInt32(clamping: data.count)
        let offset = UInt32(clamping: buffer.count)

        // ---- 本地文件头（30 字节 + 文件名 + 数据）----
        buffer.append(contentsOf: Self.le32(Self.localHeaderSignature))
        buffer.append(contentsOf: Self.le16(20))                  // version needed = 20（ZIP 2.0）
        buffer.append(contentsOf: Self.le16(0x0800))              // 通用标志：文件名 UTF-8
        buffer.append(contentsOf: Self.le16(0))                   // 压缩方法 0 = store
        buffer.append(contentsOf: Self.le16(Self.fixedDOSTime))   // 修改时间
        buffer.append(contentsOf: Self.le16(Self.fixedDOSDate))   // 修改日期
        buffer.append(contentsOf: Self.le32(crc))                 // CRC32
        buffer.append(contentsOf: Self.le32(size))                // 压缩后大小
        buffer.append(contentsOf: Self.le32(size))                // 原始大小
        buffer.append(contentsOf: Self.le16(UInt16(clamping: nameBytes.count)))
        buffer.append(contentsOf: Self.le16(0))                   // extra 长度
        buffer.append(contentsOf: nameBytes)
        buffer.append(data)

        entries.append(Entry(nameBytes: nameBytes, crc32: crc, size: size, offset: offset))
    }

    /// 生成完整 zip 字节：本地头区 + 中央目录 + EOCD。
    func finalize() -> Data {
        var output = buffer
        let centralOffset = UInt32(clamping: buffer.count)

        // ---- 中央目录（每条 46 字节 + 文件名）----
        for entry in entries {
            output.append(contentsOf: Self.le32(Self.centralSignature))
            output.append(contentsOf: Self.le16(20))      // version made by = 2.0
            output.append(contentsOf: Self.le16(20))      // version needed = 2.0
            output.append(contentsOf: Self.le16(0x0800))  // 通用标志：UTF-8
            output.append(contentsOf: Self.le16(0))       // 方法 0
            output.append(contentsOf: Self.le16(Self.fixedDOSTime))
            output.append(contentsOf: Self.le16(Self.fixedDOSDate))
            output.append(contentsOf: Self.le32(entry.crc32))
            output.append(contentsOf: Self.le32(entry.size))   // 压缩后大小
            output.append(contentsOf: Self.le32(entry.size))   // 原始大小
            output.append(contentsOf: Self.le16(UInt16(clamping: entry.nameBytes.count)))
            output.append(contentsOf: Self.le16(0))       // extra 长度
            output.append(contentsOf: Self.le16(0))       // 注释长度
            output.append(contentsOf: Self.le16(0))       // 起始磁盘号
            output.append(contentsOf: Self.le16(0))       // 内部属性
            output.append(contentsOf: Self.le32(0))       // 外部属性：普通文件
            output.append(contentsOf: Self.le32(entry.offset)) // 对应本地头偏移
            output.append(contentsOf: entry.nameBytes)
        }

        let centralSize = UInt32(clamping: output.count - buffer.count)

        // ---- EOCD（22 字节）----
        output.append(contentsOf: Self.le32(Self.eocdSignature))
        output.append(contentsOf: Self.le16(0))   // 本磁盘号
        output.append(contentsOf: Self.le16(0))   // 中央目录起始磁盘号
        output.append(contentsOf: Self.le16(UInt16(clamping: entries.count)))  // 本磁盘条目数
        output.append(contentsOf: Self.le16(UInt16(clamping: entries.count)))  // 总条目数
        output.append(contentsOf: Self.le32(centralSize))
        output.append(contentsOf: Self.le32(centralOffset))
        output.append(contentsOf: Self.le16(0))   // 注释长度
        return output
    }

    // MARK: - 内部工具

    /// CRC32（IEEE 802.3，反向多项式 0xEDB88320）。空数据自然得到 0。
    private func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let table = crcTable
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    @inline(__always) private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    @inline(__always) private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 24) & 0xFF)]
    }
}
