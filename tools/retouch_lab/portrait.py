"""Portrait retouch reference implementation (V16).

Numerical twin of the Swift engine in `Core/CommercialRetouch`. Every stage
takes/returns float32 sRGB in [0,1]; parameter names match `RetouchParameters`
in Swift so the QC numbers here are directly comparable with on-device runs.

Stage order (matches `RetouchPipeline.process`):
    analyze -> detect_spots -> heal_spots -> skin_smoothing -> dodge_burn
            -> eyes -> under_eye -> teeth -> lips
"""

from __future__ import annotations

from dataclasses import dataclass
import os

import numpy as np

from . import ops

ANALYSIS_EDGE = 1024      # masks are computed here, then upsampled (Swift: 1600 proxy)
DETECTION_EDGE = 2000     # blemish detection needs real 2-8 px spots
MAX_SPOTS = 80            # per-pass heal budget (commercial tools also cap this)
_DEBUG = bool(os.environ.get("RETOUCH_DEBUG"))


# --------------------------------------------------------------------------- #
# geometry
# --------------------------------------------------------------------------- #

@dataclass
class FaceGeometry:
    """Normalised coordinates, origin top-left, y down."""
    box: tuple[float, float, float, float]
    left_eye: tuple[float, float, float, float] | None = None   # cx, cy, w, h
    right_eye: tuple[float, float, float, float] | None = None
    lips: tuple[float, float, float, float] | None = None
    nose: tuple[float, float] | None = None

    @property
    def width(self) -> float:
        return self.box[2] - self.box[0]

    @property
    def height(self) -> float:
        return self.box[3] - self.box[1]

    def derived_eyes(self):
        if self.left_eye and self.right_eye:
            return self.left_eye, self.right_eye
        x0, y0, x1, y1 = self.box
        w, h = self.width, self.height
        cy = y0 + h * 0.42
        return ((x0 + w * 0.30, cy, w * 0.26, h * 0.115),
                (x0 + w * 0.70, cy, w * 0.26, h * 0.115))

    def derived_lips(self):
        if self.lips:
            return self.lips
        x0, y0 = self.box[0], self.box[1]
        return (x0 + self.width * 0.5, y0 + self.height * 0.73,
                self.width * 0.34, self.height * 0.13)


def _ellipse(h: int, w: int, cx: float, cy: float, rx: float, ry: float, soft: float = 1.8) -> np.ndarray:
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((xx - cx * w) / max(rx * w, 1e-4)) ** 2 + ((yy - cy * h) / max(ry * h, 1e-4)) ** 2)
    return np.clip((1.0 - d) * soft, 0.0, 1.0).astype(np.float32)


def _rect(h: int, w: int, rect, feather_px: float = 4.0) -> np.ndarray:
    cx, cy, rw, rh = rect
    m = _ellipse(h, w, cx, cy, max(rw, 1e-4) / 2.0, max(rh, 1e-4) / 2.0, soft=2.0)
    return ops.feather(m, max(0.8, feather_px))


# --------------------------------------------------------------------------- #
# analysis
# --------------------------------------------------------------------------- #

@dataclass
class SkinAnalysis:
    skin: np.ndarray
    feature: np.ndarray
    texture: np.ndarray
    noise_sigma: float
    face: FaceGeometry
    skin_lab_median: np.ndarray
    exposure: float
    white_balance: np.ndarray
    long_edge: int


def _auto_white_balance(rgb: np.ndarray) -> np.ndarray:
    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    sat = (mx - mn) / np.maximum(mx, 1e-4)
    flat = sat < float(np.percentile(sat, 30))
    if flat.sum() < 100:
        return np.ones(3, dtype=np.float32)
    means = rgb[flat].mean(axis=0)
    gain = float(means.mean()) / np.maximum(means, 1e-3)
    return np.clip(gain, 0.93, 1.07).astype(np.float32)


