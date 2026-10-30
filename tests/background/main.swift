import Foundation
import CoreGraphics
import CoreImage

// Runtime checks for RetouchBackgroundEngine
// (OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchBackground.swift).
//
// Every check here is pure geometry, layout maths, or a lazily-built Core Image
// graph: no Vision request, no camera, no GPU render, so this runs on a headless
// macOS machine. Segmentation, background compositing and the printed sheet are
// covered by the type-check plus the manual acceptance pass.
//
// Build and run (Mac Catalyst triple because the engine links UIKit + Vision):
//
//   xcrun --sdk macosx swiftc -target arm64-apple-ios17.6-macabi \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchParameters.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchMaskKit.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchStudioModel.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchBackground.swift \
//     tests/background/main.swift -o build/background-tests && build/background-tests
//
// On a machine that cannot run a Catalyst binary, validate with
//   xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios17.6 <same files>

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

func expectClose(_ value: Double, _ expected: Double, _ tolerance: Double, _ label: String) {
    let ok = abs(value - expected) <= tolerance
    checks += 1
    if ok {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: \(label) -> got \(value), expected \(expected) +/- \(tolerance)")
    }
}

func expectSize(_ size: CGSize, _ width: Double, _ height: Double, _ label: String) {
    let ok = abs(Double(size.width) - width) <= 0.001 && abs(Double(size.height) - height) <= 0.001
    checks += 1
    if ok {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: \(label) -> got \(size), expected \(width)x\(height)")
    }
}

// MARK: - 1. ID photo pixel sizes at 300 dpi

print("-- ID photo pixel sizes --")

// 25 mm / 25.4 * 300 = 295.28 -> 295 px, 35 mm -> 413.39 -> 413 px.
let expectedSizes: [(IDPhotoSpec, Double, Double)] = [
    (.oneInch, 295, 413),
    (.smallOneInch, 260, 378),
    (.twoInch, 413, 579),
    (.smallTwoInch, 413, 531),
    (.passport, 390, 567),
    (.visaUS, 602, 602),
    (.custom, 295, 413),
]
for (spec, width, height) in expectedSizes {
    expectSize(spec.pixelSize(dpi: 300), width, height,
               "\(spec.displayName) is \(Int(width))x\(Int(height)) px at 300 dpi")
    expectSize(RetouchBackgroundEngine.pixelSize(of: spec, dpi: 300), width, height,
               "engine pixel size for \(spec.displayName) matches the spec")
}
expect(IDPhotoSpec.allCases.count == 7, "all seven ID photo specs are covered")
expect(IDPhotoSpec.oneInch.pixelSize(dpi: 300).width == 295
        && IDPhotoSpec.oneInch.pixelSize(dpi: 300).height == 413,
       "one inch is 295x413 px at 300 dpi")

// MARK: - 2. dpi sanitising

print("-- dpi sanitising --")

expectClose(RetouchBackgroundEngine.sanitizedDPI(0), 300, 1e-9, "dpi 0 clamps to 300")
expectClose(RetouchBackgroundEngine.sanitizedDPI(-120), 300, 1e-9, "negative dpi clamps to 300")
expectClose(RetouchBackgroundEngine.sanitizedDPI(.nan), 300, 1e-9, "NaN dpi clamps to 300")
expectClose(RetouchBackgroundEngine.sanitizedDPI(.infinity), 300, 1e-9, "infinite dpi clamps to 300")
expectClose(RetouchBackgroundEngine.sanitizedDPI(1), 300, 1e-9, "dpi 1 clamps to 300")
expectClose(RetouchBackgroundEngine.sanitizedDPI(300), 300, 1e-9, "300 dpi is kept")
expectClose(RetouchBackgroundEngine.sanitizedDPI(600), 600, 1e-9, "600 dpi is kept")
expectSize(RetouchBackgroundEngine.pixelSize(of: .oneInch, dpi: 0), 295, 413,
           "dpi 0 renders the one inch spec at 295x413 px")
expectClose(Double(RetouchBackgroundEngine.pixels(millimeters: 25.4, dpi: 300)), 300, 1e-6,
            "25.4 mm is 300 px at 300 dpi")
let paperPixels = RetouchBackgroundEngine.pixelSize(millimeters: CGSize(width: 152, height: 102), dpi: 300)
expectClose(Double(paperPixels.width), 1795.2756, 0.01, "6-inch paper is 1795.28 px wide at 300 dpi")
expectClose(Double(paperPixels.height), 1204.7244, 0.01, "6-inch paper is 1204.72 px high at 300 dpi")

