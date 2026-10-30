import Foundation

// Runtime tests for the commercial delivery layer:
//
//   OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchDelivery.swift
//   OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchProofing.swift
//
// Both files keep their value logic outside `#if canImport(UIKit)`, so the real
// CRC32, ZIP writer, naming scheme, manifest coding and HTML page builder run on
// macOS with Foundation only — no UIKit, no simulator, no Xcode project:
//
//   xcrun swiftc \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchDelivery.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchProofing.swift \
//     tests/delivery/main.swift \
//     -o build/delivery-tests && build/delivery-tests
//
// The image pipeline (ImageIO destinations, CIContext, watermark drawing) needs
// UIKit/ImageIO and is therefore only type-checked on the iOS SDK; everything
// that decides byte layouts is covered here.

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: " + label)
    }
}

func expectEqual<T: Equatable>(_ value: T, _ expected: T, _ label: String) {
    checks += 1
    if value == expected {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: \(label) -> got \(value), expected \(expected)")
    }
}

func expectNoThrow(_ label: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        print("PASS: " + label)
    } catch {
        failures += 1
        print("FAIL: \(label) -> unexpected error \(error)")
    }
}

func expectThrows(_ label: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL: \(label) -> no error thrown")
    } catch {
        print("PASS: " + label)
    }
}

func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
        count += 1
        if found.upperBound >= searchRange.upperBound { break }
        searchRange = found.upperBound..<haystack.endIndex
    }
    return count
}

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("opa-delivery-tests-\(UUID().uuidString)", isDirectory: true)
expectNoThrow("创建测试临时目录") {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
}

// MARK: - 1. CRC32

print("-- CRC32 --")

func ascii(_ value: String) -> [UInt8] { Array(value.utf8) }

expectEqual(DeliveryCRC32.checksum(ascii("123456789")), 0xCBF4_3926,
            "CRC32 of \"123456789\" is 0xCBF43926")
expectEqual(DeliveryCRC32.checksum([UInt8]()), 0,
            "CRC32 of empty input is 0")
expectEqual(DeliveryCRC32.checksum(ascii("a")), 0xE8B7_BE43,
            "CRC32 of \"a\" is 0xE8B7BE43")
expectEqual(DeliveryCRC32.checksum(ascii("The quick brown fox jumps over the lazy dog")), 0x414F_A339,
            "CRC32 of the pangram is 0x414FA339")
expectEqual(DeliveryCRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926,
            "CRC32 Data overload matches the byte overload")
expectEqual(DeliveryCRC32.hex(0xCBF4_3926), "CBF43926",
            "CRC32 hex is eight uppercase digits")
expectEqual(DeliveryCRC32.hex(0), "00000000",
            "CRC32 hex pads a zero checksum")

var streaming = DeliveryCRC32Stream()
streaming.update(Data("12345".utf8))
streaming.update(Data("6789".utf8))
expectEqual(streaming.value, 0xCBF4_3926,
            "Streaming CRC32 matches one-shot across a chunk boundary")

var splitBytes = DeliveryCRC32Stream()
splitBytes.update(ascii("The quick "))
splitBytes.update(ascii("brown fox "))
splitBytes.update(ascii("jumps over the lazy dog"))
expectEqual(splitBytes.value, 0x414F_A339,
            "Streaming CRC32 matches one-shot for three byte chunks")

// MARK: - 2. File naming

print("-- file naming --")

var stampComponents = DateComponents()
stampComponents.year = 2026
stampComponents.month = 1
stampComponents.day = 1
stampComponents.hour = 12
stampComponents.minute = 0
stampComponents.second = 0
var stampCalendar = Calendar(identifier: .gregorian)
stampCalendar.timeZone = TimeZone.current
let stampDate = stampCalendar.date(from: stampComponents) ?? Date(timeIntervalSince1970: 0)

expectEqual(DeliveryNaming.dateStamp(stampDate), "20260101",
            "Date stamp is yyyyMMdd with a POSIX locale")
