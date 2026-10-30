import Foundation

// MARK: - 预设模型

/// 一份导入后的 Lightroom 预设。
///
/// `look` 的字段与 `LightroomLook.swift` 的契约逐字一致（字段名、类型、默认值都不动），
/// 这里只负责把 XMP 里散落的 `crs:` 参数搬进这个结构，不参与任何像素计算。
struct LightroomPreset: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var group: String
    var sourceFileName: String
    var look: LightroomLook
}

/// Lightroom 预设 XMP 的解析与导出（纯 Foundation，没有第三方库）。
///
/// 为什么手写扫描而不用 `XMLParser`：
/// - 真实预设经常不是严格 XML：值写成 `+0.85`、属性用单引号、偶尔缺引号，
///   `XMLParser` 碰到这种文件会直接失败并丢掉整份预设；
/// - 我们只需要 `crs:` 命名空间下的参数和几条 `rdf:Seq`，扫描器更可控也更好测；
/// - 预设文件一般小于 100 KB，一次性转成 `[Character]` 足够快。
///
/// 兼容的写法：普通开始标签、自闭合标签、单/双引号、无引号值，
/// 以及 `crs:` 前缀的大小写变体（`CRS:` / `Crs:`）；
/// 键名本身大小写敏感（`Exposure2012` 只认这个写法）。
enum LightroomPresetParser {

    /// HSL 8 个色带的固定顺序，和 `LightroomLook.hslHue` 等数组的下标一一对应。
    private static let hslBands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    /// 单条曲线的点数上限（超出后按输入排序截断，避免畸形文件把曲线撑爆）。
    private static let curvePointLimit = 32

    // MARK: - 对外接口

