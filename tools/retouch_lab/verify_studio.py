"""Verifies the studio layer: set consistency, liquify field, ID photo layout.

Writes acceptance/studio_report.json and prints a compact table.
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.retouch_lab import ops, portrait, studio  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "acceptance")


def load_face() -> tuple[np.ndarray, portrait.FaceGeometry]:
    meta = json.load(open(os.path.join(ROOT, "testdata", "faces.json"), encoding="utf-8"))["wiki_05.jpg"]
    face = portrait.FaceGeometry(box=tuple(meta["box"]),
                                 left_eye=tuple(meta["left_eye"]),
                                 right_eye=tuple(meta["right_eye"]),
                                 lips=tuple(meta["lips"]), nose=tuple(meta["nose"]))
    im = Image.open(os.path.join(ROOT, "testdata", "final", "wiki_05.jpg")).convert("RGB")
    w, h = im.size
    sc = 1200 / max(w, h)
    im = im.resize((int(w * sc), int(h * sc)), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0, face


def main() -> None:
    rgb, face = load_face()
    os.makedirs(OUT, exist_ok=True)
    report: dict = {}

    # 1. set consistency: five frames of the same shoot with exposure/WB drift
    variations = [
        (1.00, (1.00, 1.00, 1.00)),
        (0.82, (1.03, 1.00, 0.96)),
        (1.18, (0.98, 1.01, 1.05)),
        (0.92, (1.06, 1.00, 0.93)),
        (1.08, (0.96, 1.00, 1.07)),
    ]
    frames = [np.clip(rgb * np.array(gain, dtype=np.float32)[None, None, :] * ev, 0.0, 1.0) for ev, gain in variations]
    analyses = [portrait.analyze(f, face) for f in frames]
    before = studio.consistency(analyses)

    anchor = studio.ShootAnchor.build(analyses)
    corrected = []
    for frame, analysis in zip(frames, analyses):
        gains, ev = anchor.correction(analysis)
        corrected.append(studio.apply_correction(frame, gains, ev))
    analyses_after = [portrait.analyze(f, face) for f in corrected]
    after = studio.consistency(analyses_after)

    report["set_consistency"] = {
        "frames": before["frames"],
        "max_skin_de_before": before["max_skin_de"],
        "max_skin_de_after": after["max_skin_de"],
        "exposure_spread_before_ev": before["exposure_spread_ev"],
        "exposure_spread_after_ev": after["exposure_spread_ev"],
        "passed": after["max_skin_de"] <= 2.5 and after["exposure_spread_ev"] <= 0.08,
    }
    print("set consistency:", report["set_consistency"])

    # 2. liquify: field properties for a commercial-strength slider set
    size = (rgb.shape[1], rgb.shape[0])
    cases = {
        "face_only": studio.Reshape(face_width=0.6, jawline=0.4, chin=0.3),
        "full": studio.Reshape(face_width=0.7, jawline=0.5, chin=0.4, eye_size=0.5,
                               nose_width=0.4, neck_thin=0.5, waist=0.6, arm_thin=0.5),
        "extreme": studio.Reshape(face_width=1.0, jawline=1.0, chin=1.0, eye_size=1.0,
                                  nose_width=1.0, neck_thin=1.0, waist=1.0, arm_thin=1.0),
        "neutral": studio.Reshape(),
    }
    reshape_report = {}
    for name, reshape in cases.items():
        dx, dy = studio.reshape_field(size, face, reshape)
        st = studio.field_stats(dx, dy, size)
        st["neutral"] = bool(reshape.is_neutral())
        st["cap_ratio"] = reshape.clamped().max_displacement
        st["smooth_ok"] = st["max_neighbour_step_px"] <= 0.25
        st["edge_ok"] = st["border_max_px"] <= 0.05
        st["cap_ok"] = st["max_displacement_ratio"] <= reshape.clamped().max_displacement + 1e-6
        reshape_report[name] = st
        print("reshape", name, st)
    report["reshape"] = reshape_report
    report["reshape_passed"] = all(v["smooth_ok"] and v["edge_ok"] and v["cap_ok"]
                                   for v in reshape_report.values())

    # 3. ID photo layout + print sheet
    id_report = {}
    for spec in studio.ID_SPECS:
        px = studio.id_pixel_size(spec)
        crop = studio.id_crop_rect(size, face, spec)
        fit = studio.print_sheet_fit(px)
        id_report[spec] = {"pixel_size": px, "crop": crop, "sheet_6inch": fit}
        print("id", spec, px, "sheet count", fit["count"])
    report["id_photo"] = id_report
    one_inch = studio.id_pixel_size("oneInch")
    report["id_passed"] = (one_inch == (295, 413)
                           and id_report["oneInch"]["sheet_6inch"]["count"] >= 8
                           and id_report["visaUS"]["pixel_size"] == (602, 602))

    with open(os.path.join(OUT, "studio_report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)
    ok = report["set_consistency"]["passed"] and report["reshape_passed"] and report["id_passed"]
    print("STUDIO CHECKS:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
