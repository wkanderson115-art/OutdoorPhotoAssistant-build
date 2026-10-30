"""Acceptance runner for the retouch reference pipeline.

Usage:
    python -m tools.retouch_lab.run --input testdata --output out --look refined_portrait

For every image it writes:
    out/<name>_before.jpg / _after.jpg / _crop.png  (100% skin crop side by side)
    out/<name>_mask.png                              (skin + feature mask overlay)
    out/report.json                                  (QC metrics per image)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.retouch_lab import ops, pipeline, portrait  # noqa: E402


def load(path: str, max_edge: int = 2400) -> np.ndarray:
    im = Image.open(path).convert("RGB")
    w, h = im.size
    scale = min(1.0, max_edge / float(max(w, h)))
    if scale < 1.0:
        im = im.resize((int(round(w * scale)), int(round(h * scale))), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def save(path: str, rgb: np.ndarray, quality: int = 95) -> None:
    Image.fromarray(ops.to_uint8(rgb)).save(path, quality=quality, subsampling=1)


def draw_debug(rgb: np.ndarray, analysis: portrait.SkinAnalysis, out_path: str) -> None:
    h, w = rgb.shape[:2]
    vis = rgb.copy()
    skin = analysis.skin
    vis[..., 0] = np.clip(vis[..., 0] * (1 - 0.45 * skin) + 0.45 * skin, 0, 1)
    feat = analysis.feature
    vis[..., 2] = np.clip(vis[..., 2] * (1 - 0.6 * feat) + 0.6 * feat, 0, 1)
    f = analysis.face
    x0, y0, x1, y1 = [int(v * s) for v, s in zip(f.box, (w, h, w, h))]
    vis[max(0, y0):y0 + 3, max(0, x0):x1] = 1.0
    vis[max(0, y1 - 3):y1, max(0, x0):x1] = 1.0
    vis[max(0, y0):y1, max(0, x0):x0 + 3] = 1.0
    vis[max(0, y0):y1, max(0, x1 - 3):x1] = 1.0
    save(out_path, vis)


def crop_pair(before: np.ndarray, after: np.ndarray, face: portrait.FaceGeometry,
              path: str, target_w: int = 1400) -> None:
    h, w = before.shape[:2]
    x0, y0, x1, y1 = face.box
    cx = int((x0 + x1) / 2 * w)
    cy = int((y0 + y1) / 2 * h)
    half = int(min(w, h) * 0.16)
    x0c, x1c = max(0, cx - half), min(w, cx + half)
    y0c, y1c = max(0, cy - half), min(h, cy + half)
    b = ops.to_uint8(before[y0c:y1c, x0c:x1c])
    a = ops.to_uint8(after[y0c:y1c, x0c:x1c])
    im_b = Image.fromarray(b)
    im_a = Image.fromarray(a)
    scale = target_w / float(im_b.width * 2 + 12)
    if scale > 1:
        im_b = im_b.resize((int(im_b.width * scale), int(im_b.height * scale)), Image.LANCZOS)
        im_a = im_a.resize((int(im_a.width * scale), int(im_a.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGB", (im_b.width + im_a.width + 12, max(im_b.height, im_a.height)), (24, 24, 24))
    canvas.paste(im_b, (0, 0))
    canvas.paste(im_a, (im_b.width + 12, 0))
    canvas.save(path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="testdata")
    ap.add_argument("--output", default="out")
    ap.add_argument("--faces", default="testdata/faces.json")
    ap.add_argument("--look", default="refined_portrait")
    ap.add_argument("--max-edge", type=int, default=2400)
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    faces = {}
    if os.path.exists(args.faces):
        faces = json.load(open(args.faces, "r", encoding="utf-8"))

    os.makedirs(args.output, exist_ok=True)
    reports = {}
    names = [n for n in sorted(os.listdir(args.input))
             if n.lower().endswith((".jpg", ".jpeg", ".png"))]
    for name in names:
        if args.only and args.only not in name:
            continue
        path = os.path.join(args.input, name)
        meta = faces.get(name)
        rgb = load(path, args.max_edge)
        h, w = rgb.shape[:2]
        t0 = time.time()
        if meta:
            f = meta.get("box")
            face = portrait.FaceGeometry(
                box=tuple(f),
                left_eye=tuple(meta["left_eye"]) if meta.get("left_eye") else None,
                right_eye=tuple(meta["right_eye"]) if meta.get("right_eye") else None,
                lips=tuple(meta["lips"]) if meta.get("lips") else None,
                nose=tuple(meta["nose"]) if meta.get("nose") else None,
            )
            result = pipeline.retouch_portrait(rgb, face, look=args.look)
            analysis = portrait.analyze(rgb, face)
            stem = os.path.splitext(name)[0]
            save(os.path.join(args.output, f"{stem}_before.jpg"), rgb)
            save(os.path.join(args.output, f"{stem}_after.jpg"), result.image)
            crop_pair(rgb, result.image, face, os.path.join(args.output, f"{stem}_crop.png"))
            draw_debug(rgb, analysis, os.path.join(args.output, f"{stem}_mask.png"))
            kind = "portrait"
        else:
            result = pipeline.retouch_scene(rgb, look="landscape_natural")
            stem = os.path.splitext(name)[0]
            save(os.path.join(args.output, f"{stem}_before.jpg"), rgb)
            save(os.path.join(args.output, f"{stem}_after.jpg"), result.image)
            kind = "scene"

        dt = time.time() - t0
        rep = {
            "image": name,
            "kind": kind,
            "size": [w, h],
            "seconds": round(dt, 2),
            "passed": result.report.passed,
            "notes": result.report.notes,
            "metrics": {k: (round(v, 4) if isinstance(v, float) else v)
                        for k, v in result.report.metrics.items()},
        }
        reports[name] = rep
        print(json.dumps(rep, ensure_ascii=False, indent=2))

    with open(os.path.join(args.output, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(reports, fh, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
