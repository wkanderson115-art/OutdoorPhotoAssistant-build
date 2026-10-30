import Foundation
import CoreGraphics
import CoreImage

// Runtime checks for PixelKit (OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchMaskKit.swift).
//
// Build and run on macOS, together with the kit, as a plain command line program
// (no UIKit, no camera, no GPU needed):
//
//   xcrun swiftc -O \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchMaskKit.swift \
//     tests/retouchkit/main.swift \
//     -o /tmp/retouchkit && /tmp/retouchkit
//
// The reference numbers were produced by the numpy implementation in
// tools/retouch_lab/ops.py (plus the Sharma CIEDE2000 test set), so a failure
// means the Swift port drifted from the reference lab.

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

func expectClose(_ value: Float, _ expected: Float, _ tolerance: Float, _ label: String) {
    let ok = abs(value - expected) <= tolerance
    checks += 1
    if ok {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: \(label) -> got \(value), expected \(expected) +/- \(tolerance)")
    }
}

func expectClose3(_ value: SIMD3<Float>, _ expected: SIMD3<Float>, _ tolerance: Float, _ label: String) {
    let ok = abs(value.x - expected.x) <= tolerance
        && abs(value.y - expected.y) <= tolerance
        && abs(value.z - expected.z) <= tolerance
    checks += 1
    if ok {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: \(label) -> got \(value), expected \(expected) +/- \(tolerance)")
    }
}

// MARK: - 1. FloatPlane

print("-- FloatPlane --")

var plane = FloatPlane(width: 4, height: 3)
expect(plane.count == 12, "FloatPlane allocates width * height elements")
expect(plane.values.count == 12, "FloatPlane values buffer matches the pixel count")
expect(plane[2, 1] == 0, "FloatPlane defaults to zero")
plane[2, 1] = 0.75
expectClose(plane[2, 1], 0.75, 1e-6, "FloatPlane subscript round-trips a value")
plane[-1, 0] = 5.0
plane[9, 9] = 5.0
expect(plane[-1, 0] == 0, "FloatPlane ignores writes outside the plane")
expect(plane[9, 9] == 0, "FloatPlane reads outside the plane return zero")
expect(plane.values.count == 12, "Out-of-range writes never resize the plane")

let filled = FloatPlane(width: 3, height: 3, value: 0.25)
expect(filled.values.count == 9, "FloatPlane(width:height:value:) fills the buffer")
expectClose(filled[1, 1], 0.25, 1e-6, "FloatPlane(width:height:value:) stores the fill value")

let adopted = FloatPlane(width: 2, height: 2, values: [0.1, 0.2, 0.3])
expect(adopted.values.count == 4, "FloatPlane pads a short values buffer")
expectClose(adopted[1, 1], 0, 1e-6, "FloatPlane padding is zero")

let emptyPlane = FloatPlane(width: 0, height: 0)
expect(emptyPlane.isEmpty && emptyPlane.count == 0, "Zero sized FloatPlane is empty")

// MARK: - 2. RGBAImage

print("-- RGBAImage --")

var rgba = RGBAImage(width: 4, height: 1, bytes: [
    0, 0, 0, 255,        // black
    255, 255, 255, 255,  // white
    255, 0, 0, 255,      // red
    128, 128, 128, 255,  // 50% grey
])
expect(rgba.count == 4, "RGBAImage reports width * height")
expect(rgba.bytes.count == 16, "RGBAImage keeps four bytes per pixel")
expectClose3(rgba.rgb(x: 2, y: 0), SIMD3<Float>(1, 0, 0), 1e-6, "RGBAImage.rgb reads a red pixel")
expect(rgba.rgb(x: 8, y: 8) == SIMD3<Float>(0, 0, 0), "RGBAImage.rgb returns black out of range")
rgba = RGBAImage(width: 1, height: 1, bytes: [1, 2, 3])
expect(rgba.bytes.count == 4, "RGBAImage pads a short byte buffer")

// MARK: - 3. Transfer functions and luma

print("-- transfer functions --")