// MARK: - 3. Head placement

print("-- head placement --")

let faceBox = CGRect(x: 0.35, y: 0.18, width: 0.30, height: 0.34)
let faceOnly = FaceGeometry(box: faceBox, leftEye: nil, rightEye: nil, lips: nil, nose: nil)
let eyeLine = RetouchBackgroundEngine.eyeLine(for: faceOnly)
expectClose(Double(eyeLine), 0.18 + 0.34 * 0.42, 1e-6,
            "eye line falls back to 42 % of the face box")
expectClose(Double(RetouchBackgroundEngine.eyeLineRatio), 0.44, 1e-9,
            "the standard eye line sits at 44 % of the photo height")
expectClose(RetouchBackgroundEngine.hairAllowance, 1.08, 1e-9,
            "the crown allowance is 8 %")

let sourceSize = CGSize(width: 3000, height: 4000)
for spec in [IDPhotoSpec.oneInch, .passport, .visaUS] {
    let output = RetouchBackgroundEngine.pixelSize(of: spec, dpi: 300)
    guard let crop = RetouchBackgroundEngine.idPhotoCrop(faceBox: faceBox, eyeLine: eyeLine,
                                                         sourceSize: sourceSize, outputSize: output,
                                                         headHeightRatio: spec.headHeightRatio) else {
        expect(false, "\(spec.displayName) framing maths returns a crop")
        continue
    }
    let achievedEye = (Double(eyeLine) - Double(crop.minY)) / Double(crop.height)
    expectClose(achievedEye, 0.44, 1e-6,
                "\(spec.displayName) puts the eye line at 0.44 of the photo height")
    let achievedHead = Double(faceBox.height) * 1.08 / Double(crop.height)
    let pixelError = abs(achievedHead - spec.headHeightRatio) * Double(output.height)
    expect(pixelError <= 1.0,
           "\(spec.displayName) head height ratio is within 1 px (error \(pixelError))")
    let cropAspect = (Double(crop.width) * 3000.0) / (Double(crop.height) * 4000.0)
    expectClose(cropAspect, Double(output.width / output.height), 1e-6,
                "\(spec.displayName) crop keeps the spec aspect ratio")
    expect(crop.minX >= 0 && crop.minY >= 0 && crop.maxX <= 1 && crop.maxY <= 1,
           "\(spec.displayName) crop stays inside the frame")
    expect(crop.width > 0 && crop.height > 0, "\(spec.displayName) crop has a positive size")
}

// Defensive framing maths.
expect(RetouchBackgroundEngine.idPhotoCrop(faceBox: .zero, eyeLine: 0.44,
                                           sourceSize: sourceSize,
                                           outputSize: CGSize(width: 295, height: 413),
                                           headHeightRatio: 0.66) == nil,
       "a zero sized face box cannot be framed")
expect(RetouchBackgroundEngine.idPhotoCrop(faceBox: faceBox, eyeLine: 0.44,
                                           sourceSize: .zero,
                                           outputSize: CGSize(width: 295, height: 413),
                                           headHeightRatio: 0.66) == nil,
       "a zero sized source cannot be framed")
expect(RetouchBackgroundEngine.idPhotoCrop(faceBox: faceBox, eyeLine: 0.44,
                                           sourceSize: sourceSize,
                                           outputSize: .zero,
                                           headHeightRatio: 0.66) == nil,
       "a zero sized output cannot be framed")
expect(RetouchBackgroundEngine.idPhotoCrop(faceBox: faceBox, eyeLine: 0.44,
                                           sourceSize: sourceSize,
                                           outputSize: CGSize(width: 295, height: 413),
                                           headHeightRatio: 0) == nil,
       "a zero head height ratio cannot be framed")

// MARK: - 4. Print sheet grid

print("-- print sheet grid --")

let gapPixels = RetouchBackgroundEngine.pixels(millimeters: 2, dpi: 300)
expectClose(Double(gapPixels), 23.6220, 0.001, "the 2 mm gutter is 23.62 px at 300 dpi")
let oneInchPixels = RetouchBackgroundEngine.pixelSize(of: .oneInch, dpi: 300)
guard let oneInchGrid = RetouchBackgroundEngine.printSheetGrid(photoSize: oneInchPixels,
                                                               paperPixels: paperPixels,
                                                               gapPixels: gapPixels) else {
    fatalError("FAIL: the one inch grid must fit on 6-inch paper")
}
expect(oneInchGrid.columns == 5, "one inch photos fit five columns on 6-inch paper (got \(oneInchGrid.columns))")
expect(oneInchGrid.rows == 2, "one inch photos fit two rows on 6-inch paper (got \(oneInchGrid.rows))")
expect(oneInchGrid.count == 10, "6-inch paper holds ten one inch photos")

