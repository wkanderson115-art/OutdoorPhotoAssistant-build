import Foundation
import CoreGraphics
import CoreImage

// Runtime checks for RetouchReshapeEngine
// (OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchReshape.swift).
//
// Build and run on macOS with the iOS simulator SDK (the engine imports UIKit,
// exactly like RetouchMaskKit.swift in tests/retouchkit):
//
//   SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
//   xcrun swiftc -O -sdk "$SDK" -target arm64-apple-ios16.0-simulator \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchParameters.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchStudioModel.swift \
//     OutdoorPhotoAssistant/Core/CommercialRetouch/RetouchReshape.swift \
//     tests/reshape/main.swift -o /tmp/reshape && /tmp/reshape
//
// The assertions only inspect the displacement field; nothing is rendered. A
// CIContext is created solely because RetouchReshapeEngine.init requires one.
//
// Frame convention used throughout the checks: `dy` is a Core Image offset
// (+y up) while row 0 of the field is the top image row, so the Core Image y of
// pixel (col, row) is `height - row - 0.5`.

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
    checks += 1
    if abs(value - expected) <= tolerance {
        print("PASS: " + label)
    } else {
        failures += 1
        print("FAIL: \(label) -> got \(value), expected \(expected) +/- \(tolerance)")
    }
}

// MARK: - Field wrapper

/// Read-only view over the tuple `displacementField` returns.
struct DisplacementField {
    let dx: [Float]
    let dy: [Float]
    let width: Int
    let height: Int

    init?(_ tuple: (dx: [Float], dy: [Float], width: Int, height: Int)) {
        guard tuple.width > 0, tuple.height > 0 else { return nil }
        guard tuple.dx.count == tuple.width * tuple.height,
              tuple.dy.count == tuple.width * tuple.height else { return nil }
        self.dx = tuple.dx
        self.dy = tuple.dy
        self.width = tuple.width
        self.height = tuple.height
    }

    init(width: Int, height: Int, dx: [Float], dy: [Float]) {
        self.dx = dx
        self.dy = dy
        self.width = width
        self.height = height
    }

    var count: Int { width * height }

    func offsetX(_ col: Int, _ row: Int) -> Double {
        let index = row * width + col
        guard index >= 0, index < dx.count else { return 0 }
        return Double(dx[index])
    }

    func offsetY(_ col: Int, _ row: Int) -> Double {
        let index = row * width + col
        guard index >= 0, index < dy.count else { return 0 }
        return Double(dy[index])
    }
}

// MARK: - Field metrics

/// Longest displacement vector in the field, in pixels.
func maxMagnitude(_ field: DisplacementField) -> Double {
    var worst = 0.0
    for row in 0..<field.height {
        for col in 0..<field.width {
            let x = field.offsetX(col, row)
            let y = field.offsetY(col, row)
            let mag = (x * x + y * y).squareRoot()
            if mag > worst { worst = mag }
        }
    }
    return worst
}

/// Largest change between 4-neighbour displacement vectors, in pixels. This is
/// the C1/Lipschitz invariant the engine is designed around.
func maxNeighbourDelta(_ field: DisplacementField) -> Double {
    var worst = 0.0
    for row in 0..<field.height {
        for col in 0..<field.width {
            let x = field.offsetX(col, row)
            let y = field.offsetY(col, row)
            if col + 1 < field.width {
                let ex = field.offsetX(col + 1, row) - x
                let ey = field.offsetY(col + 1, row) - y
                let delta = (ex * ex + ey * ey).squareRoot()
                if delta > worst { worst = delta }
            }
            if row + 1 < field.height {
                let ex = field.offsetX(col, row + 1) - x
                let ey = field.offsetY(col, row + 1) - y
                let delta = (ex * ex + ey * ey).squareRoot()
                if delta > worst { worst = delta }
            }
        }
    }
    return worst
}

/// Distance, in pixels, from a pixel centre to the nearest frame edge.
func edgeDistance(col: Int, row: Int, width: Int, height: Int) -> Double {
    let x = Double(col) + 0.5
    let y = Double(height - row) - 0.5
    let left = x
    let right = Double(width) - x
    let bottom = y
    let top = Double(height) - y
    return min(min(left, right), min(bottom, top))
}