expectClose(PixelKit.luma(r: 1, g: 1, b: 1), 1, 1e-6, "luma of white is 1")
expectClose(PixelKit.luma(r: 0, g: 0, b: 0), 0, 1e-6, "luma of black is 0")
expectClose(PixelKit.luma(r: 0.5, g: 0.5, b: 0.5), 0.5, 1e-6, "luma of 50% grey is 0.5")
expectClose(PixelKit.luma(r: 1, g: 0, b: 0), 0.2126, 1e-6, "luma uses Rec.709 red weight")

expectClose(PixelKit.srgbToLinear(0), 0, 1e-6, "srgbToLinear(0) = 0")
expectClose(PixelKit.srgbToLinear(1), 1, 1e-6, "srgbToLinear(1) = 1")
expectClose(PixelKit.srgbToLinear(0.5), 0.21404114, 1e-5, "srgbToLinear(0.5) matches the sRGB curve")
expectClose(PixelKit.srgbToLinear(0.04045), 0.0031308, 1e-7, "srgbToLinear hits the linear segment")
expectClose(PixelKit.linearToSrgb(0), 0, 1e-6, "linearToSrgb(0) = 0")
expectClose(PixelKit.linearToSrgb(1), 1, 1e-6, "linearToSrgb(1) = 1")

var transferRoundTripOK = true
for step in 0...20 {
    let value = Float(step) / 20.0
    let roundTrip = PixelKit.linearToSrgb(PixelKit.srgbToLinear(value))
    if abs(roundTrip - value) > 1e-4 { transferRoundTripOK = false }
}
expect(transferRoundTripOK, "srgbToLinear / linearToSrgb round-trip to 1e-4")

// MARK: - 4. Lab conversion

print("-- CIELab --")

expectClose3(PixelKit.rgbToLab(r: 1, g: 1, b: 1), SIMD3<Float>(100, 0, 0), 0.01, "white is L* = 100")
expectClose3(PixelKit.rgbToLab(r: 0, g: 0, b: 0), SIMD3<Float>(0, 0, 0), 0.01, "black is L* = 0")
expectClose(PixelKit.rgbToLab(r: 0.5, g: 0.5, b: 0.5).x, 53.389, 0.02, "50% grey is L* = 53.389")
expectClose(PixelKit.rgbToLab(r: 0.8, g: 0.4, b: 0.3).x, 54.9407, 0.02, "skin-ish colour L* matches the reference")
expectClose(PixelKit.rgbToLab(r: 0.8, g: 0.4, b: 0.3).y, 38.3125, 0.02, "skin-ish colour a* matches the reference")
expectClose(PixelKit.rgbToLab(r: 0.8, g: 0.4, b: 0.3).z, 32.9539, 0.02, "skin-ish colour b* matches the reference")

let labSamples: [(Float, Float, Float)] = [
    (0, 0, 0), (1, 1, 1), (0.5, 0.5, 0.5), (0.8, 0.4, 0.3),
    (0.2045, 0.3805, 0.6702), (0.123, 0.456, 0.789), (1, 0, 0), (0, 1, 0), (0, 0, 1),
]
var labRoundTripOK = true
for (r, g, b) in labSamples {
    let back = PixelKit.labToRGB(PixelKit.rgbToLab(r: r, g: g, b: b))
    if abs(back.x - r) > 1e-3 || abs(back.y - g) > 1e-3 || abs(back.z - b) > 1e-3 {
        labRoundTripOK = false
        print("  round-trip drift at \(r), \(g), \(b) -> \(back)")
    }
}
expect(labRoundTripOK, "rgbToLab / labToRGB round-trip to 1e-3")

// MARK: - 5. CIEDE2000

print("-- CIEDE2000 --")

let grey50 = SIMD3<Float>(50, 0, 0)
expect(PixelKit.deltaE2000(grey50, grey50) <= 1e-6, "deltaE2000 of identical colours is 0")
expectClose(PixelKit.deltaE2000(SIMD3<Float>(50, 2.6772, -79.7751), SIMD3<Float>(50, 0, -82.7485)),
            2.0425, 2e-3, "deltaE2000 Sharma pair 1")