expectEqual(DeliveryNaming.fileName(prefix: "OPA", date: stampDate, index: 1, fileExtension: "jpg"),
            "OPA_20260101_0001.jpg",
            "File name is prefix_date_index.ext")
expectEqual(DeliveryNaming.fileName(prefix: "OPA", date: stampDate, index: 42, fileExtension: "tif"),
            "OPA_20260101_0042.tif",
            "Index is zero padded to four digits")
expectEqual(DeliveryNaming.fileName(prefix: "OPA", date: stampDate, index: 1234, fileExtension: "heic"),
            "OPA_20260101_1234.heic",
            "Four-digit index is not padded further")
expectEqual(DeliveryNaming.fileName(prefix: "OPA", date: stampDate, index: 12345, fileExtension: "jpg"),
            "OPA_20260101_12345.jpg",
            "A five-digit index is never truncated")
expectEqual(DeliveryNaming.fileName(prefix: "", date: stampDate, index: 1, fileExtension: "jpg"),
            "OPA_20260101_0001.jpg",
            "An empty prefix falls back to OPA")
expectEqual(DeliveryNaming.fileName(prefix: "a/b:c", date: stampDate, index: 2, fileExtension: "jpg"),
            "abc_20260101_0002.jpg",
            "Path separators and colons are stripped from the prefix")
expectEqual(DeliveryNaming.fileName(prefix: "  ", date: stampDate, index: 3, fileExtension: "jpg"),
            "OPA_20260101_0003.jpg",
            "A whitespace-only prefix falls back to OPA")
expectEqual(DeliveryNaming.fileName(prefix: "客片", date: stampDate, index: 4, fileExtension: "jpg"),
            "客片_20260101_0004.jpg",
            "Chinese prefixes are kept as-is")
expectEqual(DeliveryNaming.paddedIndex(7), "0007", "paddedIndex pads to four digits")
expectEqual(DeliveryNaming.paddedIndex(0), "0000", "paddedIndex keeps zero")

let namingRoot = rootURL.appendingPathComponent("naming", isDirectory: true)
let namingChild = namingRoot.appendingPathComponent("web", isDirectory: true)
expect(DeliveryNaming.relativePath(of: namingChild.appendingPathComponent("x.jpg"), root: namingRoot) == "web/x.jpg",
       "relativePath keeps the folder structure for ZIP entry names")
expect(DeliveryNaming.relativePath(of: rootURL.appendingPathComponent("outside.jpg"), root: namingRoot) == nil,
       "relativePath returns nil for a file outside the root")

// MARK: - 3. ZIP writer

print("-- ZIP writer --")

let zipRoot = rootURL.appendingPathComponent("zip", isDirectory: true)
let zipSub = zipRoot.appendingPathComponent("sub", isDirectory: true)
expectNoThrow("创建 ZIP 测试目录") {
    try fileManager.createDirectory(at: zipSub, withIntermediateDirectories: true)
}
let fileA = zipRoot.appendingPathComponent("a.jpg")
let fileB = zipSub.appendingPathComponent("b.tif")
let fileC = zipRoot.appendingPathComponent("manifest.json")
let dataA = Data("hello".utf8)
let dataB = Data("world!".utf8)
let dataC = Data("{}".utf8)
expectNoThrow("写入三个待打包文件") {
    try dataA.write(to: fileA)
    try dataB.write(to: fileB)
    try dataC.write(to: fileC)
}

let zipURL = rootURL.appendingPathComponent("package.zip")
expectNoThrow("写 ZIP 包") {
    try DeliveryZipWriter.write(files: [fileA, fileB, fileC], root: zipRoot, destination: zipURL)
}
expect(fileManager.fileExists(atPath: zipURL.path), "ZIP 文件已落盘")

let zipBytes = [UInt8]((try? Data(contentsOf: zipURL)) ?? Data())
expect(zipBytes.count > 22, "ZIP 文件长度大于 EOCD")

