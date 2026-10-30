import Foundation
import ImageIO
import UniformTypeIdentifiers

// UIKit / Core Image are only needed by the exporter itself. The pure value
// logic (naming, CRC32, the ZIP writer, the manifest JSON/CSV helpers) stays
// outside the guard so `tests/delivery/main.swift` can compile this file with
// Foundation only and exercise the real code on macOS CI instead of a copy.
#if canImport(UIKit)
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

// MARK: - Errors

enum RetouchDeliveryError: LocalizedError {
    case noApprovedPhotos
    case cannotCreateDirectory
    case encodeFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noApprovedPhotos:
            return "没有可交付的照片：请先在审片页至少通过一张"
        case .cannotCreateDirectory:
            return "无法创建交付目录"
        case .encodeFailed(let name):
            return "编码失败：\(name)"
        case .writeFailed(let name):
            return "写入失败：\(name)"
        }
    }
}

// MARK: - CRC32 (IEEE 802.3, polynomial 0xEDB88320 — the ZIP/PNG checksum)

/// Table-driven CRC-32. Cached in a static table so a full-resolution file costs
/// one table lookup per byte.
enum DeliveryCRC32 {
    /// 256-entry lookup table for the reflected polynomial 0xEDB88320.
    static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        var index = 0
        while index < 256 {
            var value = UInt32(index)
            var bit = 0
            while bit < 8 {
                if value & 1 == 1 {
                    value = 0xEDB8_8320 ^ (value >> 1)
                } else {
                    value = value >> 1
                }
                bit += 1
            }
            table[index] = value
            index += 1
        }
        return table
    }()

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let slot = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[slot] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let slot = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[slot] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Eight uppercase hex digits, the form a delivery manifest / QC sheet shows.
    static func hex(_ value: UInt32) -> String {
        String(format: "%08X", value)
    }
}

/// Incremental CRC-32 so a file can be checksummed in chunks (and so the ZIP
/// writer never has to hold a whole photo in memory).
struct DeliveryCRC32Stream {
    private var state: UInt32 = 0xFFFF_FFFF

    init() {}

    mutating func update(_ data: Data) {
        for byte in data {
            let slot = Int((state ^ UInt32(byte)) & 0xFF)
            state = DeliveryCRC32.table[slot] ^ (state >> 8)
        }
    }

    mutating func update(_ bytes: [UInt8]) {
        for byte in bytes {
            let slot = Int((state ^ UInt32(byte)) & 0xFF)
            state = DeliveryCRC32.table[slot] ^ (state >> 8)
        }
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
}

// MARK: - File naming

/// `\(prefix)_\(yyyyMMdd)_\(index4).\(ext)` — one shared, fixed-locale
/// formatter, so a delivery is reproducible and sortable in Finder.
enum DeliveryNaming {
    /// Shared formatter: a fixed POSIX locale keeps yyyyMMdd ASCII, the current
    /// time zone keeps the stamp equal to the date the customer sees.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    static func dateStamp(_ date: Date = Date()) -> String {
        dateFormatter.string(from: date)
    }

    /// Zero-padded to four digits; a fifth digit is never truncated. Manual
    /// padding instead of `String(format: "%04d", Int)` avoids the 64-bit
    /// `%d`-versus-`Int` mismatch.
    static func paddedIndex(_ index: Int) -> String {
        let digits = String(max(0, index))
        guard digits.count < 4 else { return digits }
        return String(repeating: "0", count: 4 - digits.count) + digits
    }

    static func fileName(prefix: String, date: Date, index: Int, fileExtension: String) -> String {
        let cleanPrefix = sanitizedPrefix(prefix)
        let cleanExtension = fileExtension.isEmpty ? "jpg" : fileExtension
        return "\(cleanPrefix)_\(dateStamp(date))_\(paddedIndex(index)).\(cleanExtension)"
    }