def analyze(rgb: np.ndarray, face: FaceGeometry) -> SkinAnalysis:
    h, w = rgb.shape[:2]
    long_edge = max(h, w)
    scale = min(1.0, ANALYSIS_EDGE / float(long_edge))
    small = ops.resize(rgb, (int(round(w * scale)), int(round(h * scale)))) if scale < 1.0 else rgb
    sh, sw = small.shape[:2]

    lab = ops.rgb_to_lab(small)
    ycc = ops.rgb_to_ycbcr(small)
    hsv = ops.hue_sat_value(small)

    fw = max(8.0, face.width * sw)
    fh = max(8.0, face.height * sh)
    x0, y0, x1, y1 = face.box
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0

    prior = _ellipse(sh, sw, cx, y0 + face.height * 0.46,
                     face.width * 0.52, face.height * 0.52, soft=2.4)
    # retouch region: the face oval only. Hands / background skin are never
    # auto-retouched, which is what commercial portrait tools do by default.
    region = _ellipse(sh, sw, cx, y0 + face.height * 0.47,
                      face.width * 0.54, face.height * 0.54, soft=2.0)
    inside = prior > 0.35
    if inside.sum() < 200:
        inside = np.ones((sh, sw), dtype=bool)
    med = np.median(lab[inside], axis=0)

    cb, cr = ycc[..., 1] * 255.0, ycc[..., 2] * 255.0
    y255 = ycc[..., 0] * 255.0
    gate_ycc = ((cb > 76) & (cb < 128) & (cr > 132) & (cr < 174) &
                (y255 > 40) & (y255 < 246)).astype(np.float32)
    d_l = (lab[..., 0] - med[0]) / 42.0
    d_a = (lab[..., 1] - med[1]) / 13.0
    d_b = (lab[..., 2] - med[2]) / 17.0
    chroma_d = np.sqrt(d_a ** 2 + d_b ** 2 + d_l ** 2)
    gate_lab = np.clip((1.0 - chroma_d * 0.85 - 0.15) / 0.5, 0.0, 1.0)
    coarse = np.clip(0.6 * gate_ycc * prior + 0.6 * gate_lab * prior, 0.0, 1.0).astype(np.float32)

    g = ops.luma(small)
    gr = max(2, int(round(fw * 0.04)))
    skin = ops.guided_filter(g, coarse, gr, 2e-3)
    skin = np.clip((skin - 0.30) / 0.42, 0.0, 1.0)
    skin = ops.morph_close(skin, max(1, int(round(fw * 0.006))))

    # Dark brown hair passes the YCbCr skin window. Drop everything much darker
    # than the face's own median luma (fringe, brows, shadowed hairline).
    ref_l = float(np.percentile(g[skin > 0.45], 60)) if (skin > 0.45).sum() > 200 else 0.55
    luma_gate = np.clip((g - ref_l * 0.62) / (ref_l * 0.22 + 1e-3), 0.0, 1.0)
    skin = skin * luma_gate
    skin = np.clip(skin * region, 0.0, 1.0)

    area = float((skin > 0.5).mean())
    if area < 0.005 or area > 0.6:
        skin = np.clip(region * prior * 0.92, 0.0, 1.0)

    eye_l, eye_r = face.derived_eyes()
    lips = face.derived_lips()
    feature = np.zeros((sh, sw), dtype=np.float32)
    for eye in (eye_l, eye_r):
        ex, ey, ew, eh = eye
        feature = np.maximum(feature, _rect(sh, sw, (ex, ey - eh * 0.15, ew * 1.15, eh * 1.7), fw * 0.010))
        feature = np.maximum(feature, _rect(sh, sw, (ex, ey - eh * 1.05, ew * 1.20, eh * 0.70), fw * 0.008))
    feature = np.maximum(feature, _rect(sh, sw, (lips[0], lips[1], lips[2] * 1.12, lips[3] * 1.20), fw * 0.010))
    if face.nose:
        nx, ny = face.nose
    else:
        nx, ny = x0 + face.width * 0.5, y0 + face.height * 0.60
    feature = np.maximum(feature, _rect(sh, sw, (nx, ny, face.width * 0.13, face.height * 0.08), fw * 0.006))
    skin = np.clip(skin * (1.0 - 0.95 * feature), 0.0, 1.0)

    hp = lab[..., 0] - ops.gaussian_blur(lab[..., 0], max(1.2, fw * 0.003))
    texture = np.abs(ops.gaussian_blur(hp, max(1.2, fw * 0.003)))
    flat = skin > 0.6
    noise = float(np.median(texture[flat]) * 1.4826) if flat.sum() > 500 else 1.2
    noise = float(np.clip(noise, 0.35, 6.0))

    stats = lab[skin > 0.7] if (skin > 0.7).sum() > 100 else lab.reshape(-1, 3)
    skin_med = np.median(stats, axis=0).astype(np.float32)
    roi = ycc[..., 0][skin > 0.6]
    exposure = float(np.percentile(roi, 55)) if roi.size > 100 else 0.5

    if scale < 1.0:
        skin = ops.resize(skin, (w, h))
        feature = ops.resize(feature, (w, h))
        texture = ops.resize(texture, (w, h))
    skin = ops.feather(skin, max(0.8, long_edge * 0.0008))

    return SkinAnalysis(skin=skin.astype(np.float32), feature=feature.astype(np.float32),
                        texture=texture.astype(np.float32), noise_sigma=noise, face=face,
                        skin_lab_median=skin_med, exposure=exposure,
                        white_balance=_auto_white_balance(rgb), long_edge=long_edge)


