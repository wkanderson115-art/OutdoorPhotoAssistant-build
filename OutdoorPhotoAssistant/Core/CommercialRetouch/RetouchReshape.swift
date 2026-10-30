import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Parametric studio liquify. Every slider is a deterministic warp with a hard
/// displacement cap, smooth falloff and frame-edge locking; nothing here is a
/// free brush, so a slider can never destroy a face.
///
/// Coordinate convention
/// ---------------------
/// `FaceGeometry` and `ReshapeParameters` are defined in normalised top-left /
/// y-down space (the Python reference lab convention). Core Image works with an
/// origin at the bottom-left and `+y` upwards, so every point is converted once:
///
///     ciY = size.height - normY * size.height
///
/// All internal maths is then done in Core Image pixel space (`+y` up). The
/// public `displacementField(size:geometry:parameters:)` follows that: row 0 of
/// the returned arrays is the **top** image row, while `dy` is a Core Image
/// offset, i.e. a positive `dy` moves the sample up.
///
/// Determinism / continuity
/// ------------------------
/// Each slider is one radial "squeeze" term built from
///
///     o   = (p - centre) / radius                (ellipse normalised offset)
///     t   = clamp(1 - |o|, 0, 1)
///     s   = t * t * (3 - 2 * t)                  (smoothstep falloff)
///     off -= amp * s * (o.x, bias * o.y)
///
/// `|off| <= amp` by construction, `s` is C1 (zero slope at both ends of the
/// support), and the amplitude of every term is kept far enough below its radius
/// that the summed field never moves more than ~0.13 px between 4-neighbours.
/// `tests/reshape/main.swift` asserts that invariant.
final class RetouchReshapeEngine {

    // MARK: - Nested value types

    /// One radial squeeze term of the warp, expressed in Core Image pixels.
    private struct Term {
        var cx: Double
        var cy: Double
        var rx: Double
        var ry: Double
        var amp: Double
        var bias: Double
    }

    /// Every scalar the warp needs, pre-computed once per call. The kernel and
    /// the CPU reference both read from this, so they cannot drift apart.
    /// Core Image pixel space, zero origin, `+y` up. Radii are always >= 1 px
    /// (the kernel divides by them).
    private struct WarpSetup {
        var faceCX: Double = 0
        var faceCY: Double = 0
        var faceRX: Double = 1
        var faceRY: Double = 1
        var faceAmp: Double = 0
        var jawCY: Double = 0
        var jawRX: Double = 1
        var jawRY: Double = 1
        var jawAmp: Double = 0
        var chinCY: Double = 0
        var chinRX: Double = 1
        var chinRY: Double = 1
        var chinAmp: Double = 0
        var eye0X: Double = 0
        var eye0Y: Double = 0
        var eye1X: Double = 0
        var eye1Y: Double = 0
        var eyeRadius: Double = 1
        var eyeAmp: Double = 0
        var noseCX: Double = 0
        var noseCY: Double = 0
        var noseRX: Double = 1
        var noseRY: Double = 1
        var noseAmp: Double = 0
        var neckAmp: Double = 0
        var waistAmp: Double = 0
        var armAmp: Double = 0
        var width: Double = 1
        var height: Double = 1
        var band: Double = 1
        var ramp: Double = 1
        var cap: Double = 1
    }

    // MARK: - Tuning constants

    /// Displacement amplitudes as a fraction of the face width (or of the frame
    /// width for the body bands), evaluated at slider = 1.
    private static let faceWidthAmount = 0.060   // <= 6 % of the face width, per spec
    private static let jawAmount = 0.052
    private static let chinAmount = 0.045
    private static let eyeAmount = 0.055
    private static let noseAmount = 0.032
    private static let neckAmount = 0.026        // of the frame width
    private static let waistAmount = 0.030
    private static let armAmount = 0.016

    /// Vertical coupling of the jaw / chin / nose terms. Positive contracts
    /// towards the term centre along y; negative pushes away from it.
    private static let jawBias = 0.30
    private static let chinBias = -0.20
    private static let noseBias = 0.60

    /// Radius of every term, as a multiple of the face width / height (or of the
    /// frame). Wide radii are what keeps the field C1: the slope of a term is at
    /// most ~1.3 * amp / radius, and amp / radius is <= 0.06 here.
    private static let faceRX = 1.25
    private static let faceRY = 1.15
    private static let jawRX = 1.05
    private static let jawRY = 0.70
    private static let chinRX = 0.80
    private static let chinRY = 0.50
    private static let noseRX = 0.55
    private static let noseRY = 0.40
    private static let eyeRX = 1.55
    private static let eyeMinRX = 0.34