/// Largest displacement inside the outermost `fraction` of the long edge.
func maxMagnitudeInFrameBand(_ field: DisplacementField, fraction: Double) -> Double {
    let longEdge = Double(max(field.width, field.height))
    let band = fraction * longEdge
    var worst = 0.0
    for row in 0..<field.height {
        for col in 0..<field.width {
            if edgeDistance(col: col, row: row, width: field.width, height: field.height) > band {
                continue
            }
            let x = field.offsetX(col, row)
            let y = field.offsetY(col, row)
            let mag = (x * x + y * y).squareRoot()
            if mag > worst { worst = mag }
        }
    }
    return worst
}

// MARK: - Synthetic scene

/// Deterministic portrait frame: a soft ellipse "face" painted on a 3 px grid so
/// a warp can also be checked from its effect on known pixels.
struct SyntheticScene {
    let width: Int
    let height: Int
    let centerX: Double      // normalised, top-left origin
    let centerY: Double
    let radiusX: Double
    let radiusY: Double
    let gridStep: Int

    var faceBox: CGRect {
        CGRect(x: CGFloat(centerX - radiusX), y: CGFloat(centerY - radiusY),
               width: CGFloat(radiusX * 2), height: CGFloat(radiusY * 2))
    }

    /// Face geometry with eyes / nose / lips left to `derivedEyes()` so the test
    /// exercises the same fallback the app uses when Vision finds nothing.
    var geometry: FaceGeometry {
        FaceGeometry(box: faceBox, leftEye: nil, rightEye: nil, lips: nil, nose: nil)
    }

    func faceContains(normX: Double, normY: Double) -> Bool {
        let dx = (normX - centerX) / radiusX
        let dy = (normY - centerY) / radiusY
        return dx * dx + dy * dy <= 1
    }

    /// Luminance of one pixel: 0.55/0.20 base plus a bright 3 px grid.
    func luminance(col: Int, row: Int) -> Double {
        let c = min(max(col, 0), width - 1)
        let r = min(max(row, 0), height - 1)
        let grid = (c % gridStep == 0 || r % gridStep == 0) ? 0.35 : 0.0
        let normX = (Double(c) + 0.5) / Double(width)
        let normY = (Double(r) + 0.5) / Double(height)
        return faceContains(normX: normX, normY: normY) ? 0.55 + grid : 0.20 + grid * 0.4
    }
}

/// Bilinear sample of the scene; the coordinate is a fractional pixel index.
func sampleScene(_ scene: SyntheticScene, col: Double, row: Double) -> Double {
    let x0 = Int(col.rounded(.down))
    let y0 = Int(row.rounded(.down))
    let fx = col - Double(x0)
    let fy = row - Double(y0)
    let v00 = scene.luminance(col: x0, row: y0)
    let v10 = scene.luminance(col: x0 + 1, row: y0)
    let v01 = scene.luminance(col: x0, row: y0 + 1)
    let v11 = scene.luminance(col: x0 + 1, row: y0 + 1)
    let top = v00 * (1 - fx) + v10 * fx
    let bottom = v01 * (1 - fx) + v11 * fx
    return top * (1 - fy) + bottom * fy
}

/// Scene luminance after the warp: source = destination + offset.
func warpedLuminance(_ scene: SyntheticScene, field: DisplacementField, col: Int, row: Int) -> Double {
    let srcX = Double(col) + field.offsetX(col, row)
    let srcY = Double(scene.height - row) - 0.5 + field.offsetY(col, row)
    let srcRow = Double(scene.height) - srcY - 0.5
    return sampleScene(scene, col: srcX, row: srcRow)
}

// MARK: - Parameter helpers

/// Builds a slider set without relying on the memberwise initialiser.
func sliders(faceWidth: Double = 0, jawline: Double = 0, chin: Double = 0, eyeSize: Double = 0,
             noseWidth: Double = 0, neckThin: Double = 0, waist: Double = 0, armThin: Double = 0,
             edgeLock: Double = 0.85, maxDisplacement: Double = 0.06) -> ReshapeParameters {
    var p = ReshapeParameters.neutral
    p.faceWidth = faceWidth
    p.jawline = jawline
    p.chin = chin
    p.eyeSize = eyeSize
    p.noseWidth = noseWidth
    p.neckThin = neckThin
    p.waist = waist
    p.armThin = armThin
    p.edgeLock = edgeLock
    p.maxDisplacement = maxDisplacement
    return p
}