let visaPixels = RetouchBackgroundEngine.pixelSize(of: .visaUS, dpi: 300)
if let visaGrid = RetouchBackgroundEngine.printSheetGrid(photoSize: visaPixels,
                                                         paperPixels: paperPixels,
                                                         gapPixels: gapPixels) {
    expect(visaGrid.columns == 2 && visaGrid.rows == 1 && visaGrid.count == 2,
           "6-inch paper holds two 51 mm visa photos")
} else {
    expect(false, "two visa photos fit on 6-inch paper")
}

expect(RetouchBackgroundEngine.printSheetGrid(photoSize: oneInchPixels,
                                              paperPixels: CGSize(width: 100, height: 100),
                                              gapPixels: gapPixels) == nil,
       "a sheet smaller than one photo has no grid")
expect(RetouchBackgroundEngine.printSheetGrid(photoSize: .zero,
                                              paperPixels: paperPixels,
                                              gapPixels: gapPixels) == nil,
       "a zero sized photo has no grid")
expect(RetouchBackgroundEngine.printSheetGrid(photoSize: oneInchPixels,
                                              paperPixels: paperPixels,
                                              gapPixels: .nan) != nil,
       "a NaN gutter falls back to zero and still fits the sheet")

// MARK: - 5. Background construction

print("-- background construction --")

let frame = CGRect(x: 0, y: 0, width: 120, height: 200)
let endpoints = RetouchBackgroundEngine.gradientEndpoints(in: frame)
expect(Double(endpoints.top.y) == Double(frame.maxY), "the gradient starts at y = height (top edge)")
expect(Double(endpoints.bottom.y) == Double(frame.minY), "the gradient ends at y = 0 (bottom edge)")
expect(endpoints.top.y > endpoints.bottom.y, "the CI gradient axis runs downwards from the top")
expect(endpoints.top.x == frame.minX && endpoints.bottom.x == frame.minX,
       "the gradient is vertical, both points share x")

let studioBlue = BackgroundOptions.studioBlue
expect(studioBlue.kind == .gradient, "studio blue is a gradient")
expect(studioBlue.color.y < studioBlue.colorBottom.y,
       "studio blue is darker at the top than at the bottom")
let studioGray = BackgroundOptions.studioGray
expect(studioGray.kind == .gradient && studioGray.color.x < studioGray.colorBottom.x,
       "studio gray keeps the darker value at the top")
expect(BackgroundOptions.white.kind == .solid, "the white preset is a solid background")
expect(BackgroundOptions.keep.isKeep, "the keep preset is a no-op background")
expect(BackgroundOptions.keep.needsSegmentation == false, "keep does not need segmentation")
expect(BackgroundOptions.white.needsSegmentation, "solid white needs segmentation")
expect(BackgroundOptions.studioBlue.needsSegmentation, "the blue gradient needs segmentation")

// MARK: - 6. Engine defensive paths

print("-- engine defensive paths --")

let context = CIContext(options: [.useSoftwareRenderer: true])
let engine = RetouchBackgroundEngine(context: context)
let source = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 500))
let onePixel = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

expect(engine.idPhoto(source, geometry: nil, spec: .oneInch, background: .keep, dpi: 300) == nil,
       "id photo without face geometry returns nil")
let zeroGeometry = FaceGeometry(box: .zero, leftEye: nil, rightEye: nil, lips: nil, nose: nil)
expect(engine.idPhoto(source, geometry: zeroGeometry, spec: .oneInch, background: .keep, dpi: 300) == nil,
       "id photo with a zero sized face box returns nil")
expect(engine.idPhoto(onePixel, geometry: faceOnly, spec: .oneInch, background: .keep, dpi: 300) == nil,
       "a 1x1 source cannot be framed")
expect(engine.subjectMask(for: onePixel, geometry: nil, context: context) == nil,
       "a 1x1 image cannot be segmented")

let kept = engine.apply(source, subjectMask: nil, options: .keep)
expect(kept.extent == source.extent, "keep returns the image untouched")
let noMask = engine.apply(source, subjectMask: nil, options: .white)
expect(noMask.extent == source.extent, "a nil subject mask leaves the image untouched")