# --------------------------------------------------------------------------- #
# blemish detection
# --------------------------------------------------------------------------- #

@dataclass
class Spot:
    x: int
    y: int
    radius: int
    score: float
    kind: str


def _small(rgb: np.ndarray, edge: int) -> tuple[np.ndarray, float]:
    h, w = rgb.shape[:2]
    s = min(1.0, edge / float(max(h, w)))
    if s >= 1.0:
        return rgb, 1.0
    return ops.resize(rgb, (int(round(w * s)), int(round(h * s)))), s


def detect_spots(rgb: np.ndarray, a: SkinAnalysis, sensitivity: float = 0.6) -> list[Spot]:
    """Blemish detector: per-scale normalised LoG (scale-space blob detector).

    Each scale is normalised by its own robust MAD inside the allowed region, so
    a lighting gradient at a large scale can never outvote a small pimple. The
    winning scale also gives the spot radius (r = sqrt(2) * sigma), which keeps
    the heal patch sized correctly at any resolution.
    """
    small, s = _small(rgb, DETECTION_EDGE)
    h, w = small.shape[:2]
    lab = ops.rgb_to_lab(small)
    L, A, B = lab[..., 0], lab[..., 1], lab[..., 2]

    skin_s = ops.resize(a.skin, (w, h)) if a.skin.shape[:2] != (h, w) else a.skin[:h, :w]
    feat_s = ops.resize(a.feature, (w, h)) if a.feature.shape[:2] != (h, w) else a.feature[:h, :w]

    fw_px = max(12.0, a.face.width * w)
    grad = np.hypot(*np.gradient(ops.gaussian_blur(L, 1.4)))
    allowed = (skin_s > 0.50) & (feat_s < 0.15) & (L > 16.0) & (L < 95.0) & (grad < 22.0)
    if allowed.sum() < 200:
        return []

    sigmas = [max(1.2, fw_px * f) for f in (0.004, 0.006, 0.009)]
    resp = np.zeros((h, w), dtype=np.float32)
    rad = np.zeros((h, w), dtype=np.float32)
    for sig in sigmas:
        r = np.abs(ops.log_response(L, sig)) + 0.7 * np.abs(ops.log_response(A, sig))
        r = ops.gaussian_blur(r, max(0.6, sig * 0.45))
        mad = float(np.median(r[allowed])) * 1.4826 + 0.04
        z = r / mad
        upd = z > resp
        resp = np.where(upd, z, resp)
        rad = np.where(upd, (2.0 ** 0.5) * sig, rad)
    resp = np.where(allowed, resp, 0.0)

    surround = max(5.0, fw_px * 0.05)
    sur_L = ops.gaussian_blur(L, surround)
    sur_A = ops.gaussian_blur(A, surround)
    sur_B = ops.gaussian_blur(B, surround)
    thr = 3.4 + 3.2 * (1.0 - sensitivity)

    local_max = ops.maximum_filter(resp, max(3, int(round(fw_px * 0.012))))
    peaks = (resp > thr) & (resp >= local_max * 0.995) & allowed
    ys, xs = np.nonzero(peaks)
    if _DEBUG:
        print(f"[detect] allowed={allowed.mean():.3f} z p50/p99/max="
              f"{[round(float(np.percentile(resp[allowed], p)), 2) for p in (50, 99, 100)]} "
              f"thr={thr:.2f} peaks={ys.size}")
    if ys.size == 0:
        return []

    order = np.argsort(-resp[ys, xs])[:8000]
    taken = np.zeros((h, w), dtype=bool)
    out: list[Spot] = []
    for idx in order:
        y, x = int(ys[idx]), int(xs[idx])
        r = float(rad[y, x])
        if taken[max(0, y - int(r)):y + int(r) + 1, max(0, x - int(r)):x + int(r) + 1].any():
            continue
        rr = int(max(3, round(r * 2.2)))
        y0, y1 = max(0, y - rr), min(h, y + rr + 1)
        x0, x1 = max(0, x - rr), min(w, x + rr + 1)
        wl, wa = L[y0:y1, x0:x1], A[y0:y1, x0:x1]
        if wl.size < 25:
            continue
        yy = np.arange(y1 - y0, dtype=np.float32)[:, None] - (y - y0)
        xx = np.arange(x1 - x0, dtype=np.float32)[None, :] - (x - x0)
        ring = np.sqrt(yy ** 2 + xx ** 2)
        inner = ring <= max(1.5, r * 0.7)
        outer = (ring > max(2.5, r * 1.8)) & (ring <= rr)
        if inner.sum() < 4 or outer.sum() < 10:
            continue
        c_l = float(wl[outer].mean() - wl[inner].mean())
        c_a = float(wa[inner].mean() - wa[outer].mean())
        if c_l < 1.0 and c_a < 1.0:
            continue
        ring_std = float(np.std(wl[outer]))
        if ring_std > max(6.0, abs(c_l) * 0.9 + 3.0):
            continue
        de = float(ops.delta_e_2000(lab[y, x], np.array([sur_L[y, x], sur_A[y, x], sur_B[y, x]], dtype=np.float32)))
        if de < 2.5 and c_l < 2.0:
            continue
        conf = (float(np.clip(resp[y, x] / (thr * 2.0), 0.0, 1.0)) * 0.55 +
                float(np.clip(de / 9.0, 0.0, 1.0)) * 0.45)
        if conf < 0.10:
            continue
        out.append(Spot(x=int(round(x / s)), y=int(round(y / s)),
                        radius=int(max(2, round(r / s * 0.95))),
                        score=conf, kind="acne" if c_a >= 1.0 else "shadow"))
        taken[max(0, y - int(r)):y + int(r) + 1, max(0, x - int(r)):x + int(r) + 1] = True
        if len(out) >= MAX_SPOTS:
            break
    out.sort(key=lambda t: -t.score)
    return out


