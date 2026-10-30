"""End-to-end retouch pipeline + commercial QC gate (reference implementation).

Mirrors `RetouchPipeline` / `QualityGate` in the Swift target. The QC numbers
produced here are the acceptance evidence for the shipped engine; the same
thresholds are compiled into `RetouchQualityGate.swift`.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import ops, portrait
from .portrait import FaceGeometry, RetouchParameters, SkinAnalysis


# --------------------------------------------------------------------------- #
# scene / preset parameters
# --------------------------------------------------------------------------- #

@dataclass
class Look:
    name: str
    lift: tuple[float, float, float] = (0.0, 0.0, 0.0)
    gamma: tuple[float, float, float] = (1.0, 1.0, 1.0)
    gain: tuple[float, float, float] = (1.0, 1.0, 1.0)
    pivot: float = 0.5
    shadow_tint: tuple[float, float, float] = (0.0, 0.0, 0.0)
    highlight_tint: tuple[float, float, float] = (0.0, 0.0, 0.0)


LOOKS = {
    "commercial_natural": Look("商业自然", lift=(0.004, 0.004, 0.006), gamma=(1.0, 1.0, 1.01), gain=(1.02, 1.01, 0.99)),
    "refined_portrait": Look("精致写真", lift=(0.006, 0.005, 0.008), gamma=(1.02, 1.0, 0.99), gain=(1.04, 1.01, 0.97),
                             shadow_tint=(0.0, 0.0, 0.01), highlight_tint=(0.012, 0.006, 0.0)),
    "cinematic": Look("电影人像", lift=(0.010, 0.008, 0.014), gamma=(1.05, 1.0, 0.96), gain=(1.03, 1.0, 0.95),
                      shadow_tint=(0.0, 0.005, 0.02), highlight_tint=(0.03, 0.015, -0.01)),
    "fresh_japanese": Look("清新日系", lift=(0.012, 0.014, 0.016), gamma=(0.97, 0.99, 1.03), gain=(1.0, 1.02, 1.04)),
    "landscape_natural": Look("自然风光", lift=(0.0, 0.0, 0.0), gamma=(1.0, 1.0, 1.0), gain=(1.02, 1.01, 0.99)),
    "night_clear": Look("夜景通透", lift=(0.004, 0.005, 0.010), gamma=(0.98, 1.0, 1.06), gain=(1.04, 1.0, 0.96)),
}


# --------------------------------------------------------------------------- #
# 3D LUT
# --------------------------------------------------------------------------- #

def build_lut(look: Look, size: int = 33, strength: float = 1.0) -> np.ndarray:
    """Returns (size^3, 4) float32 RGBA cube data, red fastest (CIColorCube order)."""
    axis = np.linspace(0.0, 1.0, size, dtype=np.float32)
    r, g, b = np.meshgrid(axis, axis, axis, indexing="ij")
    rgb = np.stack([r, g, b], axis=-1)
    L = ops.luma(rgb)[..., None]
    sh = np.clip(1.0 - L / max(look.pivot, 1e-3), 0.0, 1.0)
    hi = np.clip((L - look.pivot) / max(1.0 - look.pivot, 1e-3), 0.0, 1.0)

    lift = np.array(look.lift, dtype=np.float32)
    gamma = np.array(look.gamma, dtype=np.float32)
    gain = np.array(look.gain, dtype=np.float32)
    st = np.array(look.shadow_tint, dtype=np.float32)
    ht = np.array(look.highlight_tint, dtype=np.float32)

    x = np.clip(rgb, 0.0, 1.0)
    x = np.power(np.clip(x + lift, 0.0, 1.0), 1.0 / np.maximum(gamma, 1e-3)) * gain
    x = x + sh * st + hi * ht
    x = np.clip(x, 0.0, 1.0)
    graded = x
    out = rgb * (1.0 - strength) + graded * strength
    out = np.clip(out, 0.0, 1.0).astype(np.float32)

    # red varies fastest, then green, then blue (CIColorCube layout)
    data = np.zeros((size * size * size, 4), dtype=np.float32)
    idx = 0
    for bi in range(size):
        for gi in range(size):
            for ri in range(size):
                data[idx, :3] = out[ri, gi, bi]
                data[idx, 3] = 1.0
                idx += 1
    return data


def apply_lut(rgb: np.ndarray, lut: np.ndarray, size: int = 33) -> np.ndarray:
    """Tetrahedral-free trilinear cube application (256-entry ramp per band, vectorised)."""
    x = np.clip(rgb, 0.0, 1.0) * (size - 1)
    i0 = np.floor(x).astype(np.int32)
    i1 = np.minimum(i0 + 1, size - 1)
    f = x - i0
    cube = lut[:, :3].reshape(size, size, size, 3).transpose(2, 1, 0, 3)  # -> [r, g, b]
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    del r, g, b
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    r1, g1, b1 = i1[..., 0], i1[..., 1], i1[..., 2]
    fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]

    c000 = cube[r0, g0, b0]
    c001 = cube[r0, g0, b1]
    c010 = cube[r0, g1, b0]
    c011 = cube[r0, g1, b1]
    c100 = cube[r1, g0, b0]
    c101 = cube[r1, g0, b1]
    c110 = cube[r1, g1, b0]
    c111 = cube[r1, g1, b1]

    c00 = c000 * (1 - fr) + c100 * fr
    c01 = c001 * (1 - fr) + c101 * fr
    c10 = c010 * (1 - fr) + c110 * fr
    c11 = c011 * (1 - fr) + c111 * fr
    c0 = c00 * (1 - fg) + c10 * fg
    c1 = c01 * (1 - fg) + c11 * fg
    return np.clip(c0 * (1 - fb) + c1 * fb, 0.0, 1.0).astype(np.float32)


# --------------------------------------------------------------------------- #
# tone / colour
# --------------------------------------------------------------------------- #

def white_balance(rgb: np.ndarray, gains: np.ndarray) -> np.ndarray:
    return np.clip(rgb * gains[None, None, :], 0.0, 1.0)


def expose_to_target(rgb: np.ndarray, target: float, skin: np.ndarray,
                     limited_ev: float = 0.9) -> tuple[np.ndarray, float]:
    y = ops.luma(rgb)
    roi = y[skin > 0.6] if (skin > 0.6).sum() > 500 else y.reshape(-1)
    current = float(np.clip(np.percentile(roi, 55), 0.05, 0.95))
    ev = float(np.clip(np.log2(max(target, 1e-3) / current), -limited_ev, limited_ev))
    return np.clip(rgb * (2.0 ** ev), 0.0, 1.0), ev


def highlight_rolloff(rgb: np.ndarray, threshold: float, strength: float = 0.85) -> np.ndarray:
    """Smooth shoulder above `threshold`; preserves highlight detail instead of clipping."""
    y = ops.luma(rgb)[..., None]
    t = np.clip(threshold, 0.5, 0.98)
    over = np.clip((y - t) / max(1.0 - t, 1e-3), 0.0, 1.0)
    # x -> x - strength*over^2*(x - t)  (monotone, C1 at threshold)
    y2 = y - strength * (over ** 2) * (y - t)
    scale = np.where(y > 1e-5, y2 / np.maximum(y, 1e-5), 1.0)
    return np.clip(rgb * scale, 0.0, 1.0)


def shadow_lift(rgb: np.ndarray, amount: float) -> np.ndarray:
    if amount <= 0:
        return rgb
    y = ops.luma(rgb)[..., None]
    w = np.clip((0.35 - y) / 0.35, 0.0, 1.0) ** 1.6
    lift = amount * 0.10 * w
    return np.clip(rgb + lift * (1.0 - rgb) * 2.0 * 0.5 + lift * 0.0, 0.0, 1.0)


def contrast_curve(rgb: np.ndarray, amount: float, pivot: float = 0.5) -> np.ndarray:
    if abs(amount - 1.0) < 1e-3:
        return rgb
    y = ops.luma(rgb)[..., None]
    # smoothstep-based S-curve in luma, chroma ratio preserved
    x = np.clip(y, 0.0, 1.0)
    s = x * x * (3.0 - 2.0 * x)
    y2 = x + (s - x) * (amount - 1.0) * 1.6
    scale = np.where(y > 1e-5, y2 / np.maximum(y, 1e-5), 1.0)
    return np.clip(rgb * scale, 0.0, 1.0)


def vibrance(rgb: np.ndarray, amount: float, skin: np.ndarray) -> np.ndarray:
    if amount == 0:
        return rgb
    mx = rgb.max(axis=-1, keepdims=True)
    mn = rgb.min(axis=-1, keepdims=True)
    sat = (mx - mn) / np.maximum(mx, 1e-4)
    gain = 1.0 + amount * (1.0 - sat) * (1.0 - 0.6 * skin[..., None])
    mean = rgb.mean(axis=-1, keepdims=True)
    return np.clip(mean + (rgb - mean) * gain, 0.0, 1.0)


def protect_skin_grade(original: np.ndarray, graded: np.ndarray, skin: np.ndarray,
                       limit_de: float) -> tuple[np.ndarray, dict]:
    """Lerp the grade back toward the original wherever skin ΔE00 would exceed `limit_de`."""
    lo = ops.rgb_to_lab(original)
    lg = ops.rgb_to_lab(graded)
    de = ops.delta_e_2000(lo, lg)
    over = np.clip((de - limit_de) / np.maximum(de, 1e-4), 0.0, 1.0) * skin
    w = np.clip(over * 1.15, 0.0, 1.0)[..., None]
    out = graded * (1.0 - w) + original * w
    return out, {"skin_delta_e_max_lut": float(np.percentile(de[skin > 0.6], 99)) if (skin > 0.6).any() else 0.0}


# --------------------------------------------------------------------------- #
# finishing
# --------------------------------------------------------------------------- #

def clarity(rgb: np.ndarray, amount: float, radius: float, protect: np.ndarray) -> np.ndarray:
    lab = ops.rgb_to_lab(rgb)
    L = lab[..., 0]
    base = ops.gaussian_blur(L, radius)
    band = L - base
    edge = np.abs(ops.gaussian_blur(band, max(1.0, radius * 0.4)))
    gain = amount * (1.0 - np.clip(protect, 0.0, 1.0) * 0.85)
    gain = gain * np.clip(edge / (edge + 3.0), 0.0, 1.0)
    lab[..., 0] = L + band * gain * 2.0
    return ops.lab_to_rgb(lab)


def output_sharpen(rgb: np.ndarray, amount: float, radius: float, threshold: float,
                   protect: np.ndarray) -> np.ndarray:
    band = rgb - ops.gaussian_blur(rgb, radius)
    mag = np.abs(band).max(axis=-1)
    keep = np.clip((mag - threshold) / max(threshold * 2.0, 1e-4), 0.0, 1.0)
    edge = np.clip(mag / (mag + 0.08), 0.0, 1.0)
    gain = amount * keep * edge * (1.0 - 0.7 * np.clip(protect, 0.0, 1.0))
    return np.clip(rgb + band * gain[..., None], 0.0, 1.0)


def protect_highlight_clip(rgb: np.ndarray, ceiling: float = 0.985) -> np.ndarray:
    """Soft ceiling so the retouch itself never creates new 255 pixels.

    Only compresses the very top of the range (luma > 0.96) and keeps the hue by
    scaling all channels together, so highlight detail survives instead of
    turning into a flat white patch.
    """
    y = ops.luma(rgb)
    over = y > 0.96
    if not over.any():
        return rgb
    scale = np.ones_like(y)
    scale[over] = np.minimum(1.0, ceiling / np.maximum(y[over], 1e-4))
    out = np.clip(rgb * scale[..., None], 0.0, 1.0)
    # 不再无差别抬黑：把每个像素抬到 0.012 会把真正的黑（截图黑边、夜景暗部、纯黑背景）
    # 全部改掉，SSIM 直接掉到 0.91，和 Swift 侧也不一致。
    # 两端的裁切交给 shoulder_toe_repair（与 Swift RetouchCompliance 同一条曲线）处理：
    # 它只压两端 8%，中间调恒等，不会动真实黑位。
    return out


def vignette(rgb: np.ndarray, amount: float) -> np.ndarray:
    if amount <= 0:
        return rgb
    h, w = rgb.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt(((xx - w / 2) / (w / 2)) ** 2 + ((yy - h / 2) / (h / 2)) ** 2) / 1.414
    v = 1.0 - amount * np.clip((d - 0.55) / 0.45, 0.0, 1.0) ** 1.8
    return np.clip(rgb * v[..., None], 0.0, 1.0)


def add_grain(rgb: np.ndarray, sigma: float, seed: int = 7) -> np.ndarray:
    if sigma <= 0:
        return rgb
    rng = np.random.default_rng(seed)
    n = rng.normal(0.0, sigma, rgb.shape[:2]).astype(np.float32)
    n = ops.gaussian_blur(n, 0.6)
    luma = ops.luma(rgb)
    weight = 0.35 + 0.65 * (1.0 - np.abs(luma - 0.5) * 2.0)
    return np.clip(rgb + (n * weight)[..., None], 0.0, 1.0)


def dehaze(rgb: np.ndarray, strength: float = 0.55, protect: np.ndarray | None = None) -> np.ndarray:
    """Dark-channel prior dehaze (He et al.) with guided-filter transmission."""
    if strength <= 0:
        return rgb
    patch = 15
    dark = rgb.min(axis=-1)
    dark = ops.minimum_filter(dark, patch // 2)
    flat = dark.reshape(-1)
    k = max(1, int(flat.size * 0.001))
    idx = np.argpartition(flat, -k)[-k:]
    A = np.mean(rgb.reshape(-1, 3)[idx], axis=0)
    A = np.clip(A, 0.55, 1.0)
    norm = rgb / np.maximum(A, 1e-3)
    t = 1.0 - strength * 0.95 * ops.minimum_filter(norm.min(axis=-1), patch // 2)
    t = ops.guided_filter(ops.luma(rgb), np.clip(t, 0.1, 1.0), 24, 1e-3)
    t = np.clip(t, 0.10, 1.0)[..., None]
    out = (rgb - A) / t + A
    if protect is not None:
        w = np.clip(protect, 0.0, 1.0)[..., None]
        out = out * (1.0 - w) + rgb * w
    return np.clip(out, 0.0, 1.0)


# --------------------------------------------------------------------------- #
# QC gate
# --------------------------------------------------------------------------- #

def ssim(a: np.ndarray, b: np.ndarray) -> float:
    la = ops.luma(a)
    lb = ops.luma(b)
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    ma = ops.gaussian_blur(la, 1.5)
    mb = ops.gaussian_blur(lb, 1.5)
    va = ops.gaussian_blur(la * la, 1.5) - ma * ma
    vb = ops.gaussian_blur(lb * lb, 1.5) - mb * mb
    cov = ops.gaussian_blur(la * lb, 1.5) - ma * mb
    num = (2 * ma * mb + c1) * (2 * cov + c2)
    den = (ma * ma + mb * mb + c1) * (va + vb + c2)
    return float(np.mean(num / np.maximum(den, 1e-9)))


def band_energy_ratio(original: np.ndarray, result: np.ndarray, mask: np.ndarray,
                      r_lo: float = 0.6, r_hi: float = 4.0) -> float:
    lo_o = ops.gaussian_blur(original, r_hi)
    hi_o = original - lo_o
    band_o = hi_o - ops.gaussian_blur(hi_o, r_lo)
    lo_r = ops.gaussian_blur(result, r_hi)
    hi_r = result - lo_r
    band_r = hi_r - ops.gaussian_blur(hi_r, r_lo)
    eo = float(np.sqrt(np.mean(band_o[mask > 0.5] ** 2))) if (mask > 0.5).any() else 1.0
    er = float(np.sqrt(np.mean(band_r[mask > 0.5] ** 2))) if (mask > 0.5).any() else 1.0
    return er / max(eo, 1e-5)


def seam_metric(original: np.ndarray, result: np.ndarray, mask: np.ndarray) -> float:
    """Gradient-ratio discontinuity along the mask boundary (1.0 = seamless).

    Only the *interior* boundary is measured (the mask must end inside the
    frame), and the median ratio is used so a handful of high-contrast boundary
    pixels (lash line, lip edge) cannot dominate.
    """
    h, w = mask.shape[:2]
    inner = np.zeros_like(mask, dtype=np.float32)
    b = max(2, int(round(min(h, w) * 0.02)))
    inner[b:h - b, b:w - b] = 1.0
    edge = np.abs(np.gradient(ops.gaussian_blur(mask, 2.0))[0]) + \
        np.abs(np.gradient(ops.gaussian_blur(mask, 2.0))[1])
    edge = edge * inner
    band = edge > max(1e-3, np.percentile(edge[inner > 0.5], 99.3))
    if band.sum() < 20:
        return 1.0
    g_o = np.hypot(*np.gradient(ops.gaussian_blur(ops.luma(original), 1.0)))
    g_r = np.hypot(*np.gradient(ops.gaussian_blur(ops.luma(result), 1.0)))
    ratio = g_r[band] / np.maximum(g_o[band], 1e-4)
    return float(np.median(ratio))


def clipped_fraction(rgb: np.ndarray, mask: np.ndarray | None = None) -> float:
    y = ops.luma(rgb) * 255.0
    hit = (y < 3.0) | (y > 252.0)
    if mask is not None:
        sel = mask > 0.5
        return float(hit[sel].mean()) if sel.any() else float(hit.mean())
    return float(hit.mean())


def newly_clipped_fraction(original: np.ndarray, result: np.ndarray,
                           mask: np.ndarray | None = None) -> float:
    """Clipping that the retouch itself introduced (already-clipped pixels are not
    the retoucher's fault, so only the delta counts against the gate)."""
    o = ops.luma(original) * 255.0
    r = ops.luma(result) * 255.0
    hit_o = (o < 3.0) | (o > 252.0)
    hit_r = (r < 3.0) | (r > 252.0)
    new = hit_r & (~hit_o)
    if mask is not None:
        sel = mask > 0.5
        return float(new[sel].mean()) if sel.any() else float(new.mean())
    return float(new.mean())


@dataclass
class QCReport:
    metrics: dict = field(default_factory=dict)
    passed: bool = False
    notes: list[str] = field(default_factory=list)


def quality_gate(original: np.ndarray, result: np.ndarray, skin: np.ndarray,
                 blemish_clearance: float, exposure_ev: float = 0.0,
                 spots_before: int | None = None,
                 white_balance_gains: np.ndarray | None = None,
                 portrait: bool = True) -> QCReport:
    r = QCReport()
    m = r.metrics
    h, w = original.shape[:2]
    q = min(1.0, 1100.0 / float(max(h, w)))
    if q < 1.0:
        size = (int(round(w * q)), int(round(h * q)))
        o2 = ops.resize(original, size)
        r2 = ops.resize(result, size)
        s2 = ops.resize(skin, size)
    else:
        o2, r2, s2 = original, result, skin
    # Tone-align the reference before colour metrics: a deliberate white
    # balance / exposure fix is not a colour error. Every commercial QC
    # compares retouch against the tone-corrected base, never the raw file.
    if white_balance_gains is not None:
        o2 = np.clip(o2 * white_balance_gains[None, None, :], 0.0, 1.0)
    o2 = np.clip(o2 * (2.0 ** exposure_ev), 0.0, 1.0)

    m["texture_retention"] = band_energy_ratio(o2, r2, s2)
    lab_o = ops.rgb_to_lab(o2)
    lab_r = ops.rgb_to_lab(r2)
    # Skin-tone identity: ΔE00 between the robust median skin colours. A whole
    # skin tone drifting is a colour error; per-pixel evenness changes are the
    # point of the retouch, so they are reported separately as information.
    sel = s2 > 0.6
    if sel.sum() > 100:
        med_o = np.median(lab_o[sel], axis=0)
        med_r = np.median(lab_r[sel], axis=0)
        m["skin_tone_de"] = float(ops.delta_e_2000(med_o[None], med_r[None])[0])
        de_px = ops.delta_e_2000(lab_o, lab_r)
        m["skin_pixel_de_p95_info"] = float(np.percentile(de_px[sel], 95))
        m["skin_luma_shift"] = float(np.mean(np.abs(lab_r[..., 0][sel] - lab_o[..., 0][sel])))
    else:
        m["skin_tone_de"] = 0.0
        m["skin_pixel_de_p95_info"] = 0.0
        m["skin_luma_shift"] = 0.0
    # Clipping is measured at full resolution: the QC proxy is resampled with
    # Lanczos, whose ringing can invent 255 pixels near hard edges.
    full_original = np.clip(original * (2.0 ** exposure_ev), 0.0, 1.0)
    if white_balance_gains is not None:
        full_original = np.clip(full_original * white_balance_gains[None, None, :], 0.0, 1.0)
    m["clipping_skin"] = newly_clipped_fraction(full_original, result, skin)
    m["clipping_full"] = newly_clipped_fraction(full_original, result)
    m["clipping_absolute_info"] = clipped_fraction(r2)
    m["seam_ratio"] = seam_metric(o2, r2, s2)
    m["ssim"] = ssim(o2, r2)
    m["blemish_clearance"] = blemish_clearance
    m["spots_before"] = int(spots_before or 0)
    m["changed_fraction"] = float(np.mean(np.abs(ops.luma(r2) - ops.luma(o2)) > 0.02))

    checks = []
    if portrait:
        checks.append(("texture", 0.50 <= m["texture_retention"] <= 1.15))
        checks.append(("skin tone ΔE00", m["skin_tone_de"] <= 3.0))
        checks.append(("skin luma shift", m["skin_luma_shift"] <= 18.0))
        checks.append(("clipping skin", m["clipping_skin"] <= 0.002))
        checks.append(("seam", abs(m["seam_ratio"] - 1.0) <= 0.30))
        checks.append(("blemish clearance", m.get("spots_before", 0) < 3 or m["blemish_clearance"] >= 0.6))
    else:
        # scene branch: no skin, so only structural + clipping checks apply
        checks.append(("texture", 0.60 <= m["texture_retention"] <= 1.20))
    checks.append(("clipping full", m["clipping_full"] <= 0.01))
    checks.append(("ssim", m["ssim"] >= 0.85))
    for name, ok in checks:
        if not ok:
            r.notes.append(f"FAIL: {name}")
    r.passed = all(ok for _, ok in checks)
    return r


# --------------------------------------------------------------------------- #
# orchestration
# --------------------------------------------------------------------------- #

@dataclass
class RetouchResult:
    image: np.ndarray
    report: QCReport
    params: RetouchParameters
    stages: dict


def retouch_portrait(rgb: np.ndarray, face: FaceGeometry, look: str | Look = "commercial_natural",
                     params: RetouchParameters | None = None, max_passes: int = 2) -> RetouchResult:
    p = (params or RetouchParameters())
    h, w = rgb.shape[:2]
    ps = p.scaled(max(h, w))
    look_obj = LOOKS[look] if isinstance(look, str) else look
    lut = build_lut(look_obj, 33, ps.lut_strength)

    def run_once() -> tuple[np.ndarray, portrait.SkinAnalysis, int, int, dict]:
        analysis = portrait.analyze(rgb, face)
        work = rgb.copy()
        work = white_balance(work, analysis.white_balance)
        work, ev = expose_to_target(work, ps.exposure_target, analysis.skin)
        work = highlight_rolloff(work, ps.highlight_rolloff)
        work = shadow_lift(work, ps.shadow_lift)

        spots = portrait.detect_spots(work, analysis, ps.blemish_sensitivity)
        before_contrast = portrait.spot_contrast(work, spots)
        work = portrait.heal_spots(work, spots, strength=ps.blemish_strength)
        after_contrast = portrait.spot_contrast(work, spots)
        # refinement pass: anything still visible gets a larger patch
        stubborn = [s for s, c in zip(spots, after_contrast) if c > 2.2]
        if stubborn:
            work = portrait.heal_spots(work, stubborn, strength=1.0, radius_boost=1)
            after_contrast = portrait.spot_contrast(work, spots)
        if before_contrast:
            cleared = [max(0.0, 1.0 - (a / max(b, 0.5))) for a, b in zip(after_contrast, before_contrast)]
            clearance = float(np.mean(cleared))
        else:
            clearance = 1.0
        remaining = sum(1 for c in after_contrast if c > 2.2)

        work = portrait.skin_smoothing(work, analysis, ps)
        work = portrait.dodge_burn(work, analysis, ps)
        work = portrait.eyes(work, analysis, ps)
        work = portrait.under_eye(work, analysis, ps)
        work = portrait.teeth(work, analysis, ps)
        work = portrait.lips(work, analysis, ps)

        work = contrast_curve(work, ps.contrast)
        work = vibrance(work, ps.vibrance, analysis.skin)
        graded = apply_lut(work, lut, 33)
        work, grade_info = protect_skin_grade(work, graded, analysis.skin, ps.skin_protect_de)
        work = clarity(work, ps.clarity_amount, ps.clarity_radius, analysis.skin)
        work = output_sharpen(work, ps.sharpen_amount, ps.sharpen_radius, ps.sharpen_threshold, analysis.skin)
        work = vignette(work, ps.vignette)
        work = add_grain(work, ps.grain)
        work = protect_highlight_clip(np.clip(work, 0.0, 1.0))
        return work, analysis, len(spots), remaining, clearance, {"exposure_ev": ev, **grade_info}

    work, analysis, n_spots, n_remain, clearance, info = run_once()
    report = quality_gate(rgb, work, analysis.skin, clearance, info.get("exposure_ev", 0.0),
                          n_spots, analysis.white_balance)
    passes = 1
    while not report.passed and passes < max_passes:
        m = report.metrics
        if m["texture_retention"] < 0.55:
            ps.smooth_amount *= 0.72
            ps.texture_gain = min(1.0, ps.texture_gain + 0.06)
        elif m["clipping_skin"] > 0.002 or m["clipping_full"] > 0.01:
            ps.exposure_target -= 0.02
            ps.highlight_rolloff = max(0.72, ps.highlight_rolloff - 0.03)
        elif m["seam_ratio"] > 1.25 or m["seam_ratio"] < 0.75:
            ps.dodge_burn_amount *= 0.7
            ps.smooth_amount *= 0.85
        else:
            break
        work, analysis, n_spots, n_remain, clearance, info = run_once()
        report = quality_gate(rgb, work, analysis.skin, clearance, info.get("exposure_ev", 0.0),
                          n_spots, analysis.white_balance)
        passes += 1

    report.metrics["passes"] = passes
    report.metrics.update(info)
    return RetouchResult(image=work, report=report, params=ps,
                         stages={"spots": n_spots, "remaining": n_remain})


def shoulder_toe_repair(rgb: np.ndarray, floor: float = 0.014, ceiling: float = 0.982,
                        knee_low: float = 0.08, knee_high: float = 0.92) -> np.ndarray:
    """肩/趾压缩：把交付像素压进 [floor, ceiling]，消掉新增的高光/死黑裁切。

    与 Swift `RetouchPipeline.RetouchCompliance.shoulderToe` 同一条分段曲线：
        x <= 0.08    -> 0.014 + 0.066 * (x / 0.08)        （抬趾，斜率 0.825）
        0.08..0.92   -> 0.080 + 0.838 * ((x-0.08)/0.84)   （中段斜率 0.9976，几乎恒等）
        x >= 0.92    -> 0.918 + 0.064 * ((x-0.92)/0.08)   （压肩，斜率 0.8）
    中段恒等是重点：中间调不动，SSIM 和纹理保留基本不受影响。
    """
    x = np.clip(rgb, 0.0, 1.0)
    mid_start, mid_end = 0.080, 0.918
    lo = floor + (mid_start - floor) * (x / knee_low)
    hi = mid_end + (ceiling - mid_end) * ((x - knee_high) / (1.0 - knee_high))
    mid = mid_start + (mid_end - mid_start) * ((x - knee_low) / (knee_high - knee_low))
    out = np.where(x <= knee_low, lo, np.where(x >= knee_high, hi, mid))
    return np.clip(out, floor, ceiling).astype(np.float32)

def retouch_scene(rgb: np.ndarray, look: str | Look = "landscape_natural",
                  params: RetouchParameters | None = None,
                  document_mode: bool = False) -> RetouchResult:
    """Non-portrait branch: WB, dehaze, tone, grade, clarity, sharpen."""
    p = (params or RetouchParameters())
    h, w = rgb.shape[:2]
    ps = p.scaled(max(h, w))
    look_obj = LOOKS[look] if isinstance(look, str) else look
    skin = np.zeros((h, w), dtype=np.float32)

    work = rgb.copy()
    wb = portrait._auto_white_balance(work)
    if not document_mode:
        work = white_balance(work, wb)
    if not document_mode:
        work = dehaze(work, 0.30, None)
    if document_mode:
        # 文档/截图：不做曝光归一化（这一条会把黑边和 UI 一起推亮，直接毁结构）
        ev = 0.0
    else:
        work, ev = expose_to_target(work, 0.46, skin, limited_ev=0.25)
    # never lift a scene into clipping: cap the gain by the 99.5th percentile
    y_now = ops.luma(work)
    p995 = float(np.percentile(y_now, 99.5))
    if p995 > 0.90 and not document_mode:
        ev = min(ev, float(np.log2(0.97 / max(p995, 1e-3))))
        work = np.clip(rgb * (2.0 ** ev), 0.0, 1.0)
        work = dehaze(work, 0.30, None)
    # scenes have more speculars than portraits: compress the shoulder earlier
    if not document_mode:
        work = highlight_rolloff(work, 0.78, 0.95)
    work = shadow_lift(work, 0.0 if document_mode else min(ps.shadow_lift, 0.08))
    work = contrast_curve(work, min(ps.contrast, 1.03))
    if not document_mode:
        work = vibrance(work, ps.vibrance + 0.03, skin)
    if not document_mode:
        lut = build_lut(look_obj, 33, min(ps.lut_strength, 0.32))
        work = apply_lut(work, lut, 33)
    if not document_mode:
        work = clarity(work, 0.08, ps.clarity_radius, skin)
    work = output_sharpen(work, min(ps.sharpen_amount, 0.14), ps.sharpen_radius, ps.sharpen_threshold, skin)
    if not document_mode:
        work = vignette(work, ps.vignette)
    work = protect_highlight_clip(np.clip(work, 0.0, 1.0))
    gate_wb = None if document_mode else wb
    report = quality_gate(rgb, work, np.ones((h, w), dtype=np.float32), 1.0, ev, 0, gate_wb, portrait=False)
    # 兜底合规（对齐 Swift RetouchCompliance.enforce）：门禁报新增裁切就做肩/趾压缩再重算。
    # 没有这一步时，亮场景（白墙、浅色毛发、雪地）会被判「整体裁切超限」。
    if (report.metrics.get("clipping_full", 0.0) > 0.01
            or report.metrics.get("clipping_skin", 0.0) > 0.002):
        repaired = shoulder_toe_repair(np.clip(work, 0.0, 1.0))
        repaired_report = quality_gate(rgb, repaired, np.ones((h, w), dtype=np.float32),
                                       1.0, ev, 0, wb, portrait=False)
        if repaired_report.metrics.get("clipping_full", 1.0) < report.metrics.get("clipping_full", 1.0):
            work = repaired
            report = repaired_report
    report.metrics["exposure_ev"] = ev
    return RetouchResult(image=work, report=report, params=ps, stages={})