expectClose(PixelKit.deltaE2000(SIMD3<Float>(50, 0, 0), SIMD3<Float>(50, -1, 2)),
            2.3669, 2e-3, "deltaE2000 Sharma pair 7")
expectClose(PixelKit.deltaE2000(SIMD3<Float>(50, 2.49, -0.001), SIMD3<Float>(50, -2.49, 0.0009)),
            7.1792, 2e-3, "deltaE2000 Sharma pair 9 (hue wrap)")
expectClose(PixelKit.deltaE2000(SIMD3<Float>(50, 2.5, 0), SIMD3<Float>(73, 25, -18)),
            27.1492, 3e-3, "deltaE2000 Sharma pair 17 (large difference)")
expectClose(PixelKit.deltaE2000(SIMD3<Float>(2.0776, 0.0795, -1.135), SIMD3<Float>(0.9033, -0.0636, -0.5514)),
            0.9082, 2e-3, "deltaE2000 Sharma pair 34 (dark colours)")
let symmetryA = PixelKit.deltaE2000(SIMD3<Float>(50, 2.6772, -79.7751), SIMD3<Float>(50, 0, -82.7485))
let symmetryB = PixelKit.deltaE2000(SIMD3<Float>(50, 0, -82.7485), SIMD3<Float>(50, 2.6772, -79.7751))
expect(abs(symmetryA - symmetryB) < 1e-4, "deltaE2000 is symmetric")
expect(PixelKit.deltaE2000(SIMD3<Float>(0, 0, 0), SIMD3<Float>(100, 0, 0)) > 99,
       "deltaE2000 of black vs white is large")

// MARK: - 6. boxBlur

print("-- boxBlur --")

let constant = FloatPlane(width: 21, height: 21, value: 0.3)
let constantBlurred = PixelKit.boxBlur(constant, radius: 3)
var constantOK = true
for y in 0..<21 {
    for x in 0..<21 {
        if abs(constantBlurred[x, y] - 0.3) > 1e-6 { constantOK = false }
    }
}
expect(constantOK, "boxBlur keeps a constant plane constant (edge clamping, no darkening)")
expect(PixelKit.boxBlur(constant, radius: 0).values == constant.values, "boxBlur with radius 0 is a no-op")

var impulse = FloatPlane(width: 21, height: 21)
impulse[10, 10] = 1.0
let impulseBlur = PixelKit.boxBlur(impulse, radius: 2)
expectClose(impulseBlur[10, 10], 1.0 / 25.0, 1e-6, "boxBlur(radius 2) spreads an impulse to 1/25")
var impulseSum: Float = 0
for y in 0..<21 {
    for x in 0..<21 { impulseSum += impulseBlur[x, y] }
}
expectClose(impulseSum, 1.0, 1e-4, "boxBlur conserves total mass for an interior impulse")
expectClose(impulseBlur[9, 10], impulseBlur[11, 10], 1e-6, "boxBlur is symmetric around the impulse")
expect(impulseBlur[10, 13] == 0, "boxBlur does not leak past the 2r+1 window")

var stepPlane = FloatPlane(width: 21, height: 7)
for y in 0..<7 {
    for x in 10..<21 { stepPlane[x, y] = 1.0 }
}
let stepBlur = PixelKit.boxBlur(stepPlane, radius: 2)
var monotone = true
for x in 1..<21 where stepBlur[x, 3] < stepBlur[x - 1, 3] { monotone = false }
expect(monotone, "boxBlur keeps a step edge monotone")
expectClose(stepBlur[12, 3], 1.0, 1e-6, "boxBlur leaves the interior of a step at 1")
expectClose(stepBlur[10, 3], 0.6, 1e-6, "boxBlur ramps the step edge over the window")

// MARK: - 7. gaussianBlur

print("-- gaussianBlur --")