// Walk the local headers front to back, exactly like an unzip implementation.
var cursor = 0
var localNames: [String] = []
var localFlags: [UInt16] = []
var localMethods: [UInt16] = []
var localCRCs: [UInt32] = []
var localVersions: [UInt16] = []
var localContents: [Data] = []
var localOffsets: [Int] = []
while cursor + 30 <= zipBytes.count, readUInt32(zipBytes, cursor) == 0x0403_4B50 {
    localOffsets.append(cursor)
    localVersions.append(readUInt16(zipBytes, cursor + 4))
    localFlags.append(readUInt16(zipBytes, cursor + 6))
    localMethods.append(readUInt16(zipBytes, cursor + 8))
    let crc = readUInt32(zipBytes, cursor + 14)
    let compressedSize = Int(readUInt32(zipBytes, cursor + 18))
    let uncompressedSize = Int(readUInt32(zipBytes, cursor + 22))
    let nameLength = Int(readUInt16(zipBytes, cursor + 26))
    let extraLength = Int(readUInt16(zipBytes, cursor + 28))
    let nameStart = cursor + 30
    guard nameStart + nameLength <= zipBytes.count else { break }
    localNames.append(String(decoding: zipBytes[nameStart..<(nameStart + nameLength)], as: UTF8.self))
    let dataStart = nameStart + nameLength + extraLength
    guard dataStart + uncompressedSize <= zipBytes.count, compressedSize == uncompressedSize else { break }
    localCRCs.append(crc)
    localContents.append(Data(zipBytes[dataStart..<(dataStart + uncompressedSize)]))
    cursor = dataStart + uncompressedSize
}

expectEqual(localNames, ["a.jpg", "sub/b.tif", "manifest.json"],
            "Local headers are in input order with /-separated relative paths")
expectEqual(localMethods, [0, 0, 0], "Every entry is stored (method 0)")
expectEqual(localVersions, [20, 20, 20], "Every entry declares version 2.0")
expect(localFlags.allSatisfy { $0 & 0x0800 != 0 }, "Every entry sets general purpose bit 11 (UTF-8 names)")
expect(localFlags.allSatisfy { $0 & 0x0008 == 0 }, "No data descriptors (sizes are in the local header)")
expectEqual(localContents, [dataA, dataB, dataC], "Stored payloads round-trip byte for byte")
expectEqual(localCRCs, [DeliveryCRC32.checksum(dataA), DeliveryCRC32.checksum(dataB),
                        DeliveryCRC32.checksum(dataC)],
            "Local header CRC32 values match the payload checksums")
expectEqual(DeliveryCRC32.hex(localCRCs.first ?? 0), DeliveryCRC32.hex(DeliveryCRC32.checksum(dataA)),
            "CRC32 of the first payload is the documented value")

// The walk must have stopped exactly on the central directory.
expectEqual(readUInt32(zipBytes, cursor), 0x0201_4B50,
            "Payload walk stops on the central directory signature")

let eocdOffset = zipBytes.count - 22
expectEqual(readUInt32(zipBytes, eocdOffset), 0x0605_4B50, "EOCD record ends the archive")
expectEqual(Int(readUInt16(zipBytes, eocdOffset + 8)), 3, "EOCD entry count (this disk) is 3")
expectEqual(Int(readUInt16(zipBytes, eocdOffset + 10)), 3, "EOCD total entry count is 3")
let centralOffset = Int(readUInt32(zipBytes, eocdOffset + 16))
let centralSize = Int(readUInt32(zipBytes, eocdOffset + 12))
expectEqual(centralOffset, cursor, "EOCD central directory offset points at the first central record")
expectEqual(centralOffset + centralSize, eocdOffset,
            "Central directory size exactly fills the gap before the EOCD")