/// The cap `clamped()` guarantees, in pixels.
func expectedCap(_ parameters: ReshapeParameters, longEdge: Double) -> Double {
    min(0.08, max(0.01, parameters.maxDisplacement)) * longEdge
}

// MARK: - Setup

let frameWidth = 1200
let frameHeight = 1600
let frameSize = CGSize(width: CGFloat(frameWidth), height: CGFloat(frameHeight))
let longEdge = Double(max(frameWidth, frameHeight))
let lockBandFraction = 0.08

let context = CIContext(options: [CIContextOption.useSoftwareRenderer: true])
let engine = RetouchReshapeEngine(context: context)

let scene = SyntheticScene(width: frameWidth, height: frameHeight,
                           centerX: 0.50, centerY: 0.33,
                           radiusX: 0.22, radiusY: 0.17,
                           gridStep: 3)
// A different, horizontally centred face: the symmetry check must not depend on
// one particular geometry.
let symmetricScene = SyntheticScene(width: frameWidth, height: frameHeight,
                                    centerX: 0.50, centerY: 0.30,
                                    radiusX: 0.28, radiusY: 0.20, gridStep: 3)
// A very large face so the maxDisplacement cap actually binds.
let largeScene = SyntheticScene(width: frameWidth, height: frameHeight,
                                centerX: 0.50, centerY: 0.40,
                                radiusX: 0.47, radiusY: 0.31, gridStep: 3)
// A small, off-centre face (near the locked border band).
let smallScene = SyntheticScene(width: frameWidth, height: frameHeight,
                                centerX: 0.42, centerY: 0.45,
                                radiusX: 0.06, radiusY: 0.045, gridStep: 3)

// MARK: - 1. Scene sanity

print("-- scene --")

expect(scene.width == 1200 && scene.height == 1600, "Synthetic frame is 1200 x 1600")
expect(scene.faceContains(normX: scene.centerX, normY: scene.centerY), "Face ellipse contains its centre")
expect(!scene.faceContains(normX: 0.02, normY: 0.98), "Face ellipse excludes the frame corner")
expect(scene.luminance(col: 0, row: 0) > scene.luminance(col: 1, row: 1), "3 px grid lines are brighter than the gaps")
expect(scene.geometry.width > 0.4 && scene.geometry.width < 0.46, "Face box width matches the ellipse")

// A zero field must resample the scene onto itself, border included.
let zeroField = DisplacementField(width: frameWidth, height: frameHeight,
                                  dx: [Float](repeating: 0, count: frameWidth * frameHeight),
                                  dy: [Float](repeating: 0, count: frameWidth * frameHeight))
expectClose(warpedLuminance(scene, field: zeroField, col: 613, row: 517),
            scene.luminance(col: 613, row: 517), 1e-9,
            "A zero field reproduces the source pixel exactly")

// MARK: - 2. Slider series

print("-- slider series --")

let configurations: [(String, SyntheticScene, ReshapeParameters)] = [
    ("faceWidth", scene, sliders(faceWidth: 1)),
    ("jawline", scene, sliders(jawline: 1)),
    ("chin", scene, sliders(chin: 1)),
    ("eyeSize", scene, sliders(eyeSize: 1)),
    ("noseWidth", scene, sliders(noseWidth: 1)),
    ("neckThin", scene, sliders(neckThin: 1)),
    ("waist", scene, sliders(waist: 1)),
    ("armThin", scene, sliders(armThin: 1)),
    ("all sliders", scene, sliders(faceWidth: 1, jawline: 1, chin: 1, eyeSize: 1, noseWidth: 1,
                                   neckThin: 1, waist: 1, armThin: 1)),
    ("all, edgeLock 0.4 cap 1 %", scene, sliders(faceWidth: 1, jawline: 1, chin: 1, eyeSize: 1,
                                                 noseWidth: 1, neckThin: 1, waist: 1, armThin: 1,
                                                 edgeLock: 0.4, maxDisplacement: 0.01)),
    ("all, edgeLock 1.0 cap 8 %", scene, sliders(faceWidth: 1, jawline: 1, chin: 1, eyeSize: 1,
                                                 noseWidth: 1, neckThin: 1, waist: 1, armThin: 1,
                                                 edgeLock: 1.0, maxDisplacement: 0.08)),
    ("bands only, no geometry", scene, sliders(neckThin: 1, waist: 1, armThin: 1)),
    ("very large face, cap 1 %", largeScene, sliders(faceWidth: 1, jawline: 1, chin: 1, eyeSize: 1,
                                                     noseWidth: 1, neckThin: 1, waist: 1, armThin: 1,
                                                     maxDisplacement: 0.01)),
    ("tiny off-centre face", smallScene, sliders(faceWidth: 1, jawline: 1, chin: 1, eyeSize: 1,
                                                 noseWidth: 1, neckThin: 1, waist: 1, armThin: 1))
]

