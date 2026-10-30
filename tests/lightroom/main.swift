import Foundation

// Lightroom 预设解析自测台（Foundation-only，不进 app target）。
//
// 跑法：
//   swiftc -D TEST_STUBS tests/lightroom/main.swift \
//       OutdoorPhotoAssistant/Core/CommercialRetouch/LightroomPresetParser.swift \
//       -o /tmp/lr && /tmp/lr
//
// 说明：
// - 真正的 App 里 `LightroomLook` / `LightroomCurvePoint` 由 `LightroomLook.swift` 提供；
//   测试台只编译解析器，所以用 `-D TEST_STUBS` 打开下面那份逐字段一致的替身。
// - 不定义 TEST_STUBS 时替身不参与编译（真机工程里用的是真身）。
// - 刻意不引用 `LightroomPresetStore`：它有磁盘 IO，本台只测纯解析与 clamp。

#if TEST_STUBS
struct LightroomCurvePoint: Codable, Equatable, Hashable {
    var input: Double
    var output: Double
    init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

struct LightroomLook: Codable, Equatable, Hashable {
    var name: String = ""
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var texture: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var parametricShadows: Double = 0
    var parametricDarks: Double = 0
    var parametricLights: Double = 0
    var parametricHighlights: Double = 0
    var toneCurve: [LightroomCurvePoint] = []
    var curveRed: [LightroomCurvePoint] = []
    var curveGreen: [LightroomCurvePoint] = []
    var curveBlue: [LightroomCurvePoint] = []
    var hslHue: [Double] = Array(repeating: 0, count: 8)
    var hslSaturation: [Double] = Array(repeating: 0, count: 8)
    var hslLuminance: [Double] = Array(repeating: 0, count: 8)
    var shadowHue: Double = 0
    var shadowSaturation: Double = 0
    var highlightHue: Double = 0
    var highlightSaturation: Double = 0
    var splitBalance: Double = 0
    var sharpness: Double = 0
    var sharpenRadius: Double = 1.0
    var sharpenMasking: Double = 0
    var grain: Double = 0
    var grainSize: Double = 25
    var vignette: Double = 0
    init() {}
}
#endif

// MARK: - 断言台

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

func near(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

func curveSignature(_ points: [LightroomCurvePoint]) -> [(Double, Double)] {
    points.map { ($0.input, $0.output) }
}

func sameCurve(_ points: [LightroomCurvePoint], _ expected: [(Double, Double)]) -> Bool {
    guard points.count == expected.count else { return false }
    for (index, point) in points.enumerated() {
        if !near(point.input, expected[index].0) || !near(point.output, expected[index].1) {
            return false
        }
    }
    return true
}

func scalarSignature(_ look: LightroomLook) -> [(String, Double)] {
    var pairs: [(String, Double)] = []
    pairs.append(("exposure", look.exposure))
    pairs.append(("contrast", look.contrast))
    pairs.append(("highlights", look.highlights))
    pairs.append(("shadows", look.shadows))
    pairs.append(("whites", look.whites))
    pairs.append(("blacks", look.blacks))
    pairs.append(("texture", look.texture))
    pairs.append(("clarity", look.clarity))
    pairs.append(("dehaze", look.dehaze))
    pairs.append(("vibrance", look.vibrance))
    pairs.append(("saturation", look.saturation))
    pairs.append(("parametricShadows", look.parametricShadows))
    pairs.append(("parametricDarks", look.parametricDarks))
    pairs.append(("parametricLights", look.parametricLights))
    pairs.append(("parametricHighlights", look.parametricHighlights))
    pairs.append(("shadowHue", look.shadowHue))
    pairs.append(("shadowSaturation", look.shadowSaturation))
    pairs.append(("highlightHue", look.highlightHue))
    pairs.append(("highlightSaturation", look.highlightSaturation))
    pairs.append(("splitBalance", look.splitBalance))
    pairs.append(("sharpness", look.sharpness))
    pairs.append(("sharpenRadius", look.sharpenRadius))
    pairs.append(("sharpenMasking", look.sharpenMasking))
    pairs.append(("grain", look.grain))
    pairs.append(("grainSize", look.grainSize))
    pairs.append(("vignette", look.vignette))
    for index in 0..<look.hslHue.count {
        pairs.append(("hslHue[\(index)]", look.hslHue[index]))
    }
    for index in 0..<look.hslSaturation.count {
        pairs.append(("hslSaturation[\(index)]", look.hslSaturation[index]))
    }
    for index in 0..<look.hslLuminance.count {
        pairs.append(("hslLuminance[\(index)]", look.hslLuminance[index]))
    }
    return pairs
}

// MARK: - 1. 真实胶片预设片段

let filmXMP = """
<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    crs:Exposure2012="+0.85"
    crs:Contrast2012="-12"
    crs:Highlights2012="-25"
    crs:Shadows2012="31"
    crs:Whites2012="12"
    crs:Blacks2012="-8"
    crs:Texture="6"
    crs:Clarity2012="8"
    crs:Dehaze="14"
    crs:Vibrance="18"
    crs:Saturation="-4"
    crs:ParametricShadows="-10"
    crs:ParametricDarks="-5"
    crs:ParametricLights="7"
    crs:ParametricHighlights="11"
    crs:Sharpness="42"
    crs:SharpenRadius="1.4"
    crs:SharpenEdgeMasking="17"
    crs:GrainAmount="12"
    crs:GrainSize="30"
    crs:VignetteAmount="-70"
    crs:PostCropVignetteAmount="-23">
   <crs:Name>
    <rdf:Alt>
     <rdf:li xml:lang="x-default">胶片暖阳</rdf:li>
    </rdf:Alt>
   </crs:Name>
   <crs:Group>
    <rdf:Alt>
     <rdf:li xml:lang="x-default">胶片</rdf:li>
    </rdf:Alt>
   </crs:Group>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""

let filmPreset = LightroomPresetParser.parse(xmp: filmXMP, fileName: "胶片暖阳.xmp")
expect(filmPreset != nil, "1a 真实胶片预设片段能解析成预设")
if let film = filmPreset {
    expect(near(film.look.exposure, 0.85), "1b Exposure2012=+0.85 解析为 0.85")
    expect(near(film.look.contrast, -12), "1c Contrast2012=-12")
    expect(near(film.look.clarity, 8), "1d Clarity2012=8")
    expect(near(film.look.dehaze, 14), "1e Dehaze=14")
    expect(near(film.look.highlights, -25) && near(film.look.shadows, 31)
        && near(film.look.whites, 12) && near(film.look.blacks, -8),
           "1f 高光/阴影/白色/黑色四个滑块都能落位")
    expect(near(film.look.texture, 6) && near(film.look.vibrance, 18) && near(film.look.saturation, -4),
           "1g Texture/Vibrance/Saturation 落位")
    expect(near(film.look.parametricShadows, -10) && near(film.look.parametricDarks, -5)
        && near(film.look.parametricLights, 7) && near(film.look.parametricHighlights, 11),
           "1h 参数曲线四个分区落位")
    expect(near(film.look.sharpness, 42) && near(film.look.sharpenRadius, 1.4)
        && near(film.look.sharpenMasking, 17),
           "1i Sharpness / SharpenRadius / SharpenEdgeMasking 落位")
    expect(near(film.look.grain, 12) && near(film.look.grainSize, 30), "1j GrainAmount / GrainSize 落位")
    expect(near(film.look.vignette, -23), "1k vignette 取 PostCropVignetteAmount 而不是 VignetteAmount")
    expect(film.name == "胶片暖阳", "1l crs:Name 子元素里的名字取到了")
    expect(film.group == "胶片", "1m crs:Group 子元素里的分组取到了")
    expect(film.sourceFileName == "胶片暖阳.xmp", "1n 源文件名被保留")
    expect(film.look.name == "胶片暖阳", "1o look.name 与预设名同步")
    expect(film.look.toneCurve.isEmpty && film.look.curveRed.isEmpty, "1p 没有曲线时曲线数组为空")
}

// MARK: - 2. 自闭合标签

let selfClosingXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="0.4" crs:Contrast2012="-3" crs:Clarity2012="5" />
"""
let selfClosing = LightroomPresetParser.parse(xmp: selfClosingXMP, fileName: "self.xmp")
expect(selfClosing != nil, "2a 自闭合 rdf:Description 能解析")
if let preset = selfClosing {
    expect(near(preset.look.exposure, 0.4) && near(preset.look.contrast, -3) && near(preset.look.clarity, 5),
           "2b 自闭合标签里的三个值正确")
    expect(near(preset.look.sharpenRadius, 1.0) && near(preset.look.grainSize, 25),
           "2c 没写的字段回落到默认值（半径 1.0 / 颗粒 25）")
}

// MARK: - 3. 复合曲线 4 个点

let curveXMP = """
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="0.2">
   <crs:ToneCurvePV2012>
    <rdf:Seq>
     <rdf:li>0, 0</rdf:li>
     <rdf:li>32, 22</rdf:li>
     <rdf:li>128, 140</rdf:li>
     <rdf:li>255, 255</rdf:li>
    </rdf:Seq>
   </crs:ToneCurvePV2012>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""
let curvePreset = LightroomPresetParser.parse(xmp: curveXMP)
expect(curvePreset?.look.toneCurve.count == 4, "3a 复合曲线解析出 4 个点")
if let curve = curvePreset?.look.toneCurve {
    expect(sameCurve(curve, [(0, 0), (32, 22), (128, 140), (255, 255)]),
           "3b 复合曲线 4 个点的顺序和值都对")
    expect(curve[1].input == 32 && curve[1].output == 22, "3c 第 2 个点是 32 → 22")
}
expect(curvePreset?.look.curveRed.isEmpty == true, "3d 只写复合曲线时红通道为空")

// MARK: - 4. 分通道曲线不污染复合曲线

let channelXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="0.1">
 <crs:ToneCurvePV2012>
  <rdf:Seq>
   <rdf:li>0, 0</rdf:li>
   <rdf:li>255, 255</rdf:li>
  </rdf:Seq>
 </crs:ToneCurvePV2012>
 <crs:ToneCurvePV2012Red>
  <rdf:Seq>
   <rdf:li>0, 8</rdf:li>
   <rdf:li>255, 240</rdf:li>
  </rdf:Seq>
 </crs:ToneCurvePV2012Red>
 <crs:ToneCurvePV2012Blue>
  <rdf:Seq>
   <rdf:li>64, 70</rdf:li>
  </rdf:Seq>
 </crs:ToneCurvePV2012Blue>
</rdf:Description>
"""
let channelPreset = LightroomPresetParser.parse(xmp: channelXMP)
if let look = channelPreset?.look {
    expect(look.toneCurve.count == 2, "4a 复合曲线只拿到自己的 2 个点")
    expect(sameCurve(look.curveRed, [(0, 8), (255, 240)]), "4b ToneCurvePV2012Red 的点只进 curveRed")
    expect(sameCurve(look.curveBlue, [(64, 70)]), "4c ToneCurvePV2012Blue 的点只进 curveBlue")
    expect(look.curveGreen.isEmpty, "4d 没写的绿通道为空")
} else {
    expect(false, "4e 分通道曲线预设应该能解析")
}

// MARK: - 5. 曲线乱序 + 重复 x

let messyCurveXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="0.3">
 <crs:ToneCurvePV2012>
  <rdf:Seq>
   <rdf:li>128, 130</rdf:li>
   <rdf:li>32, 40</rdf:li>
   <rdf:li> 32 , 44 </rdf:li>
   <rdf:li>0,0</rdf:li>
  </rdf:Seq>
 </crs:ToneCurvePV2012>
</rdf:Description>
"""
let messy = LightroomPresetParser.parse(xmp: messyCurveXMP)?.look.toneCurve ?? []
expect(messy.count == 3, "5a 乱序 + 重复 x 去重后剩 3 个点")
expect(sameCurve(messy, [(0, 0), (32, 44), (128, 130)]), "5b 按输入排序，同 x 只留最后一个")
expect(messy.first?.input == 0, "5c 排最前的输入是 0")

// MARK: - 6. HSL 色带下标

let hslXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
  crs:HueAdjustmentRed="10"
  crs:HueAdjustmentOrange="-12"
  crs:HueAdjustmentYellow="3"
  crs:HueAdjustmentGreen="4"
  crs:HueAdjustmentAqua="5"
  crs:HueAdjustmentBlue="6"
  crs:HueAdjustmentPurple="7"
  crs:HueAdjustmentMagenta="8"
  crs:SaturationAdjustmentOrange="20"
  crs:LuminanceAdjustmentBlue="9" />
"""
let hslPreset = LightroomPresetParser.parse(xmp: hslXMP)
expect(hslPreset?.look.hslHue.count == 8, "6a HSL 色带数组固定 8 个")
expect(hslPreset?.look.hslHue[1] == -12, "6b HueAdjustmentOrange 落在 hslHue[1]")
expect(hslPreset?.look.hslHue[0] == 10 && hslPreset?.look.hslHue[7] == 8, "6c 红/品红分别落在 [0] / [7]")
expect(hslPreset?.look.hslSaturation[1] == 20, "6d SaturationAdjustmentOrange 落在 hslSaturation[1]")
expect(hslPreset?.look.hslLuminance[5] == 9, "6e LuminanceAdjustmentBlue 落在 hslLuminance[5]")

// MARK: - 7. 无关键被忽略

let speedXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Speed="1" crs:ProcessVersion="11.0" crs:Exposure2012="0.5" />
"""
let speedPreset = LightroomPresetParser.parse(xmp: speedXMP)
expect(speedPreset != nil, "8a 带 Speed 的预设照常解析")
expect(near(speedPreset?.look.exposure ?? 0, 0.5), "8b Speed / ProcessVersion 不干扰数值")
expect(speedPreset?.look.clarity == 0 && speedPreset?.look.vibrance == 0, "8c Speed 类键没有被塞进任何字段")
let speedOnlyXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Speed="1" crs:PresetType="Normal" />
"""
expect(LightroomPresetParser.parse(xmp: speedOnlyXMP) == nil, "8d 只有 Speed/PresetType 时返回 nil")

// MARK: - 8. 越界 clamp

let clampedXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
  crs:Exposure2012="99"
  crs:Sharpness="500"
  crs:SharpenRadius="9"
  crs:GrainAmount="-40"
  crs:Contrast2012="-500"
  crs:PostCropVignetteAmount="300" />
"""
let clamped = LightroomPresetParser.parse(xmp: clampedXMP)?.look
expect(clamped?.exposure == 5.0, "9a Exposure2012=99 被 clamp 到 5.0")
expect(clamped?.sharpness == 150.0, "9b Sharpness=500 被 clamp 到 150")
expect(clamped?.sharpenRadius == 3.0, "9c SharpenRadius=9 被 clamp 到 3.0")
expect(clamped?.grain == 0.0, "9d GrainAmount=-40 被 clamp 到 0")
expect(clamped?.contrast == -100.0, "9e Contrast2012=-500 被 clamp 到 -100")
expect(clamped?.vignette == 100.0, "9f PostCropVignetteAmount=300 被 clamp 到 100")

// MARK: - 9. NaN / 乱码

let garbageXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
  crs:Exposure2012="nan"
  crs:Clarity2012="###"
  crs:Dehaze="inf"
  crs:Texture=""
  crs:Contrast2012="7" />
"""
let garbage = LightroomPresetParser.parse(xmp: garbageXMP)
expect(garbage != nil, "10a 数值乱码不会让整份预设解析失败")
if let look = garbage?.look {
    expect(look.exposure == 0, "10b Exposure2012=nan 回落 0")
    expect(look.clarity == 0, "10c Clarity2012=### 回落 0")
    expect(look.dehaze == 0, "10d Dehaze=inf 回落 0")
    expect(look.texture == 0, "10e 空字符串回落 0")
    expect(look.contrast == 7, "10f 同一份里合法的值不受影响")
}

// MARK: - 10. 没有 crs 调整键

let plainXMP = """
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
   <dc:title>
    <rdf:Alt>
     <rdf:li xml:lang="x-default">雨天的路口</rdf:li>
    </rdf:Alt>
   </dc:title>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""
expect(LightroomPresetParser.parse(xmp: plainXMP, fileName: "photo.xmp") == nil, "11a 普通照片 XMP 不会被当成预设")
let nameOnlyXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Name="只有名字" crs:Group="分组" />
"""
expect(LightroomPresetParser.parse(xmp: nameOnlyXMP) == nil, "11b 只有 Name/Group 也算没有调整键")
expect(LightroomPresetParser.parse(xmp: "") == nil, "11c 空字符串返回 nil")
expect(LightroomPresetParser.parse(xmp: "   \n\t  ") == nil, "11d 全是空白返回 nil")

// MARK: - 11. 写法和健壮性

let unquotedXMP = "<rdf:Description xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" crs:Exposure2012=0.7 />"
expect(near(LightroomPresetParser.parse(xmp: unquotedXMP)?.look.exposure ?? 0, 0.7), "12a 无引号属性值能解析")

let upperPrefixXMP = "<rdf:Description xmlns:CRS=\"http://ns.adobe.com/camera-raw-settings/1.0/\" CRS:Exposure2012=\"0.6\" />"
expect(near(LightroomPresetParser.parse(xmp: upperPrefixXMP)?.look.exposure ?? 0, 0.6), "12b crs: 前缀大小写变体容忍")

let brokenQuoteXMP = "<rdf:Description xmlns:crs=\"x\"\n  crs:Exposure2012=\"0.5\n  crs:Contrast2012=\"4\" />"
expect(near(LightroomPresetParser.parse(xmp: brokenQuoteXMP)?.look.exposure ?? 0, 0.5), "12c 缺引号的值取到行尾还能用")

let crlfXMP = "\u{FEFF}\r\n<rdf:Description xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"\r\n  crs:Exposure2012=\"-1.5\"\r\n  crs:Shadows2012=\"+18\" />\r\n"
let crlf = LightroomPresetParser.parse(xmp: crlfXMP)?.look
expect(crlf?.exposure == -1.5 && crlf?.shadows == 18, "12d BOM + CRLF 换行能解析")

let attributeNameXMP = "<rdf:Description xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" crs:Name=\"属性名\" crs:Exposure2012=\"0.3\" />"
expect(LightroomPresetParser.parse(xmp: attributeNameXMP)?.name == "属性名", "12e crs:Name 写成属性时也能取到")

let colorGradeXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
  crs:SplitToningShadowHue="200"
  crs:SplitToningShadowSaturation="30"
  crs:ColorGradeShadowHue="40"
  crs:ColorGradeBalance="-15" />
"""
let colorGrade = LightroomPresetParser.parse(xmp: colorGradeXMP)?.look
expect(colorGrade?.shadowHue == 40, "12f ColorGradeShadowHue 优先于 SplitToningShadowHue")
expect(colorGrade?.shadowSaturation == 30, "12g 没有 ColorGrade 饱和度时用 SplitToningShadowSaturation 兜底")
expect(colorGrade?.splitBalance == -15, "12h ColorGradeBalance 落位")

let splitOnlyXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
  crs:SplitToningShadowHue="210"
  crs:SplitToningHighlightHue="45"
  crs:SplitToningHighlightSaturation="12" />
"""
let splitOnly = LightroomPresetParser.parse(xmp: splitOnlyXMP)?.look
expect(splitOnly?.shadowHue == 210 && splitOnly?.highlightHue == 45, "12i 只有 SplitToning 时正常读取")
expect(splitOnly?.highlightSaturation == 12, "12j SplitToningHighlightSaturation 落位")

let legacyCurveXMP = """
<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure="0.2">
 <crs:ToneCurve>
  <rdf:Seq>
   <rdf:li>0, 0</rdf:li>
   <rdf:li>255, 250</rdf:li>
  </rdf:Seq>
 </crs:ToneCurve>
</rdf:Description>
"""
let legacyCurve = LightroomPresetParser.parse(xmp: legacyCurveXMP)?.look
expect(legacyCurve?.exposure == 0.2, "12k 老版 crs:Exposure 兜底可用")
expect(sameCurve(legacyCurve?.toneCurve ?? [], [(0, 0), (255, 250)]), "12l 老版 crs:ToneCurve 能读")

// MARK: - 12. 曲线点数上限

var manyCurveXMP = "<rdf:Description xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" crs:Exposure2012=\"0.1\"><crs:ToneCurvePV2012><rdf:Seq>"
for index in 0..<40 {
    let value = index * 6
    manyCurveXMP += "<rdf:li>\(value), \(value)</rdf:li>"
}
manyCurveXMP += "</rdf:Seq></crs:ToneCurvePV2012></rdf:Description>"
let manyCurve = LightroomPresetParser.parse(xmp: manyCurveXMP)?.look.toneCurve ?? []
expect(manyCurve.count == 32, "13a 曲线点数被限制到 32 个")
expect(manyCurve.first?.input == 0 && manyCurve.last?.input == 186, "13b 截断后保留前 32 个点")

// MARK: - 13. 名称兜底

let anonymousXMP = "<rdf:Description xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" crs:Exposure2012=\"0.3\" />"
let anonymous = LightroomPresetParser.parse(xmp: anonymousXMP, fileName: "SunsetWarm.xmp")
expect(anonymous?.name == "SunsetWarm.xmp", "14a 没有 crs:Name 时用文件名")
expect(anonymous?.group == "", "14b 没有分组时是空串")
let noNameNoFile = LightroomPresetParser.parse(xmp: anonymousXMP)
expect(noNameNoFile?.name == "未命名预设", "14c 名称和文件名都没有时给一个占位名")

// MARK: - 14. 导出 → 解析 round-trip

var original = LightroomLook()
original.exposure = 0.8
original.contrast = -12
original.highlights = 22.5
original.shadows = -31
original.whites = 12
original.blacks = -8
original.texture = 6
original.clarity = 8
original.dehaze = 14
original.vibrance = 18
original.saturation = -4
original.parametricShadows = -10
original.parametricDarks = -5
original.parametricLights = 7
original.parametricHighlights = 11
original.toneCurve = [LightroomCurvePoint(input: 0, output: 0),
                      LightroomCurvePoint(input: 32, output: 22.5),
                      LightroomCurvePoint(input: 255, output: 255)]
original.curveRed = [LightroomCurvePoint(input: 0, output: 8.5), LightroomCurvePoint(input: 255, output: 240)]
original.curveBlue = [LightroomCurvePoint(input: 64, output: 70)]
original.hslHue[1] = -12
original.hslSaturation[5] = 9
original.hslLuminance[7] = -6
original.shadowHue = 210
original.shadowSaturation = 30
original.highlightHue = 45
original.highlightSaturation = 12
original.splitBalance = -15
original.sharpness = 42
original.sharpenRadius = 1.4
original.sharpenMasking = 17
original.grain = 12
original.grainSize = 30
original.vignette = -23

let source = LightroomPreset(id: UUID(), name: "暖日胶片", group: "胶片",
                             sourceFileName: "warm.xmp", look: original)
let exported = LightroomPresetParser.exportXMP(source)
expect(exported.contains("x:xmpmeta") && exported.contains("rdf:RDF"), "15a 导出内容有 xmpmeta / RDF 骨架")
expect(exported.contains("xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\""), "15b 导出内容声明了 xmlns:crs")
expect(exported.contains("crs:Exposure2012=\"0.8\""), "15c 导出写了 Exposure2012=0.8（1 位小数）")

let reread = LightroomPresetParser.parse(xmp: exported, fileName: "export.xmp")
expect(reread != nil, "15d 导出的 XMP 能被自己的 parse 读回")
if let back = reread {
    expect(back.name == "暖日胶片", "15e 名称 round-trip")
    expect(back.group == "胶片", "15f 分组 round-trip")
    let before = scalarSignature(original)
    let after = scalarSignature(back.look)
    var mismatches: [String] = []
    if before.count != after.count {
        mismatches.append("字段数量不一致")
    } else {
        for index in 0..<before.count where abs(before[index].1 - after[index].1) > 0.01 {
            mismatches.append(before[index].0)
        }
    }
    expect(mismatches.isEmpty, "15g 标量字段 round-trip 误差 ≤0.01（不一致：\(mismatches.joined(separator: ","))）")
    expect(sameCurve(back.look.toneCurve, curveSignature(original.toneCurve)), "15h 复合曲线 round-trip")
    expect(sameCurve(back.look.curveRed, curveSignature(original.curveRed)), "15i 红通道曲线 round-trip")
    expect(sameCurve(back.look.curveBlue, curveSignature(original.curveBlue)), "15j 蓝通道曲线 round-trip")
    expect(back.look.curveGreen.isEmpty, "15k 空曲线不会被凭空写出来")
    expect(back.look.name == "暖日胶片", "15l look.name 跟着预设名一起回来")
}

let emptyLookPreset = LightroomPreset(id: UUID(), name: "空白", group: "",
                                      sourceFileName: "empty.xmp", look: LightroomLook())
let emptyExport = LightroomPresetParser.exportXMP(emptyLookPreset)
expect(!emptyExport.contains("rdf:Seq"), "15l 没有曲线时导出不带 rdf:Seq")

// MARK: - 15. 预设本身 Codable

let encoded = try? JSONEncoder().encode(source)
let decoded = encoded.flatMap { try? JSONDecoder().decode(LightroomPreset.self, from: $0) }
expect(decoded == source, "16a LightroomPreset 的 Codable 往返一致（存储层靠它落盘）")
expect(decoded?.look.exposure == 0.8, "16b 解码后的数值没被改")

// MARK: - 收尾

print("Lightroom 预设测试：\(checks) 条断言，失败 \(failures) 条")
if failures == 0 {
    print("PASS")
} else {
    print("FAIL")
}
exit(failures == 0 ? 0 : 1)