    /// Strips every character that would break a file name or a ZIP path, then
    /// falls back to "OPA" so a blank prefix can never produce "_20260101_0001.jpg".
    static func sanitizedPrefix(_ raw: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|",
                                         " ", "\t", "\n", "\r"]
        let cleaned = String(raw.filter { !forbidden.contains($0) })
        let limited = String(cleaned.prefix(24))
        return limited.isEmpty ? "OPA" : limited
    }

    /// Path of `file` relative to `root`, "/"-separated — this is what goes into
    /// the ZIP entry name and the manifest `fileName` field.
    static func relativePath(of file: URL, root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

// MARK: - Manifest encoding

/// One place for the manifest bit-level contract: ISO 8601 dates (whole
/// seconds), sorted keys so two exports diff cleanly, unescaped slashes so the
/// folder paths stay readable.
enum DeliveryJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// RFC 4180 subset used by `manifest.csv`: quote only when needed, double the
/// quotes inside, CRLF line endings (plus a UTF-8 BOM so Excel opens the
/// Chinese file names correctly).
enum DeliveryCSV {
    static let header = "source_name,file_name,kind,width,height,bytes,crc32"

    static func field(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func row(_ values: [String]) -> String {
        values.map(field).joined(separator: ",")
    }
}

// MARK: - Minimal ZIP writer (stored, no third party)

/// Dependency-free ZIP32 writer: local file headers, then the central
/// directory, then the end-of-central-directory record. Every entry is stored
/// (method 0) because the payloads are already compressed photos, and every
/// name is flagged UTF-8 (general purpose bit 11) so Chinese file names survive.
///
/// ZIP64 is intentionally not implemented: crossing the 4 GB / 65535-entry
/// limits throws instead of writing a package other tools cannot open.
enum DeliveryZipWriter {
    static let localHeaderSignature: UInt32 = 0x0403_4B50      // PK\x03\x04
    static let centralHeaderSignature: UInt32 = 0x0201_4B50    // PK\x01\x02
    static let endOfCentralSignature: UInt32 = 0x0605_4B50     // PK\x05\x06

    /// ZIP32 field limits.
    static let sizeLimit: Int = 0xFFFF_FFFF
    static let entryLimit: Int = 0xFFFF
    /// General purpose bit 11: file name is UTF-8.
    static let utf8Flag: UInt16 = 0x0800
    /// Stored, no compression.
    static let storedMethod: UInt16 = 0
    /// Version needed to extract: 2.0 (deflate era, stored is fine).
    static let version: UInt16 = 20

    private struct Plan {
        var url: URL
        var name: [UInt8]
        var crc: UInt32
        var size: Int
        var time: UInt16
        var date: UInt16
    }

    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var size: Int
        var offset: Int
        var time: UInt16
        var date: UInt16
    }

    /// Sequential writer that keeps its own byte position, so the central
    /// directory can be written after the payloads without re-reading anything.
    private struct Sink {
        let handle: FileHandle
        var position: Int = 0

        mutating func write(_ bytes: [UInt8]) throws {
            let data = Data(bytes)
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw RetouchDeliveryError.writeFailed("写入交付包失败")
            }
            position += data.count
        }

        mutating func copyContents(of url: URL) throws {
            let reader: FileHandle
            do {
                reader = try FileHandle(forReadingFrom: url)
            } catch {
                throw RetouchDeliveryError.writeFailed("读取失败：\(url.lastPathComponent)")
            }
            defer { try? reader.close() }
            while true {
                let chunk: Data
                do {
                    chunk = try reader.read(upToCount: 262_144) ?? Data()
                } catch {
                    throw RetouchDeliveryError.writeFailed("读取失败：\(url.lastPathComponent)")
                }
                if chunk.isEmpty { break }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    throw RetouchDeliveryError.writeFailed("写入交付包失败")
                }
                position += chunk.count
            }
        }
    }

    static func write(files: [URL], root: URL, destination: URL) throws {
        let fileManager = FileManager.default

        // Pass 1: resolve names, size and CRC of every file.
        var plans: [Plan] = []
        var total = 0
        for url in files {
            guard let relative = DeliveryNaming.relativePath(of: url, root: root),
                  let name = relative.data(using: .utf8) else {
                throw RetouchDeliveryError.writeFailed("文件不在交付目录内：\(url.lastPathComponent)")
            }
            guard name.count <= Int(UInt16.max) else {
                throw RetouchDeliveryError.writeFailed("文件名过长：\(url.lastPathComponent)")
            }
            let measured = try measure(url)
            guard measured.size <= sizeLimit else {
                throw RetouchDeliveryError.writeFailed("单个文件超过 4 GB：\(url.lastPathComponent)")
            }
            total += measured.size
            guard total <= sizeLimit else {
                throw RetouchDeliveryError.writeFailed(
                    "交付包超过 4 GB，无法写入 ZIP32：请关闭全分辨率导出或分批交付")
            }
            let stamp = dosTimestamp(contentModificationDate(url) ?? Date())
            plans.append(Plan(url: url, name: Array(name), crc: measured.crc,
                              size: measured.size, time: stamp.time, date: stamp.date))
        }
        guard plans.count <= entryLimit else {
            throw RetouchDeliveryError.writeFailed("交付包条目超过 65535 个")
        }

        // Destination is created empty, then filled sequentially.
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.removeItem(at: destination)
            } catch {
                throw RetouchDeliveryError.writeFailed("无法覆盖交付包：\(destination.lastPathComponent)")
            }
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw RetouchDeliveryError.writeFailed("无法创建交付包：\(destination.lastPathComponent)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw RetouchDeliveryError.writeFailed("无法打开交付包：\(destination.lastPathComponent)")
        }
        var committed = false
        defer {
            try? handle.close()
            if !committed {
                try? fileManager.removeItem(at: destination)
            }
        }
        var sink = Sink(handle: handle)

        // Pass 2: local file header + stored payload per entry.
        var entries: [Entry] = []
        for plan in plans {
            let offset = sink.position
            var header: [UInt8] = []
            header.append(contentsOf: bytes32(localHeaderSignature))
            header.append(contentsOf: bytes16(version))
            header.append(contentsOf: bytes16(utf8Flag))
            header.append(contentsOf: bytes16(storedMethod))
            header.append(contentsOf: bytes16(plan.time))
            header.append(contentsOf: bytes16(plan.date))
            header.append(contentsOf: bytes32(plan.crc))
            header.append(contentsOf: bytes32(UInt32(plan.size)))   // compressed size
            header.append(contentsOf: bytes32(UInt32(plan.size)))   // uncompressed size
            header.append(contentsOf: bytes16(UInt16(plan.name.count)))
            header.append(contentsOf: bytes16(0))                   // extra field length
            header.append(contentsOf: plan.name)
            try sink.write(header)
            try sink.copyContents(of: plan.url)
            entries.append(Entry(name: plan.name, crc: plan.crc, size: plan.size,
                                 offset: offset, time: plan.time, date: plan.date))
        }

        // Pass 3: central directory.
        let centralOffset = sink.position
        for entry in entries {
            var record: [UInt8] = []
            record.append(contentsOf: bytes32(centralHeaderSignature))
            record.append(contentsOf: bytes16(version))             // version made by
            record.append(contentsOf: bytes16(version))             // version needed
            record.append(contentsOf: bytes16(utf8Flag))
            record.append(contentsOf: bytes16(storedMethod))
            record.append(contentsOf: bytes16(entry.time))
            record.append(contentsOf: bytes16(entry.date))
            record.append(contentsOf: bytes32(entry.crc))
            record.append(contentsOf: bytes32(UInt32(entry.size)))
            record.append(contentsOf: bytes32(UInt32(entry.size)))
            record.append(contentsOf: bytes16(UInt16(entry.name.count)))
            record.append(contentsOf: bytes16(0))                   // extra field length
            record.append(contentsOf: bytes16(0))                   // comment length
            record.append(contentsOf: bytes16(0))                   // disk number start
            record.append(contentsOf: bytes16(0))                   // internal attributes
            record.append(contentsOf: bytes32(0))                   // external attributes
            record.append(contentsOf: bytes32(UInt32(entry.offset)))
            record.append(contentsOf: entry.name)
            try sink.write(record)
        }
        let centralSize = sink.position - centralOffset
        guard centralOffset <= sizeLimit, centralSize <= sizeLimit, sink.position <= sizeLimit else {
            throw RetouchDeliveryError.writeFailed(
                "交付包超过 4 GB，无法写入 ZIP32：请关闭全分辨率导出或分批交付")
        }

        // Pass 4: end of central directory.
        var end: [UInt8] = []
        end.append(contentsOf: bytes32(endOfCentralSignature))
        end.append(contentsOf: bytes16(0))                          // this disk number
        end.append(contentsOf: bytes16(0))                          // disk with central directory
        end.append(contentsOf: bytes16(UInt16(entries.count)))      // entries on this disk
        end.append(contentsOf: bytes16(UInt16(entries.count)))      // entries total
        end.append(contentsOf: bytes32(UInt32(centralSize)))
        end.append(contentsOf: bytes32(UInt32(centralOffset)))
        end.append(contentsOf: bytes16(0))                          // comment length
        try sink.write(end)

        try? handle.synchronize()
        committed = true
    }

    /// MS-DOS date/time packed fields, in the current time zone (ZIP timestamps
    /// are local wall-clock by definition). Years clamp to the 1980...2107 range.
    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)
        let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let stamped = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (time, stamped)
    }

    /// CRC + size of one file, read in 256 KB chunks.
    private static func measure(_ url: URL) throws -> (crc: UInt32, size: Int) {
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: url)
        } catch {
            throw RetouchDeliveryError.writeFailed("读取失败：\(url.lastPathComponent)")
        }
        defer { try? reader.close() }
        var digest = DeliveryCRC32Stream()
        var size = 0
        while true {
            let chunk: Data
            do {
                chunk = try reader.read(upToCount: 262_144) ?? Data()
            } catch {
                throw RetouchDeliveryError.writeFailed("读取失败：\(url.lastPathComponent)")
            }
            if chunk.isEmpty { break }
            digest.update(chunk)
            size += chunk.count
        }
        return (digest.value, size)
    }

    private static func contentModificationDate(_ url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private static func bytes16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0x00FF), UInt8((value >> 8) & 0x00FF)]
    }

    private static func bytes32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 24) & 0xFF)]
    }
}