var centralCursor = centralOffset
var centralCount = 0
var centralLocalOffsets: [Int] = []
while centralCursor + 46 <= zipBytes.count, readUInt32(zipBytes, centralCursor) == 0x0201_4B50 {
    centralCount += 1
    let nameLength = Int(readUInt16(zipBytes, centralCursor + 28))
    let extraLength = Int(readUInt16(zipBytes, centralCursor + 30))
    let commentLength = Int(readUInt16(zipBytes, centralCursor + 32))
    let localOffset = Int(readUInt32(zipBytes, centralCursor + 42))
    centralLocalOffsets.append(localOffset)
    guard readUInt32(zipBytes, localOffset) == 0x0403_4B50 else {
        failures += 1
        print("FAIL: central record \(centralCount) does not point at a local header")
        break
    }
    centralCursor += 46 + nameLength + extraLength + commentLength
}
expectEqual(centralCount, 3, "Central directory holds one record per file")
expectEqual(centralLocalOffsets, localOffsets,
            "Central records point at the matching local header offsets")
expectEqual(centralCursor, eocdOffset, "Central directory ends where the EOCD starts")

// An empty package must still be a valid archive.
let emptyZipURL = rootURL.appendingPathComponent("empty.zip")
expectNoThrow("写空 ZIP 包") {
    try DeliveryZipWriter.write(files: [], root: zipRoot, destination: emptyZipURL)
}
let emptyBytes = [UInt8]((try? Data(contentsOf: emptyZipURL)) ?? Data())
expectEqual(emptyBytes.count, 22, "An empty ZIP is exactly one EOCD record")
expectEqual(readUInt32(emptyBytes, 0), 0x0605_4B50, "Empty ZIP starts with the EOCD signature")
expectEqual(Int(readUInt16(emptyBytes, 10)), 0, "Empty ZIP declares zero entries")

// A file outside the delivery root must be rejected, not silently renamed.
let outsider = rootURL.appendingPathComponent("outsider.jpg")
expectNoThrow("写入交付目录之外的文件") { try Data("x".utf8).write(to: outsider) }
expectThrows("交付目录之外的文件会被拒绝") {
    try DeliveryZipWriter.write(files: [outsider], root: zipRoot,
                                destination: rootURL.appendingPathComponent("bad.zip"))
}
expect(!fileManager.fileExists(atPath: rootURL.appendingPathComponent("bad.zip").path),
       "被拒绝的 ZIP 不会留下半成品文件")

// MARK: - 4. Manifest JSON / CSV

print("-- manifest --")

// Mirror of DeliveryManifest / DeliveryManifestEntry. The delivery layer lives
// on top of UIKit types, so the shapes are pinned here instead: the key lists
// below are the contract the customer-facing manifest.json must satisfy.
struct TestEntry: Codable, Equatable {
    var sourceName: String
    var fileName: String
    var kind: String
    var width: Int
    var height: Int
    var bytes: Int
    var checksum: String
}

struct TestManifest: Codable, Equatable {
    var jobName: String
    var createdAt: Date
    var presetID: String
    var look: String
    var entries: [TestEntry]
    var anchorFrameCount: Int
    var appVersion: String
}

let sampleEntry = TestEntry(sourceName: "IMG_0001.JPG", fileName: "web/OPA_20260101_0001.jpg",
                            kind: "web", width: 2048, height: 1365,
                            bytes: 812_345, checksum: "CBF43926")
let sampleManifest = TestManifest(jobName: "客片 2026-01-01", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  presetID: "p02", look: "精致写真", entries: [sampleEntry],
                                  anchorFrameCount: 12, appVersion: "1.5")

var encodedManifest = Data()
expectNoThrow("编码 manifest.json") {
    encodedManifest = try DeliveryJSON.encoder().encode(sampleManifest)
}
let manifestText = String(data: encodedManifest, encoding: .utf8) ?? ""
expect(manifestText.contains("\"appVersion\""), "manifest.json 含 appVersion")
expect(manifestText.contains("\"anchorFrameCount\""), "manifest.json 含 anchorFrameCount")
expect(manifestText.contains("\"createdAt\""), "manifest.json 含 createdAt")
expect(manifestText.contains("T") && manifestText.contains("Z"),
       "createdAt is an ISO 8601 instant (…T…Z)")