let blackMatte = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 250))
let replaced = engine.apply(source, subjectMask: blackMatte, options: .white)
expect(replaced.extent == source.extent, "a solid background keeps the source extent")
let cleaned = engine.apply(source, subjectMask: blackMatte,
                           options: BackgroundOptions(kind: .clean))
expect(cleaned.extent == source.extent, "background cleanup keeps the source extent")

let validFace = FaceGeometry(box: CGRect(x: 0.30, y: 0.16, width: 0.34, height: 0.36),
                             leftEye: nil, rightEye: nil, lips: nil, nose: nil)
guard let portrait = engine.idPhoto(source, geometry: validFace, spec: .oneInch,
                                    background: .keep, dpi: 300) else {
    fatalError("FAIL: a valid face must produce an ID photo")
}
expectSize(portrait.extent.size, 295, 413, "the one inch ID photo is 295x413 px at 300 dpi")

let edgeFace = FaceGeometry(box: CGRect(x: 0.70, y: 0.02, width: 0.34, height: 0.36),
                            leftEye: nil, rightEye: nil, lips: nil, nose: nil)
if let edgePortrait = engine.idPhoto(source, geometry: edgeFace, spec: .oneInch,
                                     background: .keep, dpi: 300) {
    expectSize(edgePortrait.extent.size, 295, 413,
               "a face at the frame edge is clamped into the photo instead of crashing")
} else {
    expect(false, "a face at the frame edge still yields an ID photo")
}

let highDPI = engine.idPhoto(source, geometry: validFace, spec: .passport,
                             background: .keep, dpi: 0)
expectSize(highDPI?.extent.size ?? .zero, 390, 567,
           "a dpi of 0 falls back to 300 dpi for the passport spec")

// MARK: - 7. Print sheet rendering

print("-- print sheet rendering --")

let sheetPhoto = CIImage(color: CIColor(red: 0.6, green: 0.7, blue: 0.8, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 295, height: 413))
if let sheet = engine.printSheet(sheetPhoto, spec: .oneInch, dpi: 300,
                                 paper: CGSize(width: 152, height: 102), gapMillimeters: 2) {
    expectClose(Double(sheet.extent.width), 1795.2756, 0.5,
                "the 6-inch sheet is 152 mm wide at 300 dpi")
    expectClose(Double(sheet.extent.height), 1204.7244, 0.5,
                "the 6-inch sheet is 102 mm high at 300 dpi")
} else {
    expect(false, "the 6-inch sheet renders for one inch photos")
}
expect(engine.printSheet(sheetPhoto, spec: .oneInch, dpi: 300,
                         paper: CGSize(width: 20, height: 20), gapMillimeters: 2) == nil,
       "a paper smaller than one photo returns nil")
expect(engine.printSheet(sheetPhoto, spec: .oneInch, dpi: 300,
                         paper: .zero, gapMillimeters: 2) == nil,
       "a zero sized paper returns nil")
if let marks = RetouchBackgroundEngine.cropMarks(around: CGRect(x: 30, y: 30, width: 295, height: 413),
                                                 length: 12, thickness: 2,
                                                 color: CIColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1),
                                                 bounds: CGRect(x: 0, y: 0, width: 400, height: 500)) {
    expect(marks.extent.width > 0 && marks.extent.height > 0, "corner crop marks are drawn")
} else {
    expect(false, "corner crop marks are drawn")
}

// MARK: - 8. Constants the studio documents

print("-- constants --")

expectClose(RetouchBackgroundEngine.defaultDPI, 300, 1e-9, "the default print resolution is 300 dpi")
expectClose(RetouchBackgroundEngine.cropMarkMillimeters, 3, 1e-9, "crop marks are 3 mm long")
expect(RetouchBackgroundEngine.minFeatherPx == 1.5, "the soft matte never feathers below 1.5 px")
expect(RetouchBackgroundEngine.maxFeatherPx == 2.5, "the soft matte never feathers above 2.5 px")
let wideFace = FaceGeometry(box: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.5),
                            leftEye: nil, rightEye: nil, lips: nil, nose: nil)
let wideFeather = RetouchBackgroundEngine.featherRadius(for: wideFace, extent: frame)
expect(wideFeather >= 1.5 && wideFeather <= 2.5, "the feather for a large face stays in 1.5-2.5 px")
expectClose(Double(RetouchBackgroundEngine.featherRadius(for: nil, extent: frame)), 2.0, 1e-9,
            "a missing geometry feathers at 2 px")

if failures == 0 {
    print("\nALL PASS (\(checks) checks)")
} else {
    print("\nFAILURES: \(failures) of \(checks) checks")
    exit(1)
}