/// One evaluated configuration: the label, the sliders and the resulting field.
struct FieldRun {
    let label: String
    let parameters: ReshapeParameters
    let field: DisplacementField
}

var runs: [FieldRun] = []
for entry in configurations {
    let label = entry.0
    let sceneForRun = entry.1
    let parameters = entry.2
    let geometry: FaceGeometry? = label == "bands only, no geometry" ? nil : sceneForRun.geometry
    guard let field = DisplacementField(engine.displacementField(size: frameSize,
                                                                geometry: geometry,
                                                                parameters: parameters)) else {
        expect(false, "\(label): displacementField returns a \(frameWidth) x \(frameHeight) field")
        continue
    }
    runs.append(FieldRun(label: label, parameters: parameters, field: field))
    expect(field.width == frameWidth && field.height == frameHeight,
           "\(label): field size matches the frame")
}
expect(runs.count == configurations.count, "Every slider setting produced a field")

// (a) hard displacement cap: maxDisplacement * longEdge, after clamping
var worstMagnitude = 0.0
for run in runs {
    worstMagnitude = max(worstMagnitude, maxMagnitude(run.field))
    let cap = expectedCap(run.parameters, longEdge: longEdge)
    expect(maxMagnitude(run.field) <= cap + 0.001,
           "\(run.label): every displacement stays inside maxDisplacement * longEdge (\(cap) px)")
}

// (b) C1 continuity: 4-neighbour displacement delta <= 0.25 px
var worstNeighbour = 0.0
for run in runs {
    worstNeighbour = max(worstNeighbour, maxNeighbourDelta(run.field))
    expect(maxNeighbourDelta(run.field) <= 0.25,
           "\(run.label): 4-neighbour displacement delta stays under 0.25 px")
}

// (c) the outermost 8 % of the long edge never moves
for run in runs {
    expect(maxMagnitudeInFrameBand(run.field, fraction: lockBandFraction) == 0,
           "\(run.label): outer 8 % frame band is exactly locked")
}

print("-- field statistics --")
print("worst displacement   : \(worstMagnitude) px")
print("worst 4-neighbour gap: \(worstNeighbour) px")
expect(worstMagnitude > 1.0, "The slider series actually bends the frame")
expect(worstNeighbour > 0.0, "The slider series produces a non-constant field")

// MARK: - 3. Neutral parameters

print("-- neutral --")

guard let neutralField = DisplacementField(engine.displacementField(size: frameSize,
                                                                   geometry: scene.geometry,
                                                                   parameters: ReshapeParameters.neutral)) else {
    expect(false, "Neutral parameters still return a field of the right size")
    exit(1)
}
var neutralMax = 0.0
for index in 0..<neutralField.count {
    neutralMax = max(neutralMax, abs(Double(neutralField.dx[index])), abs(Double(neutralField.dy[index])))
}
expect(neutralField.count == frameWidth * frameHeight, "Neutral field covers the whole frame")
expect(neutralMax == 0, "Neutral parameters give an all-zero field")
expect(engine.affectedBounds(size: frameSize, geometry: scene.geometry,
                             parameters: ReshapeParameters.neutral) == CGRect.zero,
       "Neutral parameters give an empty affected bound")

// MARK: - 4. Symmetry

print("-- symmetry --")

let symmetricSliders = sliders(faceWidth: 1, jawline: 1, chin: 1, eyeSize: 1, noseWidth: 1,
                               neckThin: 1, waist: 1, armThin: 1)