# --------------------------------------------------------------------------- #
# healing (exemplar patch + gradient-domain correction)
# --------------------------------------------------------------------------- #

def _candidate_offsets(radius: int) -> np.ndarray:
    """Annulus around the blemish: 1.4r .. 4r, ring sampling (deterministic)."""
    offs = []
    step = max(1.0, radius * 0.55)
    r_in = radius * 1.4
    r_out = radius * 4.0
    n = max(8, int(2 * np.pi * r_out / step))
    for ring in (r_in, (r_in + r_out) / 2.0, r_out):
        for k in range(n):
            th = 2 * np.pi * k / n + (0.0 if ring != (r_in + r_out) / 2.0 else np.pi / n)
            offs.append((int(round(np.sin(th) * ring)), int(round(np.cos(th) * ring))))
    return np.unique(np.array(offs, dtype=np.int32), axis=0)


def heal_spots(rgb: np.ndarray, spots: list[Spot], strength: float = 0.85,
               preservation: float = 0.6, radius_boost: int = 0) -> np.ndarray:
    """Transplant clean texture: only the *gradient* of the source is used.

    For each spot a source patch is chosen from an annulus of 1.4-4x the spot
    radius by SSD on the blurred Lab image plus chroma cost, then blended with a
    Poisson-style low-frequency correction so the tone matches the destination.
    """
    if not spots:
        return rgb
    h, w = rgb.shape[:2]
    lab = ops.rgb_to_lab(rgb)
    lab_blur = ops.gaussian_blur(lab, 1.6)

    for spot in spots[:MAX_SPOTS]:
        rad = int(max(2, spot.radius + radius_boost))
        R = int(round(rad * 1.7))
        y, x = int(spot.y), int(spot.x)
        if y - R < 1 or x - R < 1 or y + R + 1 >= h or x + R + 1 >= w:
            continue
        tgt = lab[y - R:y + R + 1, x - R:x + R + 1]
        tgt_b = lab_blur[y - R:y + R + 1, x - R:x + R + 1]

        offs = _candidate_offsets(rad)
        cand = offs + np.array([y, x], dtype=np.int32)
        cand = cand[(cand[:, 0] - R >= 0) & (cand[:, 1] - R >= 0) &
                    (cand[:, 0] + R + 1 < h) & (cand[:, 1] + R + 1 < w)]
        if cand.size == 0:
            continue
        # vectorised SSD on the blurred patch (9x9 sample grid)
        grid = np.linspace(-R, R, 9).round().astype(np.int32)
        gy, gx = np.meshgrid(grid, grid, indexing="ij")
        samples = lab_blur[cand[:, 0][:, None, None] + gy[None], cand[:, 1][:, None, None] + gx[None]]
        target_samples = lab_blur[y + gy, x + gx]
        cost = np.mean((samples - target_samples[None]) ** 2, axis=(1, 2, 3))
        # prefer patches whose mean chroma matches (prevents red-to-green transplants)
        mean_diff = samples.mean(axis=(1, 2)) - target_samples.mean(axis=(0, 1))
        cost = cost + 2.5 * np.sum(mean_diff ** 2, axis=1)
        best = int(np.argmin(cost))
        sy, sx = int(cand[best, 0]), int(cand[best, 1])

        src = lab[sy - R:sy + R + 1, sx - R:sx + R + 1]
        src_b = lab_blur[sy - R:sy + R + 1, sx - R:sx + R + 1]
        corr = ops.gaussian_blur(tgt_b - src_b, max(1.2, rad * 0.9))
        healed = src + corr * preservation + (tgt - tgt_b) * 0.35

        yy = np.arange(2 * R + 1, dtype=np.float32)[:, None] - R
        xx = np.arange(2 * R + 1, dtype=np.float32)[None, :] - R
        d = np.sqrt((yy / R) ** 2 + (xx / R) ** 2)
        alpha = (np.clip(1.0 - d, 0.0, 1.0) ** 1.3) * strength
        lab[y - R:y + R + 1, x - R:x + R + 1] = tgt * (1.0 - alpha[..., None]) + healed * alpha[..., None]

    return ops.lab_to_rgb(lab)


