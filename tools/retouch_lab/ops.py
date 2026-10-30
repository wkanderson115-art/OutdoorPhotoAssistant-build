"""Low-level image operations used by the Retouch Lab reference pipeline.

Everything here is dependency-light (numpy + Pillow only) and mirrors the
Core Image / Accelerate primitives used by the shipped Swift engine:

* separable box blur via cumulative sums (O(N) per pass, 4 passes ~ Gaussian)
* guided filter (He et al. 2010) used for mask refinement and edge-aware splits
* sRGB <-> linear <-> CIELab, CIEDE2000
* morphology, DoG/LoG, unsharp masking, feathering

The functions are written to operate on float32 arrays in [0, 1] with shape
(H, W, 3) or on 2-D float32 masks in [0, 1].
"""

from __future__ import annotations

import numpy as np

EPS = 1e-6


# --------------------------------------------------------------------------- #
# basic conversion
# --------------------------------------------------------------------------- #

def to_float(img: np.ndarray) -> np.ndarray:
    if img.dtype == np.uint8:
        return img.astype(np.float32) / 255.0
    return np.clip(img.astype(np.float32), 0.0, 1.0)


def to_uint8(img: np.ndarray) -> np.ndarray:
    return np.clip(np.rint(img * 255.0), 0, 255).astype(np.uint8)


def luma(rgb: np.ndarray) -> np.ndarray:
    """Rec.709 luma on gamma-encoded sRGB (matches Core Image behaviour)."""
    return (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]).astype(np.float32)


_LUT_N = 4096
_LUT_X = np.linspace(0.0, 1.0, _LUT_N, dtype=np.float32)
_LIN_LUT = np.where(_LUT_X <= 0.04045, _LUT_X / 12.92,
                    ((_LUT_X + 0.055) / 1.055) ** 2.4).astype(np.float32)
_SRGB_LUT = np.where(_LUT_X <= 0.0031308, _LUT_X * 12.92,
                     1.055 * np.power(_LUT_X, 1 / 2.4) - 0.055).astype(np.float32)


def _apply_lut(x: np.ndarray, lut: np.ndarray) -> np.ndarray:
    idx = np.clip(x, 0.0, 1.0) * (_LUT_N - 1)
    i0 = idx.astype(np.int32)
    i1 = np.minimum(i0 + 1, _LUT_N - 1)
    f = (idx - i0).astype(np.float32)
    return lut[i0] * (1.0 - f) + lut[i1] * f


def srgb_to_linear(x: np.ndarray) -> np.ndarray:
    return _apply_lut(x, _LIN_LUT)


def linear_to_srgb(x: np.ndarray) -> np.ndarray:
    return _apply_lut(np.maximum(x, 0.0), _SRGB_LUT)


# D65 reference white
_WHITE = np.array([0.95047, 1.00000, 1.08883], dtype=np.float32)
_M_RGB2XYZ = np.array([
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041],
], dtype=np.float32)
_M_XYZ2RGB = np.linalg.inv(_M_RGB2XYZ).astype(np.float32)


def rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    lin = srgb_to_linear(np.clip(rgb, 0.0, 1.0))
    xyz = lin @ _M_RGB2XYZ.T
    xyz = xyz / _WHITE
    eps = 216.0 / 24389.0
    kappa = 24389.0 / 27.0
    f = np.where(xyz > eps, np.cbrt(np.maximum(xyz, 0.0)), (kappa * xyz + 16.0) / 116.0)
    L = 116.0 * f[..., 1] - 16.0
    a = 500.0 * (f[..., 0] - f[..., 1])
    b = 200.0 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], axis=-1).astype(np.float32)


