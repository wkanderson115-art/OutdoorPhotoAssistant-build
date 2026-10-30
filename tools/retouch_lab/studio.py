"""Studio-layer reference implementation (shoot anchor, liquify field, ID photo layout).

Everything here is measured by `tools/retouch_lab/verify_studio.py`, which writes
`acceptance/studio_report.json`. The Swift side (`RetouchStudioModel`,
`RetouchReshape`, `RetouchBackground`, `RetouchBatchRunner`) implements the same
formulas; these numbers are the acceptance evidence for the studio build.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from . import ops, portrait

# --------------------------------------------------------------------------- #
# shoot anchor (set consistency)
# --------------------------------------------------------------------------- #


@dataclass
class ShootAnchor:
    skin_lab_median: np.ndarray
    exposure: float
    white_balance: np.ndarray
    frame_count: int
    max_ev: float = 0.75

    @staticmethod
    def build(analyses: list[portrait.SkinAnalysis]) -> "ShootAnchor | None":
        valid = [a for a in analyses if a.exposure > 0.02]
        if not valid:
            return None
        med = np.median(np.stack([a.skin_lab_median for a in valid]), axis=0)
        exposure = float(np.median([a.exposure for a in valid]))
        wb = np.median(np.stack([a.white_balance for a in valid]), axis=0)
        return ShootAnchor(skin_lab_median=med, exposure=exposure,
                           white_balance=wb, frame_count=len(valid))

    def correction(self, analysis: portrait.SkinAnalysis) -> tuple[np.ndarray, float]:
        """Skin match split into exposure + colour balance.

        The target/frame ratio is measured on the *median skin colour* in linear
        light, then split: the luminance part becomes an EV correction (capped at
        max_ev, the commercial +-0.5 EV rule) and the remaining per-channel ratio
        becomes a small white-balance trim (capped at +-6 %). That way a dark frame
        is lifted by exposure and a colour cast is trimmed by gains, instead of one
        clamped gain trying to do both.
        """
        target_rgb = ops.lab_to_rgb(self.skin_lab_median.astype(np.float32)[None, None, :])[0, 0]
        frame_rgb = ops.lab_to_rgb(analysis.skin_lab_median.astype(np.float32)[None, None, :])[0, 0]
        target_lin = ops.srgb_to_linear(target_rgb).astype(np.float64)
        frame_lin = ops.srgb_to_linear(frame_rgb).astype(np.float64)
        ratio = np.maximum(target_lin, 1e-4) / np.maximum(frame_lin, 1e-4)
        lum = float(np.cbrt(ratio[0] * ratio[1] * ratio[2]))
        ev = float(np.clip(np.log2(max(lum, 1e-4)), -self.max_ev, self.max_ev))
        gains = np.clip(ratio / (2.0 ** ev), 0.88, 1.12)
        return gains.astype(np.float32), ev


def apply_correction(rgb: np.ndarray, gains: np.ndarray, ev: float) -> np.ndarray:
    """Linear-light correction: exposure and gains are linear multipliers, so the
    gamma-encoded frame is converted, scaled and converted back. Applying them
    directly to sRGB values would overshoot by roughly 2.4x."""
    lin = ops.srgb_to_linear(rgb)
    lin = lin * gains.astype(np.float32)[None, None, :] * np.float32(2.0 ** ev)
    return np.clip(ops.linear_to_srgb(lin), 0.0, 1.0)


def consistency(analyses: list[portrait.SkinAnalysis]) -> dict:
    """Spread of the delivered skin tone across a set (the number a studio cares about)."""
    labs = np.stack([a.skin_lab_median for a in analyses])
    exposures = np.array([a.exposure for a in analyses])
    worst = 0.0
    for i in range(len(labs)):
        for j in range(i + 1, len(labs)):
            worst = max(worst, float(ops.delta_e_2000(labs[i], labs[j])))
    return {
        "frames": len(analyses),
        "max_skin_de": round(worst, 3),
        "exposure_spread_ev": round(float(np.max(exposures) - np.min(exposures)), 4),
    }


# --------------------------------------------------------------------------- #
# liquify (parametric reshape field)
# --------------------------------------------------------------------------- #


@dataclass
class Reshape:
    face_width: float = 0.0
    jawline: float = 0.0
    chin: float = 0.0
    eye_size: float = 0.0
    nose_width: float = 0.0
    neck_thin: float = 0.0
    waist: float = 0.0
    arm_thin: float = 0.0
    edge_lock: float = 0.85
    max_displacement: float = 0.06

    def is_neutral(self) -> bool:
        return not any([self.face_width, self.jawline, self.chin, self.eye_size,
                        self.nose_width, self.neck_thin, self.waist, self.arm_thin])

    def clamped(self) -> "Reshape":
        def c(v: float) -> float:
            return float(min(1.0, max(0.0, v)))
        r = Reshape(c(self.face_width), c(self.jawline), c(self.chin),
                    c(self.eye_size) * 0.6, c(self.nose_width) * 0.5,
                    c(self.neck_thin), c(self.waist), c(self.arm_thin),
                    min(1.0, max(0.4, self.edge_lock)),
                    min(0.08, max(0.01, self.max_displacement)))
        total = r.face_width + r.jawline + r.chin + r.eye_size + r.nose_width
        if total > 0.6:
            k = 0.6 / total
            r.face_width *= k; r.jawline *= k; r.chin *= k
            r.eye_size *= k; r.nose_width *= k
        return r


def _smoothstep(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def reshape_field(size: tuple[int, int], face: portrait.FaceGeometry, reshape: Reshape) -> tuple[np.ndarray, np.ndarray]:
    """Displacement field in pixels (source = dest + offset), y-down array order.

    Every slider maps to a bounded horizontal squeeze / radial magnification with
    a smoothstep falloff; the maximum displacement is `slider * max_px` where
    max_px is proportional to the face (or image) width, so the field can never
    exceed the commercial cap. Frame borders are locked to exactly zero.
    """
    w, h = size
    r = reshape.clamped()
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    nx = xx / max(w - 1, 1)
    ny = yy / max(h - 1, 1)
    dx = np.zeros((h, w), dtype=np.float32)
    dy = np.zeros((h, w), dtype=np.float32)
    fw_px = max(face.width * w, 32.0)

    def squeeze(cx: float, cy: float, rx: float, ry: float, strength: float,
                max_px: float) -> None:
        if strength <= 0:
            return
        u = (nx - cx) / max(rx, 1e-4)
        v = (ny - cy) / max(ry, 1e-4)
        d = np.sqrt(u * u + v * v)
        fall = _smoothstep(1.0 - d)
        # horizontal squeeze toward the centre line, bounded by strength * max_px
        dx[...] -= u * fall * (strength * max_px)

    box = face.box
    fw, fh = face.width, face.height
    cx, cy = box[0] + fw / 2, box[1] + fh / 2
    squeeze(cx, box[1] + fh * 0.45, fw * 0.62, fh * 0.52, r.face_width, fw_px * 0.110)
    squeeze(cx, box[1] + fh * 0.78, fw * 0.50, fh * 0.26, r.jawline, fw_px * 0.090)
    squeeze(cx, box[1] + fh * 0.98, fw * 0.34, fh * 0.22, r.chin, fw_px * 0.070)
    nose = face.nose if face.nose else (cx, box[1] + fh * 0.62)
    squeeze(nose[0], nose[1], fw * 0.13, fh * 0.11, r.nose_width, fw_px * 0.060)
    squeeze(cx, box[1] + fh * 1.28, fw * 0.46, fh * 0.24, r.neck_thin, fw_px * 0.090)
    squeeze(0.5, 0.74, 0.30, 0.16, r.waist, w * 0.040)
    squeeze(0.24, 0.70, 0.15, 0.18, r.arm_thin, w * 0.032)
    squeeze(0.76, 0.70, 0.15, 0.18, r.arm_thin, w * 0.032)

    # eye magnification: radial outward, capped at 1.35x of the eye box
    for eye in face.derived_eyes():
        if r.eye_size <= 0:
            break
        ecx = eye[0] + eye[2] / 2
        ecy = eye[1] + eye[3] / 2
        u = (nx - ecx) / max(eye[2] * 0.75, 1e-4)
        v = (ny - ecy) / max(eye[3] * 0.95, 1e-4)
        d = np.sqrt(u * u + v * v)
        fall = _smoothstep(1.0 - d)
        dx += (nx - ecx) * fall * r.eye_size * 0.50 * w
        dy += (ny - ecy) * fall * r.eye_size * 0.50 * h

    # frame edge lock: exactly zero displacement in the outer band
    edge = np.minimum(np.minimum(nx, 1.0 - nx), np.minimum(ny, 1.0 - ny))
    band = 0.02 + 0.06 * r.edge_lock
    dx *= _smoothstep(edge / band)
    dy *= _smoothstep(edge / band)

    mag = np.sqrt(dx * dx + dy * dy)
    cap = r.max_displacement * max(w, h)
    scale = np.where(mag > cap, cap / np.maximum(mag, 1e-4), 1.0)
    return dx * scale, dy * scale


def field_stats(dx: np.ndarray, dy: np.ndarray, size: tuple[int, int]) -> dict:
    w, h = size
    mag = np.sqrt(dx ** 2 + dy ** 2)
    grad_x = np.abs(np.diff(dx, axis=1)) + np.abs(np.diff(dy, axis=1))
    grad_y = np.abs(np.diff(dx, axis=0)) + np.abs(np.diff(dy, axis=0))
    border = 3
    border_max = max(float(mag[:border].max()), float(mag[-border:].max()),
                     float(mag[:, :border].max()), float(mag[:, -border:].max()))
    return {
        "max_displacement_px": round(float(mag.max()), 3),
        "max_displacement_ratio": round(float(mag.max() / max(w, h)), 5),
        "max_neighbour_step_px": round(float(max(grad_x.max(), grad_y.max())), 4),
        "border_max_px": round(border_max, 4),
        "mean_displacement_px": round(float(mag.mean()), 4),
    }


# --------------------------------------------------------------------------- #
# ID photo layout
# --------------------------------------------------------------------------- #

ID_SPECS = {
    "oneInch": (25.0, 35.0, 0.66),
    "smallOneInch": (22.0, 32.0, 0.66),
    "twoInch": (35.0, 49.0, 0.66),
    "smallTwoInch": (35.0, 45.0, 0.66),
    "passport": (33.0, 48.0, 0.72),
    "visaUS": (51.0, 51.0, 0.69),
}


def id_pixel_size(spec: str, dpi: float = 300.0) -> tuple[int, int]:
    mm_w, mm_h, _ = ID_SPECS[spec]
    return int(round(mm_w / 25.4 * dpi)), int(round(mm_h / 25.4 * dpi))


def id_crop_rect(image_size: tuple[int, int], face: portrait.FaceGeometry,
                 spec: str, dpi: float = 300.0) -> dict:
    """Head-height driven crop: crown-to-chin = headHeightRatio, eyes on 0.44 line."""
    w, h = image_size
    mm_w, mm_h, head_ratio = ID_SPECS[spec]
    out_w, out_h = id_pixel_size(spec, dpi)
    box = face.box
    head_px = face.height * h * 1.08            # 8 % hair allowance
    scale = out_h * head_ratio / max(head_px, 1e-3)
    # eye line from the geometry (fall back to the classic 0.42 of the face box)
    eyes = face.derived_eyes()
    eye_y = (eyes[0][1] + eyes[0][3] / 2 + eyes[1][1] + eyes[1][3] / 2) / 2 * h
    return {
        "output_px": (out_w, out_h),
        "scale": round(float(scale), 4),
        "crop_px": (int(round(out_w / scale)), int(round(out_h / scale))),
        "eye_line_target_ratio": 0.44,
        "eye_line_actual_ratio": round(float(eye_y / h), 4),
        "head_ratio": head_ratio,
    }


def print_sheet_fit(photo: tuple[int, int], paper_mm: tuple[float, float] = (152.0, 102.0),
                    gap_mm: float = 2.0, dpi: float = 300.0) -> dict:
    paper_w = int(paper_mm[0] / 25.4 * dpi)
    paper_h = int(paper_mm[1] / 25.4 * dpi)
    gap = int(gap_mm / 25.4 * dpi)
    cols = max(0, (paper_w + gap) // (photo[0] + gap))
    rows = max(0, (paper_h + gap) // (photo[1] + gap))
    return {"paper_px": (paper_w, paper_h), "cols": int(cols), "rows": int(rows),
            "count": int(cols * rows), "gap_px": gap}