#if canImport(UIKit)

// MARK: - Result

struct DeliveryResult {
    var packageURL: URL          // the .zip handed to the customer
    var folderURL: URL           // the working folder (web/, full/, proofing/, manifest)
    var manifestURL: URL?
    var proofingURL: URL?
    var manifest: DeliveryManifest
    var totalBytes: Int          // byte size of the .zip, i.e. what actually gets sent
}

// MARK: - Exporter

/// Commercial delivery package: web JPEGs, full-resolution files, optional ID
/// photo variants, a customer proofing page and a ZIP with a manifest.
///
/// Layout inside `directory`:
///
///     web/        every approved frame, long edge = options.webLongEdge, watermarked
///     full/       original pixels, print format, never watermarked
///     idphoto/    ID photo variants at the spec's 300 dpi pixel size
///     proofing/   index.html, offline customer pick page
///     manifest.json / manifest.csv
///     <prefix>_交付包.zip
///
/// The watermark is deliberately only burned into `web/` and the proofing page:
/// the print file is the paid deliverable and must stay clean.
final class RetouchDeliveryExporter {
    private let context: CIContext
    private let fileManager = FileManager.default
    /// Watermark layer, drawn once per output size/corner/opacity.
    private var watermarkCache: [String: UIImage] = [:]