expect(PixelKit.gaussianBlur(constant, sigma: 0.1).values == constant.values,
       "gaussianBlur with sigma <= 0.3 is a no-op")
let gaussianConstant = PixelKit.gaussianBlur(constant, sigma: 3.0)
var gaussianConstantOK = true
for y in 0..<21 {
    for x in 0..<21 {
        if abs(gaussianConstant[x, y] - 0.3) > 1e-6 { gaussianConstantOK = false }
    }
}
expect(gaussianConstantOK, "gaussianBlur keeps a constant plane constant")

let gaussianImpulse = PixelKit.gaussianBlur(impulse, sigma: 3.0)
let boxImpulse = PixelKit.boxBlur(impulse, radius: 1)
expect(gaussianImpulse[10, 10] > 0, "gaussianBlur spreads an impulse")
expect(gaussianImpulse[10, 10] < boxImpulse[10, 10],
       "gaussianBlur(sigma 3) spreads wider than a 3x3 box blur")
expectClose(gaussianImpulse[10, 10], 0.0204082, 1e-5, "gaussianBlur(sigma 3, 2 passes) peak matches the box approximation")
var gaussianSum: Float = 0
for y in 0..<21 {
    for x in 0..<21 { gaussianSum += gaussianImpulse[x, y] }
}
expectClose(gaussianSum, 1.0, 1e-4, "gaussianBlur conserves total mass")
expectClose(gaussianImpulse[9, 10], gaussianImpulse[11, 10], 1e-6, "gaussianBlur is symmetric")
let gaussianOnePass = PixelKit.gaussianBlur(impulse, sigma: 2.0, passes: 1)
let gaussianTwoPass = PixelKit.gaussianBlur(impulse, sigma: 2.0, passes: 2)
expect(gaussianTwoPass[10, 10] > gaussianOnePass[10, 10],
       "two box passes of sigma 2 spread wider per pass than one wider-box pass")
expectClose(gaussianTwoPass[10, 10], 0.04, 1e-5, "gaussianBlur(sigma 2, 2 passes) peak is 1/25")
expectClose(gaussianTwoPass[10, 10], 0.0398, 1e-3,
            "two box passes approach the true sigma 2 Gaussian peak (1 / 2*pi*sigma^2)")

// MARK: - 8. guidedFilter

print("-- guidedFilter --")

let flatGuide = FloatPlane(width: 17, height: 17, value: 0.4)
let flatGuided = PixelKit.guidedFilter(guide: flatGuide, src: flatGuide, radius: 4, eps: 1e-2)
var flatGuidedOK = true
for y in 0..<17 {
    for x in 0..<17 {
        if abs(flatGuided[x, y] - 0.4) > 1e-5 { flatGuidedOK = false }
    }
}
expect(flatGuidedOK, "guidedFilter reproduces a constant image")

var stepImage = FloatPlane(width: 33, height: 9)
for y in 0..<9 {
    for x in 16..<33 { stepImage[x, y] = 1.0 }
}
let stepGuided = PixelKit.guidedFilter(guide: stepImage, src: stepImage, radius: 4, eps: 1e-2)
expectClose(stepGuided[0, 4], 0, 1e-4, "guidedFilter keeps the dark side of a step at 0")
expectClose(stepGuided[32, 4], 1, 1e-4, "guidedFilter keeps the bright side of a step at 1")
expectClose(stepGuided[15, 4], 0.025, 0.01, "guidedFilter transitions just before the step")
expectClose(stepGuided[16, 4], 0.975, 0.01, "guidedFilter transitions just after the step")
expect(stepGuided[15, 4] < 0.1 && stepGuided[16, 4] > 0.9,
       "guidedFilter preserves the step edge instead of averaging it away")

var ramp = FloatPlane(width: 33, height: 9)
for y in 0..<9 {
    for x in 0..<33 { ramp[x, y] = Float(x) / 32.0 }
}
let rampGuided = PixelKit.guidedFilter(guide: ramp, src: ramp, radius: 4, eps: 1e-2)
var rampError: Float = 0
for y in 0..<9 {
    for x in 0..<33 { rampError += abs(rampGuided[x, y] - ramp[x, y]) }
}
expectClose(rampError / Float(33 * 9), 0.005, 0.004, "guidedFilter tracks a linear ramp (mean abs error)")
expect(rampGuided[32, 4] > 0.95 && rampGuided[0, 4] < 0.05, "guidedFilter keeps the ramp end points")