def spot_contrast(rgb: np.ndarray, spots: list[Spot]) -> list[float]:
    """Local L*/a* contrast of each spot against its own ring, in Lab units."""
    if not spots:
        return []
    lab = ops.rgb_to_lab(rgb)
    L, A = lab[..., 0], lab[..., 1]
    h, w = rgb.shape[:2]
    out: list[float] = []
    for spot in spots:
        r = max(2, spot.radius)
        rr = int(max(4, round(r * 2.6)))
        y, x = int(spot.y), int(spot.x)
        y0, y1 = max(0, y - rr), min(h, y + rr + 1)
        x0, x1 = max(0, x - rr), min(w, x + rr + 1)
        if y1 - y0 < 5 or x1 - x0 < 5:
            out.append(0.0)
            continue
        yy = np.arange(y1 - y0, dtype=np.float32)[:, None] - (y - y0)
        xx = np.arange(x1 - x0, dtype=np.float32)[None, :] - (x - x0)
        d = np.sqrt(yy ** 2 + xx ** 2)
        inner = d <= max(1.2, r * 0.7)
        outer = (d > r * 1.6) & (d <= rr)
        if inner.sum() < 4 or outer.sum() < 8:
            out.append(0.0)
            continue
        c_l = float(L[y0:y1, x0:x1][outer].mean() - L[y0:y1, x0:x1][inner].mean())
        c_a = float(A[y0:y1, x0:x1][inner].mean() - A[y0:y1, x0:x1][outer].mean())
        out.append(max(c_l, c_a, 0.0))
    return out