def lab_to_rgb(lab: np.ndarray) -> np.ndarray:
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = (L + 16.0) / 116.0
    fx = fy + a / 500.0
    fz = fy - b / 200.0
    eps = 216.0 / 24389.0
    kappa = 24389.0 / 27.0
    xr = np.where(fx ** 3 > eps, fx ** 3, (116.0 * fx - 16.0) / kappa)
    yr = np.where(L > kappa * eps, ((L + 16.0) / 116.0) ** 3, L / kappa)
    zr = np.where(fz ** 3 > eps, fz ** 3, (116.0 * fz - 16.0) / kappa)
    xyz = np.stack([xr, yr, zr], axis=-1) * _WHITE
    lin = xyz @ _M_XYZ2RGB.T
    return np.clip(linear_to_srgb(np.maximum(lin, 0.0)), 0.0, 1.0).astype(np.float32)


def rgb_to_ycbcr(rgb: np.ndarray) -> np.ndarray:
    y = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    cb = -0.168736 * rgb[..., 0] - 0.331264 * rgb[..., 1] + 0.5 * rgb[..., 2] + 0.5
    cr = 0.5 * rgb[..., 0] - 0.418688 * rgb[..., 1] - 0.081312 * rgb[..., 2] + 0.5
    return np.stack([y, cb, cr], axis=-1).astype(np.float32)


def ycbcr_to_rgb(ycc: np.ndarray) -> np.ndarray:
    y, cb, cr = ycc[..., 0], ycc[..., 1] - 0.5, ycc[..., 2] - 0.5
    r = y + 1.402 * cr
    g = y - 0.344136 * cb - 0.714136 * cr
    b = y + 1.772 * cb
    return np.clip(np.stack([r, g, b], axis=-1), 0.0, 1.0).astype(np.float32)


def delta_e_2000(lab1: np.ndarray, lab2: np.ndarray) -> np.ndarray:
    """CIEDE2000, vectorised. Inputs (..., 3) Lab arrays."""
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1 = np.hypot(a1, b1) + EPS
    C2 = np.hypot(a2, b2) + EPS
    Cbar = (C1 + C2) / 2.0
    G = 0.5 * (1.0 - np.sqrt(Cbar ** 7 / (Cbar ** 7 + 25.0 ** 7)))
    a1p = (1.0 + G) * a1
    a2p = (1.0 + G) * a2
    C1p = np.hypot(a1p, b1) + EPS
    C2p = np.hypot(a2p, b2) + EPS
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360.0
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360.0
    dLp = L2 - L1
    dCp = C2p - C1p
    dhp = np.where(np.abs(h2p - h1p) <= 180.0, h2p - h1p,
                   np.where(h2p - h1p > 180.0, h2p - h1p - 360.0, h2p - h1p + 360.0))
    dHp = 2.0 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp / 2.0))
    Lbarp = (L1 + L2) / 2.0
    Cbarp = (C1p + C2p) / 2.0
    hsum = h1p + h2p
    hbarp = np.where(np.abs(h1p - h2p) <= 180.0, hsum / 2.0,
                     np.where(hsum < 360.0, (hsum + 360.0) / 2.0, (hsum - 360.0) / 2.0))
    T = (1.0 - 0.17 * np.cos(np.radians(hbarp - 30.0))
         + 0.24 * np.cos(np.radians(2.0 * hbarp))
         + 0.32 * np.cos(np.radians(3.0 * hbarp + 6.0))
         - 0.20 * np.cos(np.radians(4.0 * hbarp - 63.0)))
    dtheta = 30.0 * np.exp(-(((hbarp - 275.0) / 25.0) ** 2))
    Rc = 2.0 * np.sqrt(Cbarp ** 7 / (Cbarp ** 7 + 25.0 ** 7))
    Sl = 1.0 + (0.015 * (Lbarp - 50.0) ** 2) / np.sqrt(20.0 + (Lbarp - 50.0) ** 2)
    Sc = 1.0 + 0.045 * Cbarp
    Sh = 1.0 + 0.015 * Cbarp * T
    Rt = -np.sin(np.radians(2.0 * dtheta)) * Rc
    term_l = dLp / Sl
    term_c = dCp / Sc
    term_h = dHp / Sh
    return np.sqrt(np.maximum(term_l ** 2 + term_c ** 2 + term_h ** 2 + Rt * term_c * term_h, 0.0)).astype(np.float32)