    /// 解析一份 XMP 文本。
    ///
    /// - 识别成功返回预设；
    /// - 完全没有 `crs:` 调整参数时返回 `nil`，这样普通照片的 XMP 不会被误当成预设导入；
    /// - `crs:Name` / `crs:Group` 单独存在不算「调整参数」，仍然是 `nil`。
    static func parse(xmp: String, fileName: String = "") -> LightroomPreset? {
        let characters = Array(strippingByteOrderMark(xmp))
        let attributes = attributeValues(in: characters)
        var found = false

        /// 取一个数值参数：键存在就算「识别到了」，值解析失败则回落到调用处的默认值。
        func take(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let raw = attributes[key] else { return nil }
            found = true
            guard let value = parseNumber(raw) else { return nil }
            return clamp(value, range)
        }

        /// 新版键优先，旧版键兜底（例如 `Exposure2012` → `Exposure`）。
        func takeFirst(_ keys: [String], _ range: ClosedRange<Double>) -> Double? {
            for key in keys {
                if let value = take(key, range) {
                    return value
                }
            }
            return nil
        }

        var look = LightroomLook()

        // 基础影调
        look.exposure = takeFirst(["Exposure2012", "Exposure"], -5...5) ?? 0
        look.contrast = takeFirst(["Contrast2012", "Contrast"], -100...100) ?? 0
        look.highlights = takeFirst(["Highlights2012", "Highlights"], -100...100) ?? 0
        look.shadows = takeFirst(["Shadows2012", "Shadows"], -100...100) ?? 0
        look.whites = takeFirst(["Whites2012", "Whites"], -100...100) ?? 0
        look.blacks = takeFirst(["Blacks2012", "Blacks"], -100...100) ?? 0

        // 质感 / 色彩
        look.texture = take("Texture", -100...100) ?? 0
        look.clarity = takeFirst(["Clarity2012", "Clarity"], -100...100) ?? 0
        look.dehaze = take("Dehaze", -100...100) ?? 0
        look.vibrance = take("Vibrance", -100...100) ?? 0
        look.saturation = take("Saturation", -100...100) ?? 0

        // 参数曲线（四个分区滑块）
        look.parametricShadows = take("ParametricShadows", -100...100) ?? 0
        look.parametricDarks = take("ParametricDarks", -100...100) ?? 0
        look.parametricLights = take("ParametricLights", -100...100) ?? 0
        look.parametricHighlights = take("ParametricHighlights", -100...100) ?? 0

        // HSL 8 带
        var hue = Array(repeating: 0.0, count: hslBands.count)
        var saturation = Array(repeating: 0.0, count: hslBands.count)
        var luminance = Array(repeating: 0.0, count: hslBands.count)
        for (index, band) in hslBands.enumerated() {
            if let value = take("HueAdjustment" + band, -100...100) { hue[index] = value }
            if let value = take("SaturationAdjustment" + band, -100...100) { saturation[index] = value }
            if let value = take("LuminanceAdjustment" + band, -100...100) { luminance[index] = value }
        }
        look.hslHue = hue
        look.hslSaturation = saturation
        look.hslLuminance = luminance

        // 分离色调：新版写 ColorGrade*，旧版写 SplitToning*，新版优先。
        look.shadowHue = takeFirst(["ColorGradeShadowHue", "SplitToningShadowHue"], 0...360) ?? 0
        look.shadowSaturation = takeFirst(["ColorGradeShadowSat", "ColorGradeShadowSaturation",
                                           "SplitToningShadowSaturation"], 0...100) ?? 0
        look.highlightHue = takeFirst(["ColorGradeHighlightHue", "SplitToningHighlightHue"], 0...360) ?? 0
        look.highlightSaturation = takeFirst(["ColorGradeHighlightSat", "ColorGradeHighlightSaturation",
                                              "SplitToningHighlightSaturation"], 0...100) ?? 0
        look.splitBalance = takeFirst(["ColorGradeBalance", "SplitToningBalance"], -100...100) ?? 0

        // 细节
        look.sharpness = take("Sharpness", 0...150) ?? 0
        look.sharpenRadius = take("SharpenRadius", 0.5...3.0) ?? 1.0
        look.sharpenMasking = take("SharpenEdgeMasking", 0...100) ?? 0

        // 效果
        look.grain = take("GrainAmount", 0...100) ?? 0
        look.grainSize = take("GrainSize", 0...100) ?? 25
        // 只认 PostCrop 那个暗角；crs:VignetteAmount 是别的语义，混进来会多一圈黑边。
        look.vignette = take("PostCropVignetteAmount", -100...100) ?? 0

        // 曲线：复合曲线 / 分通道各自独立，互不污染。
        if let inner = innerContent(ofTag: "ToneCurvePV2012", in: characters) {
            found = true
            look.toneCurve = curvePoints(from: listItemTexts(in: inner))
        } else if let inner = innerContent(ofTag: "ToneCurve", in: characters) {
            // 老版本 Lightroom 的复合曲线叫 crs:ToneCurve，兼容一下。
            found = true
            look.toneCurve = curvePoints(from: listItemTexts(in: inner))
        }
        if let inner = innerContent(ofTag: "ToneCurvePV2012Red", in: characters) {
            found = true
            look.curveRed = curvePoints(from: listItemTexts(in: inner))
        }
        if let inner = innerContent(ofTag: "ToneCurvePV2012Green", in: characters) {
            found = true
            look.curveGreen = curvePoints(from: listItemTexts(in: inner))
        }
        if let inner = innerContent(ofTag: "ToneCurvePV2012Blue", in: characters) {
            found = true
            look.curveBlue = curvePoints(from: listItemTexts(in: inner))
        }

        guard found else { return nil }

        let name = resolvedText(tag: "Name", characters: characters, attributes: attributes)
        let group = resolvedText(tag: "Group", characters: characters, attributes: attributes)
        let fallbackName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName: String
        if !name.isEmpty {
            finalName = name
        } else if !fallbackName.isEmpty {
            finalName = fallbackName
        } else {
            finalName = "未命名预设"
        }
        // LightroomLook 自己也带一个 name，同步过去，界面直接用 look 展示时不用再拼一次。
        look.name = finalName

        return LightroomPreset(id: UUID(),
                               name: finalName,
                               group: group,
                               sourceFileName: fileName,
                               look: look)
    }