    /// The outer 8 % of the long edge is dead: `edgeLock` only widens the
    /// smoothstep ramp that follows it (0.072 ... 0.12 of the long edge), so the
    /// border never moves for any slider setting.
    private static let lockBand = 0.08

    // MARK: - Kernel source

    /// Core Image Kernel Language source of the single warp kernel used at full
    /// resolution. It must stay byte-for-byte in sync with
    /// `displacementField(size:geometry:parameters:)`.
    ///
    /// Arguments (all `vec4`, packed so the call stays at nine arguments):
    ///   0 face   (cx, cy, rx, ry) of the face-width squeeze
    ///   1 jaw    (cx, cy, rx, ry)
    ///   2 chin   (cx, cy, rx, ry)
    ///   3 eyes   (x0, y0, x1, y1)
    ///   4 nose   (cx, cy, rx, ry)
    ///   5 faceAmps  (faceWidth, jaw, chin, eye)      pixels
    ///   6 bandAmps  (nose, neck, waist, arm)         pixels
    ///   7 frame     (minX, minY, maxX, maxY)
    ///   8 lock      (band, ramp, eyeRadius, cap)     pixels
    private static let warpSource = """
    kernel vec2 opaReshapeWarp(vec4 face, vec4 jaw, vec4 chin, vec4 eyes, vec4 nose, vec4 faceAmps, vec4 bandAmps, vec4 frame, vec4 lock) {
        vec2 d = destCoord();
        vec2 off = vec2(0.0, 0.0);
        vec2 o = vec2(0.0, 0.0);
        vec2 wh = vec2(frame.z - frame.x, frame.w - frame.y);
        float t = 0.0;
        float s = 0.0;
        float de = 0.0;
        float mag = 0.0;

        o = (d - vec2(face.x, face.y)) / vec2(face.z, face.w);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(faceAmps.x * s * o.x, 0.0);

        o = (d - vec2(face.x, jaw.y)) / vec2(jaw.z, jaw.w);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(faceAmps.y * s * o.x, faceAmps.y * 0.30 * s * o.y);

        o = (d - vec2(face.x, chin.y)) / vec2(chin.z, chin.w);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(faceAmps.z * s * o.x, -0.20 * faceAmps.z * s * o.y);

        o = (d - vec2(eyes.x, eyes.y)) / lock.z;
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(faceAmps.w * s * o.x, faceAmps.w * s * o.y);

        o = (d - vec2(eyes.z, eyes.w)) / lock.z;
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(faceAmps.w * s * o.x, faceAmps.w * s * o.y);

        o = (d - vec2(nose.x, nose.y)) / vec2(nose.z, nose.w);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(bandAmps.x * s * o.x, 0.60 * bandAmps.x * s * o.y);

        o = (d - vec2(0.5 * wh.x, 0.56 * wh.y)) / vec2(0.30 * wh.x, 0.085 * wh.y);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(bandAmps.y * s * o.x, 0.0);

        o = (d - vec2(0.5 * wh.x, 0.28 * wh.y)) / vec2(0.42 * wh.x, 0.16 * wh.y);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(bandAmps.z * s * o.x, 0.0);

        o = (d - vec2(0.24 * wh.x, 0.38 * wh.y)) / vec2(0.20 * wh.x, 0.22 * wh.y);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(bandAmps.w * s * o.x, 0.0);

        o = (d - vec2(0.76 * wh.x, 0.38 * wh.y)) / vec2(0.20 * wh.x, 0.22 * wh.y);
        t = clamp(1.0 - length(o), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        off = off - vec2(bandAmps.w * s * o.x, 0.0);

        de = min(min(d.x - frame.x, frame.z - d.x), min(d.y - frame.y, frame.w - d.y));
        t = clamp((de - lock.x) / lock.y, 0.0, 1.0);
        off = off * (t * t * (3.0 - 2.0 * t));

        mag = length(off);
        off = off * min(1.0, lock.w / max(mag, 0.000001));
        return d + off;
    }
    """

    // MARK: - Stored state

    /// Kept for symmetry with `RetouchEngine`; the warp is evaluated lazily by
    /// Core Image at render time and needs no explicit context.
    private let context: CIContext