expect(manifestText.contains("web/OPA_20260101_0001.jpg"),
       "Slashes in file paths are not escaped")

var decodedManifest: TestManifest?
expectNoThrow("解码 manifest.json") {
    decodedManifest = try DeliveryJSON.decoder().decode(TestManifest.self, from: encodedManifest)
}
expect(decodedManifest == sampleManifest, "manifest JSON round-trips through JSONEncoder/JSONDecoder")

var topLevelKeys: [String] = []
var entryKeys: [String] = []
if let raw = try? JSONSerialization.jsonObject(with: encodedManifest),
   let object = raw as? [String: Any] {
    topLevelKeys = object.keys.sorted()
    if let entries = object["entries"] as? [[String: Any]], let first = entries.first {
        entryKeys = first.keys.sorted()
    }
}
expectEqual(topLevelKeys,
            ["anchorFrameCount", "appVersion", "createdAt", "entries", "jobName", "look", "presetID"],
            "manifest.json has exactly the documented top-level keys")
expectEqual(entryKeys,
            ["bytes", "checksum", "fileName", "height", "kind", "sourceName", "width"],
            "manifest entries have exactly the documented keys")

expectEqual(DeliveryCSV.header, "source_name,file_name,kind,width,height,bytes,crc32",
            "manifest.csv header names every column")
expectEqual(DeliveryCSV.row([sampleEntry.sourceName, sampleEntry.fileName, sampleEntry.kind,
                             "2048", "1365", "812345", sampleEntry.checksum]),
            "IMG_0001.JPG,web/OPA_20260101_0001.jpg,web,2048,1365,812345,CBF43926",
            "CSV row joins plain fields with commas")
expectEqual(DeliveryCSV.field("a,b"), "\"a,b\"", "CSV quotes a field containing a comma")
expectEqual(DeliveryCSV.field("x\"y"), "\"x\"\"y\"", "CSV doubles internal quotes")
expectEqual(DeliveryCSV.field("line\nbreak"), "\"line\nbreak\"", "CSV quotes a field containing a newline")
expectEqual(DeliveryCSV.field("plain"), "plain", "CSV leaves a plain field unquoted")

// MARK: - 5. Proofing page

print("-- proofing page --")

expectEqual(RetouchProofingPage.escapeHTML("<script>alert(1)</script>"),
            "&lt;script&gt;alert(1)&lt;/script&gt;",
            "escapeHTML neutralises script tags")
expectEqual(RetouchProofingPage.escapeHTML("a&b\"c'd"),
            "a&amp;b&quot;c&#39;d",
            "escapeHTML covers ampersand, quotes and apostrophes")
expectEqual(RetouchProofingPage.escapeHTML("正常中文 123"), "正常中文 123",
            "escapeHTML leaves plain text untouched")

let evilItems = [
    RetouchProofingPage.Item(fileName: "../web/OPA_20260101_0001.jpg",
                             title: "IMG_0001.jpg", width: 2048, height: 1365),
    RetouchProofingPage.Item(fileName: "../web/x\" onload=\"alert(1).jpg",
                             title: "</script><script>alert(2)</script>", width: 10, height: 10)
]
let evilHTML = RetouchProofingPage.page(jobName: "客片 </title><script>alert(3)</script>",
                                        items: evilItems,
                                        watermarkNote: "水印 <b>样片</b>")

expect(evilHTML.hasPrefix("<!DOCTYPE html>"), "页面以 HTML5 doctype 开头")
expect(evilHTML.contains("<html lang=\"zh-CN\""), "页面声明 zh-CN 语言")
expect(evilHTML.contains("<meta charset=\"utf-8\">"), "页面声明 UTF-8 编码")
expect(!evilHTML.contains("</title><script>alert(3)"),
       "拍摄名里的 </title><script> 无法逃出标题")