# --------------------------------------------------------------------------- #
# blur / filter primitives
# --------------------------------------------------------------------------- #

def _box_blur_1d(a: np.ndarray, r: int, axis: int) -> np.ndarray:
    if r <= 0:
        return a
    a = np.moveaxis(a, axis, 0)
    n = a.shape[0]
    c = np.cumsum(a, axis=0, dtype=np.float32)
    zero = np.zeros_like(c[:1])
    c0 = np.concatenate([zero, c], axis=0)
    hi = c[np.clip(np.arange(n) + r, 0, n - 1)]
    lo = c0[np.maximum(np.arange(n) - r, 0)]
    out = (hi - lo) / np.float32(2 * r + 1)
    return np.moveaxis(out.astype(np.float32), 0, axis)


def box_blur(a: np.ndarray, r: int, passes: int = 1) -> np.ndarray:
    out = a
    for _ in range(max(1, passes)):
        out = _box_blur_1d(_box_blur_1d(out, r, 0), r, 1)
    return out


def gaussian_blur(a: np.ndarray, sigma: float, passes: int = 2) -> np.ndarray:
    """Gaussian approximation by repeated box filters (central limit theorem)."""
    if sigma <= 0.3:
        return a.astype(np.float32)
    # sigma^2 = passes * ((2r+1)^2 - 1) / 12
    target = sigma * sigma * 12.0 / passes + 1.0
    r = int(max(1, round((np.sqrt(target) - 1.0) / 2.0)))
    return box_blur(a.astype(np.float32), r, passes)


def guided_filter(guide: np.ndarray, src: np.ndarray, radius: int, eps: float) -> np.ndarray:
    """Grey-guide guided filter (He et al.). guide: (H, W) in [0,1]; src: (H,W) or (H,W,C)."""
    g = guide.astype(np.float32)
    if src.ndim == 3:
        return np.stack([guided_filter(g, src[..., i], radius, eps) for i in range(src.shape[2])], axis=-1)
    p = src.astype(np.float32)
    mean_g = box_blur(g, radius)
    mean_p = box_blur(p, radius)
    corr_gp = box_blur(g * p, radius)
    corr_gg = box_blur(g * g, radius)
    var_g = corr_gg - mean_g * mean_g
    cov_gp = corr_gp - mean_g * mean_p
    a = cov_gp / (var_g + eps)
    b = mean_p - a * mean_g
    return box_blur(a, radius) * g + box_blur(b, radius)


def bilateral_approx(a: np.ndarray, radius: int, sigma_range: float, levels: int = 4) -> np.ndarray:
    """Edge-preserving smoothing via the bilateral grid / guided-filter mix.

    A fast approximation used only where a true joint bilateral is not required:
    blend the guided filter result with a plain blur according to local variance.
    """
    g = luma(a) if a.ndim == 3 else a
    base = guided_filter(g, a, radius, max(1e-4, sigma_range ** 2))
    plain = gaussian_blur(a, radius)
    var = np.abs(box_blur(g * g, radius) - box_blur(g, radius) ** 2)
    w = np.clip(var / (var + sigma_range ** 2), 0.0, 1.0)
    if a.ndim == 3:
        w = w[..., None]
    return (base * w + plain * (1.0 - w)).astype(np.float32)


def minimum_filter(a: np.ndarray, r: int) -> np.ndarray:
    if r <= 0:
        return a
    out = a
    for axis in (0, 1):
        out = _min_filter_1d(out, r, axis)
    return out


def _min_filter_1d(a: np.ndarray, r: int, axis: int) -> np.ndarray:
    """Exact 1-D erosion by min over a (2r+1) window (O(r) per pixel, r <= 16)."""
    a = np.moveaxis(a, axis, 0)
    n = a.shape[0]
    pad = np.pad(a, [(r, r)] + [(0, 0)] * (a.ndim - 1), mode="edge")
    out = pad[r:r + n].copy()
    for k in range(1, r + 1):
        out = np.minimum(out, pad[r - k:r - k + n])
        out = np.minimum(out, pad[r + k:r + k + n])
    return np.moveaxis(out, 0, axis)