    /// 读取磁盘上的预设文件。
    ///
    /// 只接受 XMP 文本（`.xmp` 或任何内容是 XMP 的文本文件）；
    /// `.lrtemplate` 是 Lua 文本，里面没有 `crs:` 键时会自然解析失败返回 `nil`，
    /// 不认识的二进制文件同样返回 `nil`，不会抛异常也不会崩。
    static func parse(contentsOf url: URL) -> LightroomPreset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return parse(xmp: text, fileName: url.lastPathComponent)
        }
        // 少数老预设是 Latin-1 / Windows-1252，再兜一次。
        if let text = String(data: data, encoding: .isoLatin1) {
            return parse(xmp: text, fileName: url.lastPathComponent)
        }
        return nil
    }

    /// 反向导出成 Lightroom 能读的 XMP。
    ///
    /// 规则：
    /// - 只写非零字段（和已知默认值相等的半径 / 颗粒大小也不写），避免导出文件塞满噪声；
    /// - 数值统一保留 1 位小数（和 LR 自己的写法一致）；
    /// - 曲线写成 `rdf:Seq` / `rdf:li`，每个点是 `"in, out"`；
    /// - 输出能被自己的 `parse` 原样读回（1 位小数能精确表示的值，误差为 0）。
    static func exportXMP(_ preset: LightroomPreset) -> String {
        let look = preset.look
        var pairs: [(String, String)] = []

        let cleanedName = cleanedText(preset.name)
        pairs.append(("crs:Name", escaping(cleanedName.isEmpty ? "未命名预设" : cleanedName)))
        let cleanedGroup = cleanedText(preset.group)
        if !cleanedGroup.isEmpty {
            pairs.append(("crs:Group", escaping(cleanedGroup)))
        }

        /// 写入一个数值参数：先 clamp 到合法范围，再判断是否真的需要写。
        func add(_ key: String, _ value: Double, _ range: ClosedRange<Double>) {
            let text = number(clamp(value, range))
            guard text != "0.0" else { return }
            pairs.append(("crs:" + key, text))
        }

        add("Exposure2012", look.exposure, -5...5)
        add("Contrast2012", look.contrast, -100...100)
        add("Highlights2012", look.highlights, -100...100)
        add("Shadows2012", look.shadows, -100...100)
        add("Whites2012", look.whites, -100...100)
        add("Blacks2012", look.blacks, -100...100)
        add("Texture", look.texture, -100...100)
        add("Clarity2012", look.clarity, -100...100)
        add("Dehaze", look.dehaze, -100...100)
        add("Vibrance", look.vibrance, -100...100)
        add("Saturation", look.saturation, -100...100)
        add("ParametricShadows", look.parametricShadows, -100...100)
        add("ParametricDarks", look.parametricDarks, -100...100)
        add("ParametricLights", look.parametricLights, -100...100)
        add("ParametricHighlights", look.parametricHighlights, -100...100)
        add("SplitToningShadowHue", look.shadowHue, 0...360)
        add("SplitToningShadowSaturation", look.shadowSaturation, 0...100)
        add("SplitToningHighlightHue", look.highlightHue, 0...360)
        add("SplitToningHighlightSaturation", look.highlightSaturation, 0...100)
        add("SplitToningBalance", look.splitBalance, -100...100)
        add("Sharpness", look.sharpness, 0...150)
        // 半径默认 1.0、颗粒大小默认 25：和默认值一致就不写，LR 读的时候自然回落到默认。
        if number(clamp(look.sharpenRadius, 0.5...3.0)) != number(1.0) {
            pairs.append(("crs:SharpenRadius", number(clamp(look.sharpenRadius, 0.5...3.0))))
        }
        add("SharpenEdgeMasking", look.sharpenMasking, 0...100)
        add("GrainAmount", look.grain, 0...100)
        if number(clamp(look.grainSize, 0...100)) != number(25.0) {
            pairs.append(("crs:GrainSize", number(clamp(look.grainSize, 0...100))))
        }
        add("PostCropVignetteAmount", look.vignette, -100...100)

        for (index, band) in hslBands.enumerated() {
            add("HueAdjustment" + band, hslValue(look.hslHue, index), -100...100)
            add("SaturationAdjustment" + band, hslValue(look.hslSaturation, index), -100...100)
            add("LuminanceAdjustment" + band, hslValue(look.hslLuminance, index), -100...100)
        }

        var children: [String] = []
        appendCurveElement(&children, tag: "crs:ToneCurvePV2012", points: look.toneCurve)
        appendCurveElement(&children, tag: "crs:ToneCurvePV2012Red", points: look.curveRed)
        appendCurveElement(&children, tag: "crs:ToneCurvePV2012Green", points: look.curveGreen)
        appendCurveElement(&children, tag: "crs:ToneCurvePV2012Blue", points: look.curveBlue)

        var lines: [String] = []
        lines.append("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>")
        lines.append("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"OutdoorPhotoAssistant\">")
        lines.append(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">")

        var description: [String] = []
        description.append("  <rdf:Description rdf:about=\"\"")
        description.append("    xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"")
        for (key, value) in pairs {
            description.append("    \(key)=\"\(value)\"")
        }

        if children.isEmpty {
            // 没有子元素就自闭合，省掉一坨空标签。
            description[description.count - 1] += " />"
            lines.append(contentsOf: description)
        } else {
            // 有子元素时必须先把开始标签收尾，否则后面的 rdf:Seq 会被当成属性，
            // 导出的 XMP 直接不合法（这是本文件踩过的一个坑，测试台 15h 覆盖它）。
            description[description.count - 1] += ">"
            lines.append(contentsOf: description)
            lines.append(contentsOf: children)
            lines.append("  </rdf:Description>")
        }
        lines.append(" </rdf:RDF>")
        lines.append("</x:xmpmeta>")
        lines.append("<?xpacket end=\"w\"?>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 数值健壮性

    /// 统一走 Double 解析：容忍 `+0.85`、`"0.85"`、`.85`、`nan`、乱码。
    /// 非有限值（nan / inf）和解析不出来的乱码一律返回 `nil`，由调用处回落到默认值。
    private static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("+") {
            text = String(text.dropFirst())
            text = text.trimmingCharacters(in: .whitespaces)
        }
        // 有的预设把值又套了一层引号，扫掉。
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix(".") {
            text = "0" + text
        } else if text.hasPrefix("-.") {
            text = "-0" + String(text.dropFirst())
        } else if text.hasPrefix("+.") {
            text = "0" + String(text.dropFirst())
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    /// 1 位小数的确定性格式化：不用 `String(format:)`，避免跟随系统区域把小数点写成逗号。
    private static func number(_ value: Double) -> String {
        guard value.isFinite, Swift.abs(value) < 100_000 else { return "0.0" }
        let units = Int((value * 10).rounded())
        let sign = units < 0 ? "-" : ""
        let magnitude = Swift.abs(units)
        return "\(sign)\(magnitude / 10).\(magnitude % 10)"
    }

    private static func hslValue(_ values: [Double], _ index: Int) -> Double {
        index < values.count ? values[index] : 0
    }

    // MARK: - 曲线

    /// 曲线点标准化：clamp 到 0...255 → 同 x 保留最后一个 → 按 x 升序 → 最多 32 个。
    private static func preparedCurve(_ points: [LightroomCurvePoint]) -> [LightroomCurvePoint] {
        var byInput: [Double: LightroomCurvePoint] = [:]
        for point in points {
            guard point.input.isFinite, point.output.isFinite else { continue }
            let prepared = LightroomCurvePoint(input: clamp(point.input, 0...255),
                                               output: clamp(point.output, 0...255))
            byInput[prepared.input] = prepared
        }
        var list = byInput.keys.sorted().compactMap { byInput[$0] }
        if list.count > curvePointLimit {
            list = Array(list.prefix(curvePointLimit))
        }
        return list
    }

    /// 把 `rdf:li` 里的 `"x, y"` 拆成曲线点。
    /// 见过 `"x,y"`、`" x , y "`，也见过只有空格的写法，都吃掉。
    private static func curvePoints(from items: [String]) -> [LightroomCurvePoint] {
        var points: [LightroomCurvePoint] = []
        for item in items {
            let raw = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            var components = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if components.count < 2 {
                components = raw.split(whereSeparator: { $0.isWhitespace })
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            guard components.count >= 2,
                  let input = parseNumber(components[0]),
                  let output = parseNumber(components[1]) else { continue }
            points.append(LightroomCurvePoint(input: input, output: output))
        }
        return preparedCurve(points)
    }

    private static func appendCurveElement(_ lines: inout [String],
                                           tag: String,
                                           points: [LightroomCurvePoint]) {
        let prepared = preparedCurve(points)
        guard !prepared.isEmpty else { return }
        lines.append("   <\(tag)>")
        lines.append("    <rdf:Seq>")
        for point in prepared {
            lines.append("     <rdf:li>\(number(point.input)), \(number(point.output))</rdf:li>")
        }
        lines.append("    </rdf:Seq>")
        lines.append("   </\(tag)>")
    }

    // MARK: - 属性扫描

    /// 扫描整份文本里的 `crs:Key="Value"`。
    ///
    /// 细节：
    /// - 前缀 `crs:` 大小写不敏感，键名大小写敏感；
    /// - 值支持双引号、单引号、无引号；引号没闭合就取到行尾（容忍残缺文件）；
    /// - 同名键只认第一个，避免后面的片段串味。
    private static func attributeValues(in characters: [Character]) -> [String: String] {
        var result: [String: String] = [:]
        let count = characters.count
        var index = 0
        while index < count {
            guard isCRSPrefix(characters, at: index) else {
                index += 1
                continue
            }
            var cursor = index + 4
            var name = ""
            while cursor < count, isNameCharacter(characters[cursor]) {
                name.append(characters[cursor])
                cursor += 1
            }
            var probe = cursor
            while probe < count, characters[probe].isWhitespace {
                probe += 1
            }
            guard probe < count, characters[probe] == "=" else {
                // `<crs:ToneCurvePV2012>` 这种元素标签，跳过前缀继续扫。
                index = Swift.max(index + 4, cursor)
                continue
            }
            probe += 1
            while probe < count, characters[probe].isWhitespace {
                probe += 1
            }
            var value = ""
            if probe < count, characters[probe] == "\"" || characters[probe] == "'" {
                let quote = characters[probe]
                probe += 1
                while probe < count, characters[probe] != quote, characters[probe] != "\n" {
                    value.append(characters[probe])
                    probe += 1
                }
                if probe < count, characters[probe] == quote {
                    probe += 1
                }
            } else {
                while probe < count,
                      !characters[probe].isWhitespace,
                      characters[probe] != ">",
                      characters[probe] != "/" {
                    value.append(characters[probe])
                    probe += 1
                }
            }
            if !name.isEmpty, result[name] == nil {
                result[name] = value
            }
            index = Swift.max(probe, index + 4)
        }
        return result
    }

    private static func isCRSPrefix(_ characters: [Character], at index: Int) -> Bool {
        guard index + 3 < characters.count else { return false }
        let c = characters[index]
        let r = characters[index + 1]
        let s = characters[index + 2]
        let colon = characters[index + 3]
        return (c == "c" || c == "C")
            && (r == "r" || r == "R")
            && (s == "s" || s == "S")
            && colon == ":"
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return character == "_" || character == "-" || character == "."
    }

    // MARK: - 子元素扫描

    /// 取 `<crs:Tag ...> ... </crs:Tag>` 之间的原始字符；自闭合标签返回空内容，找不到返回 nil。
    ///
    /// 标签名按完整本地名精确比对，所以 `ToneCurvePV2012` 不会误伤
    /// `ToneCurvePV2012Red` / `ToneCurvePV2012Green` / `ToneCurvePV2012Blue`。
    private static func innerContent(ofTag tag: String, in characters: [Character]) -> [Character]? {
        let count = characters.count
        var index = 0
        while index < count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }
            // 注释整段跳过，别让注释里的假标签骗了扫描器。
            if index + 3 < count, characters[index + 1] == "!", characters[index + 2] == "-", characters[index + 3] == "-" {
                var skip = index + 4
                while skip + 2 < count,
                      !(characters[skip] == "-" && characters[skip + 1] == "-" && characters[skip + 2] == ">") {
                    skip += 1
                }
                index = Swift.min(skip + 3, count)
                continue
            }
            var cursor = index + 1
            var firstName = ""
            while cursor < count, isNameCharacter(characters[cursor]) {
                firstName.append(characters[cursor])
                cursor += 1
            }
            var local = firstName
            if cursor < count, characters[cursor] == ":" {
                cursor += 1
                var secondName = ""
                while cursor < count, isNameCharacter(characters[cursor]) {
                    secondName.append(characters[cursor])
                    cursor += 1
                }
                local = secondName
            }
            // 找到这个标签的 '>'，属性里的引号内容不参与判断。
            var end = cursor
            var quote: Character?
            while end < count {
                let current = characters[end]
                if let active = quote {
                    if current == active { quote = nil }
                } else if current == "\"" || current == "'" {
                    quote = current
                } else if current == ">" {
                    break
                }
                end += 1
            }
            guard end < count else { return nil }
            let selfClosing = end > index && characters[end - 1] == "/"
            if local == tag {
                if selfClosing { return [] }
                let bodyStart = end + 1
                if let close = closingTagStart(ofTag: tag, in: characters, from: bodyStart) {
                    return Array(characters[bodyStart..<close])
                }
                return nil
            }
            index = end + 1
        }
        return nil
    }

    private static func closingTagStart(ofTag tag: String, in characters: [Character], from start: Int) -> Int? {
        let count = characters.count
        var index = start
        while index < count {
            guard index + 1 < count, characters[index] == "<", characters[index + 1] == "/" else {
                index += 1
                continue
            }
            var cursor = index + 2
            var firstName = ""
            while cursor < count, isNameCharacter(characters[cursor]) {
                firstName.append(characters[cursor])
                cursor += 1
            }
            var local = firstName
            if cursor < count, characters[cursor] == ":" {
                cursor += 1
                var secondName = ""
                while cursor < count, isNameCharacter(characters[cursor]) {
                    secondName.append(characters[cursor])
                    cursor += 1
                }
                local = secondName
            }
            if local == tag {
                return index
            }
            index = Swift.max(cursor, index + 2)
        }
        return nil
    }

    /// 取一段子元素里所有 `rdf:li` 的文本（曲线点、名称、分组都是这个结构）。
    private static func listItemTexts(in characters: [Character]) -> [String] {
        var items: [String] = []
        let count = characters.count
        var index = 0
        while index < count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }
            var cursor = index + 1
            var firstName = ""
            while cursor < count, isNameCharacter(characters[cursor]) {
                firstName.append(characters[cursor])
                cursor += 1
            }
            var local = firstName
            if cursor < count, characters[cursor] == ":" {
                cursor += 1
                var secondName = ""
                while cursor < count, isNameCharacter(characters[cursor]) {
                    secondName.append(characters[cursor])
                    cursor += 1
                }
                local = secondName
            }
            var end = cursor
            var quote: Character?
            while end < count {
                let current = characters[end]
                if let active = quote {
                    if current == active { quote = nil }
                } else if current == "\"" || current == "'" {
                    quote = current
                } else if current == ">" {
                    break
                }
                end += 1
            }
            guard end < count else { break }
            let selfClosing = end > index && characters[end - 1] == "/"
            if local == "li", !selfClosing {
                var body = ""
                var scan = end + 1
                while scan < count, characters[scan] != "<" {
                    body.append(characters[scan])
                    scan += 1
                }
                items.append(body)
                index = scan
                continue
            }
            index = end + 1
        }
        return items
    }

    // MARK: - 文本清洗

    /// 名称 / 分组：优先子元素里的 `rdf:li`，其次属性，最后交给文件名兜底。
    private static func resolvedText(tag: String,
                                     characters: [Character],
                                     attributes: [String: String]) -> String {
        if let inner = innerContent(ofTag: tag, in: characters) {
            let items = listItemTexts(in: inner)
            let candidate = items.first(where: { !cleanedText($0).isEmpty })
            let text = cleanedText(candidate ?? String(inner))
            if !text.isEmpty { return text }
        }
        if let raw = attributes[tag] {
            let text = cleanedText(raw)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// 去 CDATA、解实体、折叠空白（预设名称里常有换行和缩进）。
    private static func cleanedText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<![CDATA[", with: "")
        text = text.replacingOccurrences(of: "]]>", with: "")
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\r", with: " ")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ raw: String) -> String {
        var text = raw
        // 先解 &lt; 之类的命名实体，最后再解 &amp;，保证只解一层（和 XML 语义一致）。
        let named = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'")]
        for (entity, value) in named {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if text.contains("&#") {
            text = decodeNumericEntities(text)
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "&", index + 1 < characters.count, characters[index + 1] == "#" else {
                output.append(characters[index])
                index += 1
                continue
            }
            var cursor = index + 2
            var isHex = false
            if cursor < characters.count, characters[cursor] == "x" || characters[cursor] == "X" {
                isHex = true
                cursor += 1
            }
            var digits = ""
            while cursor < characters.count, characters[cursor] != ";" {
                digits.append(characters[cursor])
                cursor += 1
            }
            if cursor < characters.count,
               !digits.isEmpty,
               let code = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(code) {
                // 走 String 再拼，避免依赖 Character 从 Unicode.Scalar 的初始化器版本差异。
                output += String(scalar)
                index = cursor + 1
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return output
    }

    /// XML 属性值转义。
    private static func escaping(_ text: String) -> String {
        var output = ""
        for character in text {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            default: output.append(character)
            }
        }
        return output
    }

    private static func strippingByteOrderMark(_ text: String) -> String {
        if text.hasPrefix("\u{FEFF}") {
            return String(text.dropFirst())
        }
        return text
    }
}