expect(evilHTML.contains("&lt;/title&gt;&lt;script&gt;alert(3)&lt;/script&gt;"),
       "拍摄名被完整转义后原样显示")
expect(!evilHTML.contains("<script>alert"),
       "页面里不存在可执行的 alert 脚本（注入的名称已被转义）")
expect(!evilHTML.contains("onload=\"alert"),
       "属性注入无法生成 onload 处理器")
expect(evilHTML.contains("onload=&quot;alert"), "注入文本以无害的转义形式保留")
expect(!evilHTML.contains("<b>样片</b>"), "水印说明里的 <b> 不会变成标签")
expect(evilHTML.contains("&lt;b&gt;样片&lt;/b&gt;"), "水印说明被转义")
expect(evilHTML.contains("%22"), "文件名里的双引号在 src 中被 percent-encode")
expect(evilHTML.contains("data-file=\"OPA_20260101_0001.jpg\""),
       "data-file 保存的是要复制给客户的文件名（不含目录）")
expectEqual(countOccurrences(of: "class=\"card\"", in: evilHTML), 2,
            "每一项生成一张卡片")
expect(evilHTML.contains(">2</span>"), "卡片带顺序编号徽标")
expect(evilHTML.contains("点击放大"), "页面提示可以点击放大")
expect(evilHTML.contains("已选"), "页面显示已选数量标签")
expect(evilHTML.contains("复制选片结果"), "页面提供复制选片结果按钮")
expect(evilHTML.contains("localStorage"), "勾选状态保存在 localStorage")
expect(evilHTML.contains("execCommand"), "剪贴板有 textarea + execCommand 回退")
expect(!evilHTML.contains("http://") && !evilHTML.contains("https://"),
       "页面没有任何外链资源（离线可用、无 CDN）")
expect(!evilHTML.contains("<link"), "页面没有外部样式表")
expect(countOccurrences(of: "<script", in: evilHTML) == 1,
       "页面只有一个内联脚本块")

let proofingFolder = rootURL.appendingPathComponent("proofing", isDirectory: true)
let pageURL = proofingFolder.appendingPathComponent("index.html")
expectNoThrow("写出 proofing/index.html") {
    try RetouchProofingPage.build(jobName: "客片", items: evilItems,
                                  outputURL: pageURL, watermarkNote: nil)
}
expect(fileManager.fileExists(atPath: pageURL.path), "proofing/index.html 已落盘")
let pageText = (try? String(contentsOf: pageURL, encoding: .utf8)) ?? ""
expect(pageText.contains("<!DOCTYPE html>"), "落盘页面是完整 HTML")
expect(!pageText.contains("<script>alert"), "落盘页面同样无法被文件名注入")
expect(pageText.contains("<img src=\"../web/OPA_20260101_0001.jpg\""),
       "图片 src 指向 web/ 的相对路径")

expectNoThrow("覆盖写 proofing/index.html") {
    try RetouchProofingPage.build(jobName: "客片", items: evilItems,
                                  outputURL: pageURL, watermarkNote: "带水印样片")
}
let leftovers = (try? fileManager.contentsOfDirectory(atPath: proofingFolder.path)) ?? []
expect(leftovers.filter { $0.hasSuffix(".tmp") }.isEmpty, "写页面后不残留 .tmp 文件")
let overwritten = (try? String(contentsOf: pageURL, encoding: .utf8)) ?? ""
expect(overwritten.contains("带水印样片"), "覆盖写会更新页面内容")

// MARK: - Summary

_ = try? fileManager.removeItem(at: rootURL)

if failures == 0 {
    print("\nALL PASS (\(checks) checks)")
} else {
    print("\nFAILURES: \(failures) of \(checks) checks")
    exit(1)
}