def maximum_filter(a: np.ndarray, r: int) -> np.ndarray:
    if r <= 0:
        return a
    return -minimum_filter(-a, r)


def morph_close(mask: np.ndarray, r: int) -> np.ndarray:
    return minimum_filter(maximum_filter(mask, r), r)


def morph_open(mask: np.ndarray, r: int) -> np.ndarray:
    return maximum_filter(minimum_filter(mask, r), r)


def dog(a: np.ndarray, sigma1: float, sigma2: float) -> np.ndarray:
    """Difference of Gaussians, scale-normalised (sigma1^2 focus)."""
    return (gaussian_blur(a, sigma1) - gaussian_blur(a, sigma2)).astype(np.float32)


def log_response(a: np.ndarray, sigma: float) -> np.ndarray:
    """Scale-normalised Laplacian of Gaussian response; peaks at r = sqrt(2)*sigma."""
    return (sigma ** 2 * (gaussian_blur(a, sigma * 0.7) - gaussian_blur(a, sigma * 1.6)) * -1.0).astype(np.float32)


def unsharp(a: np.ndarray, radius: float, amount: float, threshold: float = 0.0,
            edge_guide: np.ndarray | None = None, edge_k: float = 0.08) -> np.ndarray:
    """Unsharp mask with optional edge-aware gain (suppresses skin halos)."""
    base = gaussian_blur(a, radius)
    detail = a - base
    if threshold > 0:
        keep = np.abs(detail) > threshold
        detail = np.where(keep, detail, 0.0)
    gain = amount
    if edge_guide is not None:
        g = np.clip(edge_guide, 0.0, 1.0)
        gain = amount * (g / (g + edge_k))
        if a.ndim == 3:
            gain = gain[..., None]
    return np.clip(a + gain * detail, 0.0, 1.0).astype(np.float32)


def feather(mask: np.ndarray, sigma: float) -> np.ndarray:
    return np.clip(gaussian_blur(mask.astype(np.float32), sigma), 0.0, 1.0)


def normalize01(a: np.ndarray) -> np.ndarray:
    lo, hi = float(np.min(a)), float(np.max(a))
    if hi - lo < 1e-6:
        return np.zeros_like(a, dtype=np.float32)
    return ((a - lo) / (hi - lo)).astype(np.float32)


def percentile(a: np.ndarray, p: float) -> float:
    return float(np.percentile(a, p))


def resize(a: np.ndarray, size: tuple[int, int]) -> np.ndarray:
    """Resize a float image with PIL (Lanczos), returning float32 (H, W, C)."""
    from PIL import Image
    h, w = size[1], size[0]
    if a.ndim == 2:
        im = Image.fromarray(np.clip(a * 255.0, 0, 255).astype(np.uint8), mode="L")
        return np.asarray(im.resize((w, h), Image.LANCZOS), dtype=np.float32) / 255.0
    im = Image.fromarray(np.clip(a * 255.0, 0, 255).astype(np.uint8), mode="RGB")
    return np.asarray(im.resize((w, h), Image.LANCZOS), dtype=np.float32) / 255.0


def hue_sat_value(rgb: np.ndarray) -> np.ndarray:
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = np.max(rgb, axis=-1)
    mn = np.min(rgb, axis=-1)
    d = mx - mn + EPS
    h = np.zeros_like(mx)
    m = (mx == r)
    h[m] = ((g[m] - b[m]) / d[m]) % 6.0
    m = (mx == g) & ~(mx == r)
    h[m] = (b[m] - r[m]) / d[m] + 2.0
    m = (mx == b) & ~(mx == r) & ~(mx == g)
    h[m] = (r[m] - g[m]) / d[m] + 4.0
    h = h * 60.0
    s = np.where(mx > EPS, (mx - mn) / np.maximum(mx, EPS), 0.0)
    return np.stack([h, s, mx], axis=-1).astype(np.float32)