expect(PixelKit.guidedFilter(guide: FloatPlane(width: 4, height: 4), src: ramp, radius: 2, eps: 1e-2).width == 33,
       "guidedFilter returns src when the guide size does not match")

// MARK: - 9. morphology

print("-- morphology --")

var hole = FloatPlane(width: 21, height: 21, value: 1)
hole[10, 10] = 0
let closed = PixelKit.morphologicalClose(hole, radius: 2)
expectClose(closed[10, 10], 1, 1e-6, "morphologicalClose fills a single-pixel hole")
var closedMin: Float = 1
for y in 0..<21 {
    for x in 0..<21 { closedMin = min(closedMin, closed[x, y]) }
}
expectClose(closedMin, 1, 1e-6, "morphologicalClose leaves a solid mask untouched")

var dot = FloatPlane(width: 21, height: 21)
dot[10, 10] = 1
let dilated = PixelKit.maximumFilter(dot, radius: 2)
expectClose(dilated[10, 12], 1, 1e-6, "maximumFilter grows a dot by the radius")
expectClose(dilated[10, 13], 0, 1e-6, "maximumFilter stops outside the radius")
let eroded = PixelKit.minimumFilter(dilated, radius: 2)
expectClose(eroded[10, 10], 1, 1e-6, "minimumFilter erodes a 5x5 block back to its centre")
expectClose(eroded[10, 11], 0, 1e-6, "minimumFilter removes the grown rim")
expect(PixelKit.minimumFilter(dot, radius: 0).values == dot.values, "minimumFilter with radius 0 is a no-op")
expect(PixelKit.maximumFilter(dot, radius: 0).values == dot.values, "maximumFilter with radius 0 is a no-op")
expect(PixelKit.morphologicalClose(dot, radius: 0).values == dot.values, "morphologicalClose with radius 0 is a no-op")

// MARK: - 10. statistics

print("-- statistics --")

var ramp11 = FloatPlane(width: 11, height: 1)
for x in 0..<11 { ramp11[x, 0] = Float(x) / 10.0 }
expectClose(PixelKit.percentile(ramp11, mask: nil, 0), 0, 1e-6, "percentile 0 is the minimum")
expectClose(PixelKit.percentile(ramp11, mask: nil, 25), 0.25, 1e-5, "percentile 25 interpolates like numpy")
expectClose(PixelKit.percentile(ramp11, mask: nil, 50), 0.5, 1e-6, "percentile 50 is the median")
expectClose(PixelKit.percentile(ramp11, mask: nil, 100), 1.0, 1e-6, "percentile 100 is the maximum")
expectClose(PixelKit.median(ramp11, mask: nil), 0.5, 1e-6, "median == percentile 50")
expectClose(PixelKit.mean(ramp11, mask: nil), 0.5, 1e-6, "mean of a full ramp is 0.5")

var lowMask = FloatPlane(width: 11, height: 1)
for x in 0...5 { lowMask[x, 0] = 1 }
expectClose(PixelKit.median(ramp11, mask: lowMask), 0.25, 1e-5, "masked median uses only mask > 0.5 samples")
expectClose(PixelKit.percentile(ramp11, mask: lowMask, 100), 0.5, 1e-5, "masked percentile 100 is the masked maximum")
expectClose(PixelKit.mean(ramp11, mask: lowMask), 0.25, 1e-5, "masked mean uses only the masked samples")

let emptyMask = FloatPlane(width: 11, height: 1)
expectClose(PixelKit.percentile(ramp11, mask: emptyMask, 50), 0.5, 1e-6,
            "an empty mask falls back to the whole plane")