guard let symmetricField = DisplacementField(engine.displacementField(size: frameSize,
                                                                     geometry: symmetricScene.geometry,
                                                                     parameters: symmetricSliders)) else {
    expect(false, "Symmetric scene produces a field")
    exit(1)
}
var worstAntiSymmetry = 0.0
var worstSymmetry = 0.0
for row in 0..<symmetricField.height {
    for col in 0..<symmetricField.width {
        let mirror = symmetricField.width - 1 - col
        worstAntiSymmetry = max(worstAntiSymmetry,
                                abs(symmetricField.offsetX(col, row) + symmetricField.offsetX(mirror, row)))
        worstSymmetry = max(worstSymmetry,
                            abs(symmetricField.offsetY(col, row) - symmetricField.offsetY(mirror, row)))
    }
}
expect(worstAntiSymmetry <= 1e-3, "Symmetric input gives an antisymmetric dx field")
expect(worstSymmetry <= 1e-3, "Symmetric input gives a symmetric dy field")

// MARK: - 5. Determinism

print("-- determinism --")

guard let first = DisplacementField(engine.displacementField(size: frameSize,
                                                           geometry: scene.geometry,
                                                           parameters: symmetricSliders)),
      let second = DisplacementField(engine.displacementField(size: frameSize,
                                                             geometry: scene.geometry,
                                                             parameters: symmetricSliders)) else {
    expect(false, "Repeated calls produce a field")
    exit(1)
}
var identical = first.count == second.count
if identical {
    for index in 0..<first.count where first.dx[index] != second.dx[index] {
        identical = false
        break
    }
}
if identical {
    for index in 0..<second.count where first.dy[index] != second.dy[index] {
        identical = false
        break
    }
}
expect(identical, "Same input gives bit-identical output")

// MARK: - 6. Warp semantics

print("-- semantics --")

let faceWidthOnly = sliders(faceWidth: 1)
guard let faceWidthField = DisplacementField(engine.displacementField(size: frameSize,
                                                                    geometry: scene.geometry,
                                                                    parameters: faceWidthOnly)) else {
    expect(false, "faceWidth produces a field")
    exit(1)
}
let faceLeftCol = Int((scene.centerX - scene.radiusX) * Double(frameWidth))
let faceRightCol = Int((scene.centerX + scene.radiusX) * Double(frameWidth))
let faceRow = Int(scene.centerY * Double(frameHeight))
let leftOffsetX = faceWidthField.offsetX(faceLeftCol, faceRow)
let rightOffsetX = faceWidthField.offsetX(faceRightCol, faceRow)
expect(leftOffsetX > 1.0, "faceWidth pushes the left cheek inwards (+x)")
expect(rightOffsetX < -1.0, "faceWidth pushes the right cheek inwards (-x)")
expect(faceWidthField.offsetY(faceLeftCol, faceRow) == 0,
       "faceWidth-only warp is a pure horizontal squeeze")

let eyesOnly = sliders(eyeSize: 1)
guard let eyeField = DisplacementField(engine.displacementField(size: frameSize,
                                                              geometry: scene.geometry,
                                                              parameters: eyesOnly)) else {
    expect(false, "eyeSize produces a field")
    exit(1)
}
let (leftEye, rightEye) = scene.geometry.derivedEyes()
let eyeCol = Int(leftEye.midX * Double(frameWidth))
let eyeRow = Int(leftEye.midY * Double(frameHeight))
// Magnification pulls the sample towards the eye centre: left of the centre the
// offset points right, right of the centre it points left.
let eyeOffsetLeft = eyeField.offsetX(eyeCol - 12, eyeRow)
let eyeOffsetRight = eyeField.offsetX(eyeCol + 12, eyeRow)
expect(eyeOffsetLeft > 0 && eyeOffsetRight < 0, "eyeSize magnifies around each eye centre")
expect(rightEye.midX > leftEye.midX, "Derived eye rects are ordered left to right")