def residual_spots(rgb: np.ndarray, spots: list[Spot]) -> int:
    """How many healed locations still exceed the residual contrast threshold."""
    return sum(1 for c in spot_contrast(rgb, spots) if c > 2.2)


# --------------------------------------------------------------------------- #
# parameters
# --------------------------------------------------------------------------- #

@dataclass
class RetouchParameters:
    smooth_radius_px: float = 5.0
    smooth_amount: float = 0.55
    texture_gain: float = 0.82
    color_even_amount: float = 0.5
    color_even_radius: float = 16.0
    dodge_burn_amount: float = 0.3
    dodge_burn_radius: float = 24.0
    dodge_burn_clip: float = 4.0
    skin_tone_amount: float = 0.35
    blemish_strength: float = 0.9
    blemish_sensitivity: float = 0.6
    eye_amount: float = 0.55
    teeth_amount: float = 0.55
    under_eye_amount: float = 0.45
    lip_amount: float = 0.2
    clarity_amount: float = 0.09
    clarity_radius: float = 18.0
    sharpen_radius: float = 0.8
    sharpen_amount: float = 0.18
    sharpen_threshold: float = 0.008
    exposure_target: float = 0.545
    highlight_rolloff: float = 0.86
    shadow_lift: float = 0.10
    contrast: float = 1.04
    vibrance: float = 0.05
    saturation: float = 1.0
    warmth: float = 0.0
    lut_strength: float = 0.40
    grain: float = 0.0
    vignette: float = 0.0
    skin_protect_de: float = 3.0

    def scaled(self, long_edge: int) -> "RetouchParameters":
        s = long_edge / 6000.0
        p = RetouchParameters(**self.__dict__)
        p.smooth_radius_px = max(2.0, self.smooth_radius_px * max(0.35, s * 1.6))
        p.color_even_radius = max(4.0, self.color_even_radius * max(0.35, s * 1.6))
        p.dodge_burn_radius = max(6.0, self.dodge_burn_radius * max(0.35, s * 1.6))
        p.clarity_radius = max(6.0, self.clarity_radius * max(0.35, s * 1.6))
        p.sharpen_radius = max(0.5, self.sharpen_radius)
        return p


# --------------------------------------------------------------------------- #
# skin stages
# --------------------------------------------------------------------------- #