    /// Compiled warp kernel, or nil when the kernel source did not compile on
    /// this OS/GPU combination (then the built-in distortion chain is used).
    private let warp: CIWarpKernel?

    /// Creates the engine and compiles the warp kernel once.
    init(context: CIContext) {
        self.context = context
        self.warp = CIWarpKernel(source: RetouchReshapeEngine.warpSource)
    }

    // MARK: - Public API

    /// Applies the warp to a full-resolution image. `geometry` is normalised
    /// top-left/y-down (may be nil for non-portrait frames: then only neck/waist
    /// bands from the image proportions are used).
    ///
    /// Returns `image` untouched for neutral parameters, degenerate sizes, or
    /// when Core Image refuses to produce the warp.
    func apply(_ image: CIImage, geometry: FaceGeometry?, parameters: ReshapeParameters) -> CIImage {
        let clamped = parameters.clamped()
        guard !clamped.isNeutral else { return image }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 2, extent.height >= 2 else { return image }

        let size = CGSize(width: extent.width, height: extent.height)
        let warpSetup = self.setup(size: size, geometry: geometry, parameters: clamped)
        // Work in a zero-origin frame so kernel arguments and pixel coordinates
        // agree regardless of where the image sits in its own coordinate space.
        let local = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                            y: -extent.minY))
        let frame = CGRect(origin: CGPoint.zero, size: size)
        var warped: CIImage?
        if let warp = warp {
            let pad = max(CGFloat(warpSetup.cap), 1)
            // The warp can pull from anywhere inside the displacement cap, so the
            // region of interest is the destination rect grown by that cap.
            let roi: CIKernelROICallback = { (_: Int32, rect: CGRect) -> CGRect in
                return rect.insetBy(dx: -pad, dy: -pad)
            }
            warped = warp.apply(extent: frame,
                                roiCallback: roi,
                                image: local,
                                arguments: kernelArguments(warpSetup))
        } else {
            warped = builtInWarp(local, setup: warpSetup, extent: frame)
        }
        guard let output = warped else { return image }
        let restored = output.transformed(by: CGAffineTransform(translationX: extent.minX,
                                                                y: extent.minY))
        return restored.cropped(to: extent)
    }

    /// Displacement field in pixels (source = dest + offset), for previews/tests.
    /// dx/dy are row-major, width x height, in Core Image orientation (y up).
    /// Row 0 is the top image row of a zero-origin frame of `size`.
    func displacementField(size: CGSize, geometry: FaceGeometry?, parameters: ReshapeParameters)
        -> (dx: [Float], dy: [Float], width: Int, height: Int) {
        let clamped = parameters.clamped()
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1 else {
            return (dx: [], dy: [], width: 0, height: 0)
        }
        let width = Int(min(size.width.rounded(), 16384))
        let height = Int(min(size.height.rounded(), 16384))
        // A field is a preview / test product: 32 megapixels is plenty and keeps
        // the two Float buffers bounded. Full-resolution callers use apply().
        guard width > 0, height > 0, width * height <= 33_554_432 else {
            return (dx: [], dy: [], width: 0, height: 0)
        }
        var dx = [Float](repeating: 0, count: width * height)
        var dy = [Float](repeating: 0, count: width * height)
        guard !clamped.isNeutral else { return (dx: dx, dy: dy, width: width, height: height) }

        let frameSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let warpSetup = self.setup(size: frameSize, geometry: geometry, parameters: clamped)
        let list = terms(warpSetup)
        guard !list.isEmpty else { return (dx: dx, dy: dy, width: width, height: height) }

        let w = Double(width)
        let h = Double(height)
        let count = list.count
        for row in 0..<height {
            // row 0 is the top image row, Core Image y grows upwards
            let y = h - Double(row) - 0.5
            for col in 0..<width {
                let x = Double(col) + 0.5
                var ox = 0.0
                var oy = 0.0
                var i = 0
                while i < count {
                    let term = list[i]
                    let ux = (x - term.cx) / term.rx
                    let uy = (y - term.cy) / term.ry
                    var t = 1.0 - (ux * ux + uy * uy).squareRoot()
                    if t > 0 {
                        if t > 1 { t = 1 }
                        let s = t * t * (3.0 - 2.0 * t)
                        ox -= term.amp * s * ux
                        oy -= term.amp * term.bias * s * uy
                    }
                    i += 1
                }
                // frame-edge lock: exactly zero inside the outer 8 % of the long edge
                let dEdge = min(min(x, w - x), min(y, h - y))
                if dEdge > warpSetup.band {
                    var t = (dEdge - warpSetup.band) / warpSetup.ramp
                    if t > 1 { t = 1 }
                    let lock = t * t * (3.0 - 2.0 * t)
                    ox *= lock
                    oy *= lock
                } else {
                    ox = 0
                    oy = 0
                }
                // hard cap on the vector magnitude, in long-edge units
                let mag = (ox * ox + oy * oy).squareRoot()
                if mag > warpSetup.cap {
                    let k = warpSetup.cap / mag
                    ox *= k
                    oy *= k
                }
                let index = row * width + col
                dx[index] = Float(ox)
                dy[index] = Float(oy)
            }
        }
        return (dx: dx, dy: dy, width: width, height: height)
    }

    /// Bounding box (in image pixels) that a slider set can affect; used to keep
    /// the ROI small when applying the warp. Zero-origin, same space as
    /// `displacementField`; `.zero` for neutral parameters.
    func affectedBounds(size: CGSize, geometry: FaceGeometry?, parameters: ReshapeParameters) -> CGRect {
        let clamped = parameters.clamped()
        guard !clamped.isNeutral, size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1 else { return CGRect.zero }
        let warpSetup = self.setup(size: size, geometry: geometry, parameters: clamped)
        let list = terms(warpSetup)
        guard !list.isEmpty else { return CGRect.zero }
        let frame = CGRect(origin: CGPoint.zero,
                           size: CGSize(width: CGFloat(warpSetup.width), height: CGFloat(warpSetup.height)))
        let pad = CGFloat(max(warpSetup.cap, 1))
        var union = CGRect.zero
        var hasRect = false
        for term in list {
            let rect = CGRect(x: CGFloat(term.cx - term.rx), y: CGFloat(term.cy - term.ry),
                              width: CGFloat(term.rx * 2), height: CGFloat(term.ry * 2))
                .insetBy(dx: -pad, dy: -pad)
            union = hasRect ? union.union(rect) : rect
            hasRect = true
        }
        let clipped = union.intersection(frame)
        return clipped.isNull ? CGRect.zero : clipped
    }

    // MARK: - Setup

    /// Pre-computes the warp scalars. `parameters` must already be the output of
    /// `ReshapeParameters.clamped()` (`clamped()` is not idempotent: it scales
    /// eyeSize and noseWidth, so it must be applied exactly once per call).
    private func setup(size: CGSize, geometry: FaceGeometry?, parameters: ReshapeParameters) -> WarpSetup {
        var setup = WarpSetup()
        let w = max(Double(size.width), 1)
        let h = max(Double(size.height), 1)
        let longEdge = max(w, h)
        setup.width = w
        setup.height = h
        setup.cap = max(parameters.maxDisplacement, 0.001) * longEdge
        setup.band = RetouchReshapeEngine.lockBand * longEdge
        // A stronger edgeLock widens the ramp, which locks the frame harder.
        setup.ramp = max(setup.band * (0.5 + parameters.edgeLock), 1)

        if let geometry = geometry {
            let boxWidth = Double(geometry.box.width) * w
            let boxHeight = Double(geometry.box.height) * h
            if boxWidth > 2, boxHeight > 2 {
                let faceCX = Double(geometry.box.midX) * w
                // top-left / y-down -> Core Image y-up
                let faceCY = (1.0 - Double(geometry.box.midY)) * h
                let jawCY = (1.0 - (Double(geometry.box.minY) + 0.66 * Double(geometry.box.height))) * h
                let chinCY = (1.0 - (Double(geometry.box.minY) + 0.86 * Double(geometry.box.height))) * h

                setup.faceCX = faceCX
                setup.faceCY = faceCY
                setup.faceRX = max(RetouchReshapeEngine.faceRX * boxWidth, 1)
                setup.faceRY = max(RetouchReshapeEngine.faceRY * boxHeight, 1)
                setup.faceAmp = RetouchReshapeEngine.faceWidthAmount * boxWidth * parameters.faceWidth

                setup.jawCY = jawCY
                setup.jawRX = max(RetouchReshapeEngine.jawRX * boxWidth, 1)
                setup.jawRY = max(RetouchReshapeEngine.jawRY * boxHeight, 1)
                setup.jawAmp = RetouchReshapeEngine.jawAmount * boxWidth * parameters.jawline

                setup.chinCY = chinCY
                setup.chinRX = max(RetouchReshapeEngine.chinRX * boxWidth, 1)
                setup.chinRY = max(RetouchReshapeEngine.chinRY * boxHeight, 1)
                setup.chinAmp = RetouchReshapeEngine.chinAmount * boxWidth * parameters.chin

                let (leftEye, rightEye) = geometry.derivedEyes()
                setup.eye0X = Double(leftEye.midX) * w
                setup.eye0Y = (1.0 - Double(leftEye.midY)) * h
                setup.eye1X = Double(rightEye.midX) * w
                setup.eye1Y = (1.0 - Double(rightEye.midY)) * h
                let eyePixels = max(max(Double(leftEye.width) * w, Double(leftEye.height) * h), 1)
                // The eye radius is floored at a fraction of the face width so a
                // degenerate detection cannot turn the magnifier into a spike.
                let eyeRadius = max(RetouchReshapeEngine.eyeRX * eyePixels,
                                    max(RetouchReshapeEngine.eyeMinRX * boxWidth, 1))
                setup.eyeRadius = eyeRadius
                // amp / radius <= 0.22 keeps the centre magnification under the
                // 1.35x cap while staying C1.
                setup.eyeAmp = min(RetouchReshapeEngine.eyeAmount * boxWidth * parameters.eyeSize,
                                   max(0.22 * eyeRadius, 0))

                var noseX = Double(geometry.box.midX)
                var noseY = Double(geometry.box.minY) + 0.62 * Double(geometry.box.height)
                if let nose = geometry.nose {
                    noseX = Double(nose.x)
                    noseY = Double(nose.y)
                }
                setup.noseCX = noseX * w
                setup.noseCY = (1.0 - noseY) * h
                setup.noseRX = max(RetouchReshapeEngine.noseRX * boxWidth, 1)
                setup.noseRY = max(RetouchReshapeEngine.noseRY * boxHeight, 1)
                setup.noseAmp = RetouchReshapeEngine.noseAmount * boxWidth * parameters.noseWidth
            }
        }

        // Body bands are pure frame proportions, so they also work without a face.
        setup.neckAmp = RetouchReshapeEngine.neckAmount * w * parameters.neckThin
        setup.waistAmp = RetouchReshapeEngine.waistAmount * w * parameters.waist
        setup.armAmp = RetouchReshapeEngine.armAmount * w * parameters.armThin
        return setup
    }

    /// Flattens the setup into the term list both paths evaluate. Band centres
    /// and radii are the same fixed frame fractions the kernel hardcodes.
    private func terms(_ setup: WarpSetup) -> [Term] {
        var list: [Term] = []
        list.reserveCapacity(10)
        if setup.faceAmp > 0 {
            list.append(Term(cx: setup.faceCX, cy: setup.faceCY,
                             rx: setup.faceRX, ry: setup.faceRY,
                             amp: setup.faceAmp, bias: 0))
        }
        if setup.jawAmp > 0 {
            list.append(Term(cx: setup.faceCX, cy: setup.jawCY,
                             rx: setup.jawRX, ry: setup.jawRY,
                             amp: setup.jawAmp, bias: RetouchReshapeEngine.jawBias))
        }
        if setup.chinAmp > 0 {
            list.append(Term(cx: setup.faceCX, cy: setup.chinCY,
                             rx: setup.chinRX, ry: setup.chinRY,
                             amp: setup.chinAmp, bias: RetouchReshapeEngine.chinBias))
        }
        if setup.eyeAmp > 0 {
            list.append(Term(cx: setup.eye0X, cy: setup.eye0Y,
                             rx: setup.eyeRadius, ry: setup.eyeRadius,
                             amp: setup.eyeAmp, bias: 1))
            list.append(Term(cx: setup.eye1X, cy: setup.eye1Y,
                             rx: setup.eyeRadius, ry: setup.eyeRadius,
                             amp: setup.eyeAmp, bias: 1))
        }
        if setup.noseAmp > 0 {
            list.append(Term(cx: setup.noseCX, cy: setup.noseCY,
                             rx: setup.noseRX, ry: setup.noseRY,
                             amp: setup.noseAmp, bias: RetouchReshapeEngine.noseBias))
        }
        let w = setup.width
        let h = setup.height
        if setup.neckAmp > 0 {
            list.append(Term(cx: 0.5 * w, cy: 0.56 * h,
                             rx: max(0.30 * w, 1), ry: max(0.085 * h, 1),
                             amp: setup.neckAmp, bias: 0))
        }
        if setup.waistAmp > 0 {
            list.append(Term(cx: 0.5 * w, cy: 0.28 * h,
                             rx: max(0.42 * w, 1), ry: max(0.16 * h, 1),
                             amp: setup.waistAmp, bias: 0))
        }
        if setup.armAmp > 0 {
            list.append(Term(cx: 0.24 * w, cy: 0.38 * h,
                             rx: max(0.20 * w, 1), ry: max(0.22 * h, 1),
                             amp: setup.armAmp, bias: 0))
            list.append(Term(cx: 0.76 * w, cy: 0.38 * h,
                             rx: max(0.20 * w, 1), ry: max(0.22 * h, 1),
                             amp: setup.armAmp, bias: 0))
        }
        return list
    }

    /// Packs the setup into the nine `vec4` kernel arguments. Scalars inside a
    /// kernel call must be `NSNumber` / `CIVector`, never bare Swift numbers.
    private func kernelArguments(_ setup: WarpSetup) -> [Any] {
        let face = CIVector(x: CGFloat(setup.faceCX), y: CGFloat(setup.faceCY),
                            z: CGFloat(setup.faceRX), w: CGFloat(setup.faceRY))
        let jaw = CIVector(x: CGFloat(setup.faceCX), y: CGFloat(setup.jawCY),
                           z: CGFloat(setup.jawRX), w: CGFloat(setup.jawRY))
        let chin = CIVector(x: CGFloat(setup.faceCX), y: CGFloat(setup.chinCY),
                            z: CGFloat(setup.chinRX), w: CGFloat(setup.chinRY))
        let eyes = CIVector(x: CGFloat(setup.eye0X), y: CGFloat(setup.eye0Y),
                            z: CGFloat(setup.eye1X), w: CGFloat(setup.eye1Y))
        let nose = CIVector(x: CGFloat(setup.noseCX), y: CGFloat(setup.noseCY),
                            z: CGFloat(setup.noseRX), w: CGFloat(setup.noseRY))
        let faceAmps = CIVector(x: CGFloat(setup.faceAmp), y: CGFloat(setup.jawAmp),
                                z: CGFloat(setup.chinAmp), w: CGFloat(setup.eyeAmp))
        let bandAmps = CIVector(x: CGFloat(setup.noseAmp), y: CGFloat(setup.neckAmp),
                                z: CGFloat(setup.waistAmp), w: CGFloat(setup.armAmp))
        let frame = CIVector(x: 0, y: 0,
                             z: CGFloat(setup.width), w: CGFloat(setup.height))
        let lock = CIVector(x: CGFloat(setup.band), y: CGFloat(setup.ramp),
                            z: CGFloat(setup.eyeRadius), w: CGFloat(setup.cap))
        return [face, jaw, chin, eyes, nose, faceAmps, bandAmps, frame, lock]
    }

    // MARK: - Built-in fallback

    /// Degradation path used only when the kernel source fails to compile on the
    /// running OS: the same slider set approximated with built-in distortions.
    /// The chain is slower and cannot express the edge lock or the exact cap, but
    /// it keeps the studio usable instead of silently dropping the reshape.
    ///
    /// `CIPinchDistortion.scale` shrinks towards 1.0 = no distortion, so a
    /// squeeze maps to `1 - strength`; `CIBumpDistortion.scale` grows from 0 =
    /// no distortion, so the eye magnifier maps to `+strength`.
    private func builtInWarp(_ image: CIImage, setup: WarpSetup, extent: CGRect) -> CIImage? {
        var out = image
        for term in terms(setup) {
            let radius = max(CGFloat(max(term.rx, term.ry)), 2)
            let centre = CGPoint(x: CGFloat(term.cx), y: CGFloat(term.cy))
            let strength = min(max(CGFloat(term.amp) / radius, 0.02), 0.85)
            if abs(term.bias - 1.0) < 0.0001 {
                let bump = CIFilter.bumpDistortion()
                bump.inputImage = out
                bump.center = centre
                bump.radius = Float(radius)
                bump.scale = Float(strength)
                if let result = bump.outputImage {
                    out = result.cropped(to: extent)
                }
            } else {
                let pinch = CIFilter.pinchDistortion()
                pinch.inputImage = out
                pinch.center = centre
                pinch.radius = Float(radius)
                pinch.scale = Float(1.0 - strength)
                if let result = pinch.outputImage {
                    out = result.cropped(to: extent)
                }
            }
        }
        return out.cropped(to: extent)
    }
}