// The warp must not touch the frame border but must move grid pixels inside it.
var borderUnchanged = true
var borderSamples = 0
for row in stride(from: 0, to: scene.height, by: 1) {
    let cols = [0, 1, scene.width - 2, scene.width - 1]
    for col in cols {
        borderSamples += 1
        let warped = warpedLuminance(scene, field: symmetricField, col: col, row: row)
        if abs(warped - scene.luminance(col: col, row: row)) > 1e-9 {
            borderUnchanged = false
        }
    }
}
for col in stride(from: 0, to: scene.width, by: 1) {
    let rows = [0, 1, scene.height - 2, scene.height - 1]
    for row in rows {
        borderSamples += 1
        let warped = warpedLuminance(scene, field: symmetricField, col: col, row: row)
        if abs(warped - scene.luminance(col: col, row: row)) > 1e-9 {
            borderUnchanged = false
        }
    }
}
expect(borderSamples > 8000, "The border check sampled the full frame ring")
expect(borderUnchanged, "Warping the scene leaves the frame border bit-identical")

var movedGridPixels = 0
for row in stride(from: 0, to: scene.height, by: 5) {
    for col in stride(from: 0, to: scene.width, by: 5) {
        let moved = abs(warpedLuminance(scene, field: symmetricField, col: col, row: row)
                        - scene.luminance(col: col, row: row))
        if moved > 1e-6 { movedGridPixels += 1 }
    }
}
expect(movedGridPixels > 1000, "Warping the scene moves the 3 px grid inside the frame")

// MARK: - 7. Affected bounds

print("-- affected bounds --")

// A single slider keeps the affected region well inside the frame, which is the
// case the ROI helper exists for.
let bounds = engine.affectedBounds(size: frameSize, geometry: scene.geometry,
                                   parameters: faceWidthOnly)
expect(!bounds.isEmpty, "Non-neutral parameters give a non-empty affected bound")
expect(bounds.width > 0 && bounds.height > 0, "Affected bound has a usable size")
expect(CGRect(origin: .zero, size: frameSize).contains(bounds), "Affected bound stays inside the frame")
expect(bounds.height < CGFloat(frameHeight),
       "A single slider affects less than the whole frame height")

var outsideBounds = 0
for row in 0..<faceWidthField.height {
    for col in 0..<faceWidthField.width {
        let x = faceWidthField.offsetX(col, row)
        let y = faceWidthField.offsetY(col, row)
        if (x * x + y * y).squareRoot() <= 0.5 { continue }
        let point = CGPoint(x: CGFloat(Double(col) + 0.5),
                            y: CGFloat(Double(faceWidthField.height - row) - 0.5))
        if !bounds.insetBy(dx: -1.5, dy: -1.5).contains(point) { outsideBounds += 1 }
    }
}
expect(outsideBounds == 0, "Every displaced pixel falls inside affectedBounds")

// MARK: - 8. Degenerate inputs

print("-- robustness --")

let degenerate = engine.displacementField(size: CGSize(width: 0, height: 0),
                                          geometry: scene.geometry,
                                          parameters: symmetricSliders)
expect(degenerate.width == 0 && degenerate.height == 0 && degenerate.dx.isEmpty,
       "A zero-size frame returns an empty field")
let belowOnePixel = engine.displacementField(size: CGSize(width: 0.5, height: 0.5),
                                             geometry: scene.geometry,
                                             parameters: symmetricSliders)
expect(belowOnePixel.width == 0, "A sub-pixel frame returns an empty field")
expect(engine.affectedBounds(size: CGSize(width: 0, height: 0),
                             geometry: scene.geometry,
                             parameters: symmetricSliders) == CGRect.zero,
       "A zero-size frame gives an empty affected bound")
let tiny = engine.displacementField(size: CGSize(width: 3, height: 2),
                                    geometry: scene.geometry,
                                    parameters: symmetricSliders)
expect(tiny.width == 3 && tiny.height == 2 && tiny.dx.count == 6,
       "A tiny frame still returns a consistent field")
let landscape = engine.displacementField(size: CGSize(width: 2000, height: 300),
                                          geometry: scene.geometry,
                                          parameters: symmetricSliders)
expect(landscape.width == 2000 && landscape.height == 300,
       "A landscape frame returns a field of the requested size")

// MARK: - Summary

if failures == 0 {
    print("\nALL PASS (\(checks) checks)")
} else {
    print("\nFAILURES: \(failures) of \(checks) checks")
    exit(1)
}