def skin_smoothing(rgb: np.ndarray, a: SkinAnalysis, p: RetouchParameters) -> np.ndarray:
    """Frequency separation with explicit texture retention.

    out = original - amount*skin*(original - low), then the high band is
    re-injected at `texture_gain` so pores survive at 100% zoom.
    """
    lab = ops.rgb_to_lab(rgb)
    guide = ops.luma(rgb)
    r = max(2, int(round(p.smooth_radius_px)))
    low = ops.guided_filter(guide, lab, r, 1.2e-3)
    high = lab - low

    amount = np.clip(p.smooth_amount * a.skin, 0.0, 0.95)[..., None]
    shaped = low + high * p.texture_gain
    out = lab * (1.0 - amount) + shaped * amount

    rc = max(4, int(round(p.color_even_radius)))
    ab_low = ops.guided_filter(guide, out[..., 1:3], rc, 5e-3)
    even = out[..., 1:3] * (1.0 - p.color_even_amount * a.skin[..., None]) + \
        ab_low * (p.color_even_amount * a.skin[..., None])
    out[..., 1:3] = even

    med = a.skin_lab_median
    da = out[..., 1] - med[1]
    db = out[..., 2] - med[2]
    dist = np.sqrt((da / 11.0) ** 2 + (db / 15.0) ** 2)
    pull = np.clip((dist - 0.85) / 1.5, 0.0, 1.0) * a.skin * p.skin_tone_amount
    out[..., 1] -= da * pull * 0.8
    out[..., 2] -= db * pull * 0.8
    return np.clip(ops.lab_to_rgb(out), 0.0, 1.0)


def dodge_burn(rgb: np.ndarray, a: SkinAnalysis, p: RetouchParameters) -> np.ndarray:
    lab = ops.rgb_to_lab(rgb)
    L = lab[..., 0]
    r = max(6, int(round(p.dodge_burn_radius)))
    base = ops.guided_filter(L, L, r, 1.5e-2)
    delta = np.clip(base - L, -p.dodge_burn_clip, p.dodge_burn_clip)
    lab[..., 0] = L + delta * p.dodge_burn_amount * a.skin
    return ops.lab_to_rgb(lab)


# --------------------------------------------------------------------------- #
# facial details
# --------------------------------------------------------------------------- #

def eyes(rgb: np.ndarray, a: SkinAnalysis, p: RetouchParameters) -> np.ndarray:
    if p.eye_amount <= 0:
        return rgb
    h, w = rgb.shape[:2]
    left, right = a.face.derived_eyes()
    hsv = ops.hue_sat_value(rgb)
    lab = ops.rgb_to_lab(rgb)
    for eye in (left, right):
        cx, cy, ew, eh = eye
        x0 = int(max(0, (cx - ew * 0.62) * w)); x1 = int(min(w, (cx + ew * 0.62) * w))
        y0 = int(max(0, (cy - eh * 0.95) * h)); y1 = int(min(h, (cy + eh * 0.95) * h))
        if x1 - x0 < 8 or y1 - y0 < 6:
            continue
        sub = lab[y0:y1, x0:x1]
        s_hsv = hsv[y0:y1, x0:x1]
        m = _rect(y1 - y0, x1 - x0, (0.5, 0.5, 1.0, 1.0), max(1.0, eh * h * 0.15))
        sclera = ((s_hsv[..., 1] < 0.45) & (s_hsv[..., 2] > 0.40)).astype(np.float32)
        sclera = ops.feather(sclera, max(0.8, eh * h * 0.05)) * m
        if sclera.sum() < 8:
            continue
        target = sub.copy()
        target[..., 0] += 3.2 * p.eye_amount
        target[..., 2] -= 2.4 * p.eye_amount
        de = ops.delta_e_2000(sub, target)
        cap = np.clip(p.skin_protect_de / np.maximum(de, 1e-3), 0.0, 1.0)
        alpha = (sclera * p.eye_amount * 0.9 * cap)[..., None]
        blended = sub * (1.0 - alpha) + target * alpha

        iris = ((s_hsv[..., 1] >= 0.25) & (s_hsv[..., 2] < 0.65) & (s_hsv[..., 2] > 0.08)).astype(np.float32)
        iris = ops.feather(iris, max(0.8, eh * h * 0.06)) * m
        base = ops.gaussian_blur(blended[..., 0], max(0.8, eh * h * 0.06))
        blended[..., 0] += (blended[..., 0] - base) * 0.6 * p.eye_amount * iris
        blended[..., 0] -= 2.2 * p.eye_amount * np.clip((0.30 - blended[..., 0]) / 0.30, 0, 1) * iris
        lab[y0:y1, x0:x1] = blended
    return ops.lab_to_rgb(lab)