expect(PixelKit.percentile(emptyPlane, mask: nil, 50) == 0, "percentile of an empty plane is 0")
expect(PixelKit.mean(emptyPlane, mask: nil) == 0, "mean of an empty plane is 0")

// MARK: - 11. colour spaces and medianRGB

print("-- colour spaces --")

let rgb = RGBAImage(width: 4, height: 1, bytes: [
    0, 0, 0, 255,
    255, 255, 255, 255,
    255, 0, 0, 255,
    128, 128, 128, 255,
])
let ycc = PixelKit.ycbcr(rgb)
expect(ycc.y.width == 4 && ycc.y.height == 1, "ycbcr keeps the image dimensions")
expectClose(ycc.y[1, 0], 1.0, 1e-5, "ycbcr luma of white is 1")
expectClose(ycc.y[0, 0], 0, 1e-6, "ycbcr luma of black is 0")
expectClose(ycc.cb[2, 0], 0.331264, 1e-5, "ycbcr Cb of pure red matches BT.601")
expectClose(ycc.cr[2, 0], 1.0, 1e-5, "ycbcr Cr of pure red matches BT.601")
expectClose(ycc.cb[1, 0], 0.5, 1e-5, "ycbcr Cb of neutral grey is 0.5")

let lumaPlane = PixelKit.luma(rgb)
expect(lumaPlane.width == 4 && lumaPlane.height == 1, "luma(plane) keeps the image dimensions")
expectClose(lumaPlane[0, 0], 0, 1e-6, "luma plane of a black pixel is 0")
expectClose(lumaPlane[1, 0], 1.0, 1e-5, "luma plane of a white pixel is 1")
expectClose(lumaPlane[2, 0], 0.2126, 1e-5, "luma plane of a red pixel is the Rec.709 red weight")
expect(PixelKit.luma(RGBAImage(width: 0, height: 0, bytes: [])).isEmpty, "luma plane of an empty image is empty")

let labPlanes = PixelKit.lab(rgb)
expectClose(labPlanes.l[1, 0], 100, 0.01, "lab L* of white is 100")
expectClose(labPlanes.l[0, 0], 0, 0.01, "lab L* of black is 0")
expectClose(labPlanes.l[3, 0], 53.585, 0.05, "lab L* of 128 grey matches the reference")
expectClose(labPlanes.a[1, 0], 0, 0.01, "lab a* of white is neutral")
expectClose(labPlanes.b[1, 0], 0, 0.01, "lab b* of white is neutral")
expect(abs(labPlanes.a[2, 0]) > 50, "lab a* of pure red is strongly positive")

let checker = RGBAImage(width: 2, height: 2, bytes: [
    0, 0, 0, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 0, 0, 0, 255,
])
let fullMask = FloatPlane(width: 2, height: 2, value: 1)
expectClose3(PixelKit.medianRGB(checker, mask: fullMask), SIMD3<Float>(0.5, 0.5, 0.5), 1e-6,
             "medianRGB interpolates between two equally frequent levels")
var whiteMask = FloatPlane(width: 2, height: 2, value: 0)
whiteMask[1, 0] = 1
whiteMask[0, 1] = 1
expectClose3(PixelKit.medianRGB(checker, mask: whiteMask), SIMD3<Float>(1, 1, 1), 1e-6,
             "medianRGB restricts to mask > 0.5 pixels")
let zeroMask = FloatPlane(width: 2, height: 2, value: 0)
expectClose3(PixelKit.medianRGB(checker, mask: zeroMask), SIMD3<Float>(0.5, 0.5, 0.5), 1e-6,
             "medianRGB falls back to the whole image for an empty mask")
expect(PixelKit.medianRGB(RGBAImage(width: 0, height: 0, bytes: []), mask: zeroMask) == SIMD3<Float>(0, 0, 0),
       "medianRGB of an empty image is black")

// MARK: - 12. synthetic blob end to end

print("-- synthetic blob --")