    init(context: CIContext) {
        self.context = context
    }

    // MARK: - Batch export

    func export(job: BatchJob, approvedOnly: Bool, options: DeliveryOptions,
                to directory: URL) throws -> DeliveryResult {
        let requested = job.photos
            .filter { photo in
                if approvedOnly { return photo.status == .approved }
                return photo.status == .approved || photo.status == .processed
            }
            .sorted { $0.fileName < $1.fileName }
        guard !requested.isEmpty else { throw RetouchDeliveryError.noApprovedPhotos }

        try ensureDirectory(directory)
        let webFolder = directory.appendingPathComponent("web", isDirectory: true)
        try ensureDirectory(webFolder)
        let fullFolder = directory.appendingPathComponent("full", isDirectory: true)
        let idFolder = directory.appendingPathComponent("idphoto", isDirectory: true)
        let proofingFolder = directory.appendingPathComponent("proofing", isDirectory: true)
        if options.includeFullResolution {
            try ensureDirectory(fullFolder)
        }

        let colorSpace = self.colorSpace(for: options.colorSpace)
        let date = Date()
        let prefix = DeliveryNaming.sanitizedPrefix(options.filePrefix)
        let watermarkText = (options.watermarkText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        watermarkCache.removeAll()

        var entries: [DeliveryManifestEntry] = []
        var proofingItems: [RetouchProofingPage.Item] = []
        var packageFiles: [URL] = []

        for (offset, photo) in requested.enumerated() {
            let index = offset + 1
            guard let sourceImage = loadSourceImage(photo),
                  let source = orientedCIImage(from: sourceImage) else {
                throw RetouchDeliveryError.encodeFailed(photo.fileName)
            }
            let metadata = options.keepMetadata ? sourceMetadata(photo) : nil

            // 1. web (watermarked)
            let webName = DeliveryNaming.fileName(prefix: prefix, date: date, index: index,
                                                  fileExtension: options.webFormat.fileExtension)
            let webURL = webFolder.appendingPathComponent(webName)
            let webFit = fitImage(source, longEdge: options.webLongEdge)
            guard var webCG = context.createCGImage(webFit.image, from: webFit.rect,
                                                    format: .RGBA8, colorSpace: colorSpace) else {
                throw RetouchDeliveryError.encodeFailed(photo.fileName)
            }
            if !watermarkText.isEmpty,
               let stamp = watermarkImage(size: CGSize(width: webCG.width, height: webCG.height),
                                          text: watermarkText,
                                          opacity: options.watermarkOpacity,
                                          corner: options.watermarkCorner) {
                webCG = composite(base: webCG, watermark: stamp, colorSpace: colorSpace) ?? webCG
            }
            try writeImage(webCG, to: webURL, format: options.webFormat,
                           quality: options.webQuality, keepMetadata: options.keepMetadata,
                           sourceProperties: metadata)
            entries.append(try manifestEntry(sourceName: photo.fileName, kind: "web", url: webURL,
                                             width: webCG.width, height: webCG.height,
                                             relativeTo: directory))
            packageFiles.append(webURL)
            proofingItems.append(RetouchProofingPage.Item(fileName: "../web/\(webName)",
                                                          title: photo.fileName,
                                                          width: webCG.width,
                                                          height: webCG.height))

            // 2. full resolution (print, clean)
            if options.includeFullResolution {
                let fullName = DeliveryNaming.fileName(prefix: prefix, date: date, index: index,
                                                       fileExtension: options.printFormat.fileExtension)
                let fullURL = fullFolder.appendingPathComponent(fullName)
                guard let fullCG = context.createCGImage(source, from: fullRect(source),
                                                         format: .RGBA8,
                                                         colorSpace: colorSpace) else {
                    throw RetouchDeliveryError.encodeFailed(photo.fileName)
                }
                try writeImage(fullCG, to: fullURL, format: options.printFormat,
                               quality: options.printQuality, keepMetadata: options.keepMetadata,
                               sourceProperties: metadata)
                entries.append(try manifestEntry(sourceName: photo.fileName, kind: "full", url: fullURL,
                                                 width: fullCG.width, height: fullCG.height,
                                                 relativeTo: directory))
                packageFiles.append(fullURL)
            }

            // 3. ID photo variant (framed by the caller's engine, sized here)
            if let spec = photo.adjustments.idPhoto {
                try ensureDirectory(idFolder)
                let idName = DeliveryNaming.fileName(prefix: prefix, date: date, index: index,
                                                     fileExtension: options.printFormat.fileExtension)
                let idURL = idFolder.appendingPathComponent(idName)
                let idFit = fitIDPhoto(source, spec: spec)
                guard let idCG = context.createCGImage(idFit.image, from: idFit.rect,
                                                       format: .RGBA8,
                                                       colorSpace: colorSpace) else {
                    throw RetouchDeliveryError.encodeFailed(photo.fileName)
                }
                try writeImage(idCG, to: idURL, format: options.printFormat,
                               quality: options.printQuality, keepMetadata: false,
                               sourceProperties: nil)
                entries.append(try manifestEntry(sourceName: photo.fileName, kind: "id", url: idURL,
                                                 width: idCG.width, height: idCG.height,
                                                 relativeTo: directory))
                packageFiles.append(idURL)
            }
        }

        let presetID = dominantPresetID(in: requested)
        let manifest = DeliveryManifest(jobName: job.name.isEmpty ? "未命名拍摄" : job.name,
                                        createdAt: date,
                                        presetID: presetID,
                                        look: lookName(for: presetID),
                                        entries: entries,
                                        anchorFrameCount: job.anchor?.frameCount ?? 0,
                                        appVersion: appVersion())
        var manifestURL: URL?
        if options.includeManifest {
            let written = try writeManifest(manifest, in: directory)
            manifestURL = written.json
            packageFiles.append(written.json)
            packageFiles.append(written.csv)
        }

        var proofingURL: URL?
        if options.includeProofingPage {
            try ensureDirectory(proofingFolder)
            let pageURL = proofingFolder.appendingPathComponent("index.html")
            let note: String? = watermarkText.isEmpty
                ? nil
                : "本页为带水印样片，仅供选片：\(watermarkText)"
            do {
                try RetouchProofingPage.build(jobName: manifest.jobName, items: proofingItems,
                                              outputURL: pageURL, watermarkNote: note)
            } catch {
                throw RetouchDeliveryError.writeFailed("proofing/index.html")
            }
            proofingURL = pageURL
            packageFiles.append(pageURL)
        }

        let zipURL = directory.appendingPathComponent("\(prefix)_交付包.zip")
        try makeZip(files: packageFiles, root: directory, destination: zipURL)
        let totalBytes = fileSize(zipURL)

        return DeliveryResult(packageURL: zipURL,
                              folderURL: directory,
                              manifestURL: manifestURL,
                              proofingURL: proofingURL,
                              manifest: manifest,
                              totalBytes: totalBytes)
    }

    // MARK: - Single file export

    /// Single-file export used by the review screen ("save this one").
    func exportSingle(image: UIImage, sourceName: String, options: DeliveryOptions,
                      to directory: URL) throws -> DeliveryManifestEntry {
        guard let source = orientedCIImage(from: image) else {
            throw RetouchDeliveryError.encodeFailed(sourceName)
        }
        try ensureDirectory(directory)
        let webFolder = directory.appendingPathComponent("web", isDirectory: true)
        try ensureDirectory(webFolder)

        let colorSpace = self.colorSpace(for: options.colorSpace)
        let date = Date()
        let prefix = DeliveryNaming.sanitizedPrefix(options.filePrefix)
        let watermarkText = (options.watermarkText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        watermarkCache.removeAll()

        let webName = DeliveryNaming.fileName(prefix: prefix, date: date, index: 1,
                                              fileExtension: options.webFormat.fileExtension)
        let webURL = webFolder.appendingPathComponent(webName)
        let webFit = fitImage(source, longEdge: options.webLongEdge)
        guard var webCG = context.createCGImage(webFit.image, from: webFit.rect,
                                                format: .RGBA8, colorSpace: colorSpace) else {
            throw RetouchDeliveryError.encodeFailed(sourceName)
        }
        if !watermarkText.isEmpty,
           let stamp = watermarkImage(size: CGSize(width: webCG.width, height: webCG.height),
                                      text: watermarkText,
                                      opacity: options.watermarkOpacity,
                                      corner: options.watermarkCorner) {
            webCG = composite(base: webCG, watermark: stamp, colorSpace: colorSpace) ?? webCG
        }
        // A bare UIImage carries no reliable source metadata, so nothing is
        // copied here — the encoder never invents EXIF it did not receive.
        try writeImage(webCG, to: webURL, format: options.webFormat,
                       quality: options.webQuality, keepMetadata: options.keepMetadata,
                       sourceProperties: nil)

        if options.includeFullResolution {
            let fullFolder = directory.appendingPathComponent("full", isDirectory: true)
            try ensureDirectory(fullFolder)
            let fullName = DeliveryNaming.fileName(prefix: prefix, date: date, index: 1,
                                                   fileExtension: options.printFormat.fileExtension)
            let fullURL = fullFolder.appendingPathComponent(fullName)
            guard let fullCG = context.createCGImage(source, from: fullRect(source),
                                                     format: .RGBA8,
                                                     colorSpace: colorSpace) else {
                throw RetouchDeliveryError.encodeFailed(sourceName)
            }
            try writeImage(fullCG, to: fullURL, format: options.printFormat,
                           quality: options.printQuality, keepMetadata: options.keepMetadata,
                           sourceProperties: nil)
        }

        return try manifestEntry(sourceName: sourceName, kind: "web", url: webURL,
                                 width: webCG.width, height: webCG.height, relativeTo: directory)
    }

    // MARK: - ZIP

    /// Zips `files` (already written inside `root`) into `destination`.
    func makeZip(files: [URL], root: URL, destination: URL) throws {
        try DeliveryZipWriter.write(files: files, root: root, destination: destination)
    }

    // MARK: - Image preparation

    private func loadSourceImage(_ photo: BatchPhoto) -> UIImage? {
        if let url = photo.resultURL, fileManager.fileExists(atPath: url.path),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        return photo.originalImage
    }

    /// EXIF-normalised CIImage with its origin moved to (0, 0), so a rotated
    /// original cannot shift the delivery crop.
    private func orientedCIImage(from image: UIImage) -> CIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let orientation = RetouchSpecialist.exifOrientation(image.imageOrientation)
        let oriented = CIImage(cgImage: cgImage).oriented(forExifOrientation: orientation)
        let extent = oriented.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        return oriented.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                          y: -extent.origin.y))
    }

    /// Fits the long edge to `longEdge`; never upscales. The render rect is
    /// rounded down so Core Image cannot pad a transparent edge into a JPEG.
    private func fitImage(_ image: CIImage, longEdge: Int) -> (image: CIImage, rect: CGRect) {
        let extent = image.extent
        let target = CGFloat(max(64, longEdge))
        let current = max(extent.width, extent.height)
        let scale = (current > target && current > 0) ? target / current : 1.0
        let scaled = scale < 1.0
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let scaledExtent = scaled.extent
        let width = max(1, scaledExtent.width.rounded(.down))
        let height = max(1, scaledExtent.height.rounded(.down))
        return (scaled, CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Aspect-fill crop into the spec's 300 dpi pixel size. The head placement is
    /// the engine's job (`RetouchAdjustments.cropToIDPhoto`); this step only
    /// guarantees the exact millimetre footprint the print shop expects.
    private func fitIDPhoto(_ image: CIImage, spec: IDPhotoSpec) -> (image: CIImage, rect: CGRect) {
        let pixels = spec.pixelSize(dpi: 300)
        let width = max(1, pixels.width.rounded())
        let height = max(1, pixels.height.rounded())
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return (image, target) }

        let targetAspect = width / height
        let sourceAspect = extent.width / extent.height
        var crop = extent
        if sourceAspect > targetAspect {
            let cropWidth = extent.height * targetAspect
            crop = CGRect(x: extent.midX - cropWidth / 2, y: extent.minY,
                          width: cropWidth, height: extent.height)
        } else if sourceAspect < targetAspect {
            let cropHeight = extent.width / targetAspect
            crop = CGRect(x: extent.minX, y: extent.midY - cropHeight / 2,
                          width: extent.width, height: cropHeight)
        }
        guard crop.width > 1, crop.height > 1 else { return (image, target) }
        let scale = width / crop.width
        let cropped = image.cropped(to: crop)
        let placed = cropped.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scaled = placed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return (scaled, target)
    }

    private func colorSpace(for space: DeliveryOptions.ColorSpace) -> CGColorSpace {
        let name = space == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Full-resolution render rect: the original pixels, floored so Core Image
    /// cannot pad an extra transparent row or column.
    private func fullRect(_ image: CIImage) -> CGRect {
        let extent = image.extent
        return CGRect(x: 0, y: 0,
                      width: max(1, extent.width.rounded(.down)),
                      height: max(1, extent.height.rounded(.down)))
    }

    // MARK: - Encoders

    /// Encodes straight through ImageIO — never `UIImage.jpegData` — so print
    /// quality, orientation and the TIFF tag set are exactly what was asked for.
    private func writeImage(_ image: CGImage, to url: URL,
                            format: DeliveryOptions.Format, quality: Double,
                            keepMetadata: Bool, sourceProperties: [String: Any]?) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".tmp")
        let type: UTType
        switch format {
        case .jpeg: type = .jpeg
        case .heic: type = UTType.heic
        case .tiff: type = UTType.tiff
        }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                                                               type.identifier as CFString,
                                                               1, nil) else {
            throw RetouchDeliveryError.encodeFailed(url.lastPathComponent)
        }

        var properties: [CFString: Any] = [:]
        switch format {
        case .jpeg, .heic:
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1.0)
        case .tiff:
            break   // lossless by construction
        }
        properties[kCGImagePropertyOrientation] = 1

        // Pass-through only: the EXIF/TIFF dictionaries of the source are copied
        // verbatim (Artist/Copyright included) and never synthesised.
        if keepMetadata, let sourceProperties {
            if let exif = sourceProperties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               !exif.isEmpty {
                properties[kCGImagePropertyExifDictionary] = exif as NSDictionary
            }
            var tiff = (sourceProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            if format == .tiff {
                tiff[kCGImagePropertyTIFFCompression as String] = 1     // 1 = none
            }
            if !tiff.isEmpty {
                properties[kCGImagePropertyTIFFDictionary] = tiff as NSDictionary
            }
        } else if format == .tiff {
            properties[kCGImagePropertyTIFFDictionary] =
                [kCGImagePropertyTIFFCompression as String: 1] as NSDictionary
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? fileManager.removeItem(at: temporary)
            throw RetouchDeliveryError.encodeFailed(url.lastPathComponent)
        }
        // Publish only bytes that decode back (same check as RetouchVersionStore).
        guard let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceCreateImageAtIndex(check, 0, nil) != nil else {
            try? fileManager.removeItem(at: temporary)
            throw RetouchDeliveryError.encodeFailed(url.lastPathComponent)
        }
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temporary, to: url)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw RetouchDeliveryError.encodeFailed(url.lastPathComponent)
        }
    }

    private func sourceMetadata(_ photo: BatchPhoto) -> [String: Any]? {
        if let url = photo.resultURL,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            return properties
        }
        guard let source = CGImageSourceCreateWithData(photo.originalData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        return properties
    }

    // MARK: - Watermark

    /// White text with a soft dark shadow, 2.5 % inside the chosen corner, alpha
    /// baked at `opacity`. Drawn once per (size, corner, opacity) and cached.
    private func watermarkImage(size: CGSize, text: String, opacity: Double,
                                corner: DeliveryOptions.WatermarkCorner) -> UIImage? {
        guard size.width >= 48, size.height >= 24 else { return nil }
        let key = "\(Int(size.width))x\(Int(size.height))|\(Int((opacity * 100).rounded()))|\(corner.rawValue)|\(text)"
        if let cached = watermarkCache[key] { return cached }

        let alpha = CGFloat(min(max(opacity, 0.05), 1.0))
        let fontSize = max(12, min(size.width, size.height) * 0.048)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let stamp = renderer.image { _ in
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.45 * alpha)
            shadow.shadowBlurRadius = max(2, fontSize * 0.14)
            shadow.shadowOffset = CGSize(width: 0, height: max(1, fontSize * 0.05))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(alpha),
                .shadow: shadow
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            let margin = min(size.width, size.height) * 0.025
            var origin = CGPoint(x: margin, y: margin)
            switch corner {
            case .topLeft:
                origin = CGPoint(x: margin, y: margin)
            case .topRight:
                origin = CGPoint(x: size.width - margin - textSize.width, y: margin)
            case .bottomLeft:
                origin = CGPoint(x: margin, y: size.height - margin - textSize.height)
            case .bottomRight:
                origin = CGPoint(x: size.width - margin - textSize.width,
                                 y: size.height - margin - textSize.height)
            }
            let limitX = max(margin * 0.5, size.width - textSize.width - margin * 0.5)
            let limitY = max(margin * 0.5, size.height - textSize.height - margin * 0.5)
            origin.x = min(max(origin.x, margin * 0.5), limitX)
            origin.y = min(max(origin.y, margin * 0.5), limitY)
            string.draw(at: origin)
        }
        if watermarkCache.count >= 32 { watermarkCache.removeAll() }
        watermarkCache[key] = stamp
        return stamp
    }

    private func composite(base: CGImage, watermark: UIImage, colorSpace: CGColorSpace) -> CGImage? {
        let baseImage = CIImage(cgImage: base)
        guard let mark = CIImage(image: watermark) else { return base }
        let composed = mark.composited(over: baseImage)
        return context.createCGImage(composed, from: baseImage.extent,
                                     format: .RGBA8, colorSpace: colorSpace) ?? base
    }

    // MARK: - Manifest

    private func manifestEntry(sourceName: String, kind: String, url: URL,
                               width: Int, height: Int, relativeTo root: URL) throws -> DeliveryManifestEntry {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw RetouchDeliveryError.writeFailed(url.lastPathComponent)
        }
        let checksum = DeliveryCRC32.hex(DeliveryCRC32.checksum(data))
        let relative = DeliveryNaming.relativePath(of: url, root: root) ?? url.lastPathComponent
        return DeliveryManifestEntry(sourceName: sourceName, fileName: relative, kind: kind,
                                     width: width, height: height,
                                     bytes: data.count, checksum: checksum)
    }

    private func writeManifest(_ manifest: DeliveryManifest,
                               in directory: URL) throws -> (json: URL, csv: URL) {
        let jsonURL = directory.appendingPathComponent("manifest.json")
        let csvURL = directory.appendingPathComponent("manifest.csv")

        let encoded: Data
        do {
            encoded = try DeliveryJSON.encoder().encode(manifest)
        } catch {
            throw RetouchDeliveryError.writeFailed("manifest.json")
        }
        try replaceFile(at: jsonURL, with: encoded, failure: "manifest.json")

        var lines: [String] = [DeliveryCSV.header]
        for entry in manifest.entries {
            lines.append(DeliveryCSV.row([entry.sourceName, entry.fileName, entry.kind,
                                          String(entry.width), String(entry.height),
                                          String(entry.bytes), entry.checksum]))
        }
        // UTF-8 BOM + CRLF so Excel opens the Chinese columns without mojibake.
        let csv = "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
        try replaceFile(at: csvURL, with: Data(csv.utf8), failure: "manifest.csv")
        return (jsonURL, csvURL)
    }

    private func dominantPresetID(in photos: [BatchPhoto]) -> String {
        var counts: [String: Int] = [:]
        for photo in photos {
            counts[photo.adjustments.presetID, default: 0] += 1
        }
        let ordered = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        return ordered.first?.key ?? "p02"
    }

    private func lookName(for presetID: String) -> String {
        if let preset = RetouchPresetCatalog.all.first(where: { $0.id == presetID }) {
            return preset.look.displayName
        }
        return RetouchLook.commercialNatural.displayName
    }

    private func appVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty {
            return version
        }
        return "0"
    }

    // MARK: - File system

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw RetouchDeliveryError.cannotCreateDirectory
        }
    }

    /// Writes through a `.tmp` sibling and moves it into place, so a crash or a
    /// disk-full error never leaves a half-written manifest behind.
    private func replaceFile(at url: URL, with data: Data, failure: String) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temporary, to: url)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw RetouchDeliveryError.writeFailed(failure)
        }
    }

    private func fileSize(_ url: URL) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return size
    }
}

#endif