def under_eye(rgb: np.ndarray, a: SkinAnalysis, p: RetouchParameters) -> np.ndarray:
    if p.under_eye_amount <= 0:
        return rgb
    h, w = rgb.shape[:2]
    left, right = a.face.derived_eyes()
    lab = ops.rgb_to_lab(rgb)
    m = np.zeros((h, w), dtype=np.float32)
    for eye in (left, right):
        cx, cy, ew, eh = eye
        m = np.maximum(m, _rect(h, w, (cx, cy + eh * 0.95, ew * 0.90, eh * 0.85), max(2.0, eh * h * 0.22)))
    L = lab[..., 0]
    local = ops.gaussian_blur(L, max(2.0, a.face.height * h * 0.025))
    dark = np.clip((local - L) / 10.0, 0.0, 1.0)
    alpha = (m * dark * p.under_eye_amount * 0.8)[..., None]
    target = lab.copy()
    target[..., 0] += 3.4 * p.under_eye_amount
    target[..., 1] -= 0.8 * p.under_eye_amount
    lab = lab * (1.0 - alpha) + target * alpha
    return ops.lab_to_rgb(lab)


def teeth(rgb: np.ndarray, a: SkinAnalysis, p: RetouchParameters) -> np.ndarray:
    if p.teeth_amount <= 0:
        return rgb
    h, w = rgb.shape[:2]
    cx, cy, rw, rh = a.face.derived_lips()
    x0 = int(max(0, (cx - rw * 0.44) * w)); x1 = int(min(w, (cx + rw * 0.44) * w))
    y0 = int(max(0, (cy - rh * 0.30) * h)); y1 = int(min(h, (cy + rh * 0.30) * h))
    if x1 - x0 < 8 or y1 - y0 < 5:
        return rgb
    lab = ops.rgb_to_lab(rgb)
    hsv = ops.hue_sat_value(rgb)
    sub = lab[y0:y1, x0:x1]
    s_hsv = hsv[y0:y1, x0:x1]
    m = _rect(y1 - y0, x1 - x0, (0.5, 0.5, 1.0, 1.0), max(0.8, rh * h * 0.06))
    mask = ((s_hsv[..., 1] < 0.36) & (s_hsv[..., 2] > 0.42)).astype(np.float32)
    mask = ops.feather(mask, max(0.6, rh * h * 0.04)) * m
    if mask.sum() < 6:
        return rgb
    target = sub.copy()
    target[..., 2] -= 4.5 * p.teeth_amount
    target[..., 0] += 2.4 * p.teeth_amount
    de = ops.delta_e_2000(sub, target)
    cap = np.clip(4.0 / np.maximum(de, 1e-3), 0.0, 1.0)
    alpha = (mask * p.teeth_amount * 0.9 * cap)[..., None]
    lab[y0:y1, x0:x1] = sub * (1.0 - alpha) + target * alpha
    return ops.lab_to_rgb(lab)


def lips(rgb: np.ndarray, a: SkinAnalysis, p: RetouchParameters) -> np.ndarray:
    if p.lip_amount <= 0:
        return rgb
    h, w = rgb.shape[:2]
    cx, cy, rw, rh = a.face.derived_lips()
    lab = ops.rgb_to_lab(rgb)
    hsv = ops.hue_sat_value(rgb)
    m = _rect(h, w, (cx, cy, rw * 0.88, rh * 0.82), max(1.5, rh * h * 0.15))
    lip_mask = ((hsv[..., 1] > 0.22) & (hsv[..., 2] > 0.10) &
                ((hsv[..., 0] < 28) | (hsv[..., 0] > 322))).astype(np.float32)
    lip_mask = ops.feather(lip_mask, max(0.8, rh * h * 0.06)) * m
    target = lab.copy()
    target[..., 1] *= 1.0 + 0.15 * p.lip_amount
    target[..., 2] *= 1.0 + 0.15 * p.lip_amount
    alpha = (lip_mask * p.lip_amount)[..., None]
    lab = lab * (1.0 - alpha) + target * alpha
    return ops.lab_to_rgb(lab)