// 41x41 Gaussian blob, exactly the shape used to calibrate the smoothing masks.
var blob = FloatPlane(width: 41, height: 41)
for y in 0..<41 {
    for x in 0..<41 {
        let dx = Double(x - 20)
        let dy = Double(y - 20)
        blob[x, y] = Float(exp(-(dx * dx + dy * dy) / (2.0 * 6.0 * 6.0)))
    }
}
expectClose(blob[20, 20], 1.0, 1e-6, "blob peak is 1")
expectClose(PixelKit.percentile(blob, mask: nil, 100), 1.0, 1e-6, "blob percentile 100 is its peak")
expectClose(PixelKit.percentile(blob, mask: nil, 50), 0.0252, 1e-3, "blob median matches the numpy reference")

var blobPlateau = FloatPlane(width: 41, height: 41)
for y in 0..<41 {
    for x in 0..<41 { blobPlateau[x, y] = blob[x, y] > 0.5 ? 1 : 0 }
}
expectClose(PixelKit.percentile(blob, mask: blobPlateau, 50), 0.7066, 1e-3,
            "masked blob percentile reproduces the numpy reference")

let blobBox = PixelKit.boxBlur(blob, radius: 2)
let blobGauss = PixelKit.gaussianBlur(blob, sigma: 2.0)
let blobGuided = PixelKit.guidedFilter(guide: blob, src: blob, radius: 4, eps: 1e-2)
expectClose(blobBox[20, 20], 0.9465, 5e-3, "boxBlur(radius 2) peak of the blob")
expectClose(blobGauss[20, 20], 0.8985, 5e-3, "gaussianBlur(sigma 2) peak of the blob")
expectClose(blobGuided[20, 20], 0.9333, 5e-3, "guidedFilter peak of the blob")
expect(blobGauss[20, 20] < blobGuided[20, 20],
       "guidedFilter keeps more of the blob peak than a plain Gaussian")
expect(blobGuided[20, 20] < blob[20, 20], "guidedFilter still smooths the flat top of the blob")
expect(blobGuided[19, 20] >= 0 && blobGuided[19, 20] <= 1, "guidedFilter stays within 0...1 for a 0...1 input")

let skinGrey = PixelKit.rgbToLab(r: 0.72, g: 0.55, b: 0.47)
let referenceSkin = PixelKit.rgbToLab(r: 0.75, g: 0.57, b: 0.49)
expect(PixelKit.deltaE2000(skinGrey, referenceSkin) < 5, "a small skin tone shift stays under 5 deltaE")
let strongerShift = PixelKit.rgbToLab(r: 0.62, g: 0.42, b: 0.36)
expect(PixelKit.deltaE2000(skinGrey, strongerShift) > PixelKit.deltaE2000(skinGrey, referenceSkin),
       "deltaE grows with the size of the tone shift")

// MARK: - 13. robustness

print("-- robustness --")

expect(PixelKit.boxBlur(emptyPlane, radius: 3).isEmpty, "boxBlur survives an empty plane")
expect(PixelKit.gaussianBlur(emptyPlane, sigma: 2.0).isEmpty, "gaussianBlur survives an empty plane")
expect(PixelKit.minimumFilter(emptyPlane, radius: 2).isEmpty, "minimumFilter survives an empty plane")
expect(PixelKit.guidedFilter(guide: emptyPlane, src: emptyPlane, radius: 2, eps: 1e-2).isEmpty,
       "guidedFilter survives an empty plane")
expectClose(PixelKit.percentile(constant, mask: nil, 50), 0.3, 1e-6, "percentile of a constant plane is that constant")
let single = FloatPlane(width: 1, height: 1, value: 0.6)
expectClose(PixelKit.percentile(single, mask: nil, 50), 0.6, 1e-6, "percentile of a single sample")
expectClose(PixelKit.gaussianBlur(single, sigma: 5.0)[0, 0], 0.6, 1e-6,
            "gaussianBlur of a single pixel plane keeps its value")

if failures == 0 {
    print("\nALL PASS (\(checks) checks)")
} else {
    print("\nFAILURES: \(failures) of \(checks) checks")
    exit(1)
}
