"""ScreenshotDetector 的 Python 复刻验证：对 7 张真图跑三条启发式，看是否只命中截图。

用途：在 Swift 版本落地前，先用真实样本校准阈值，避免「商品白底图被误判成截图」。
"""
from __future__ import annotations

import glob
import os

import numpy as np
from PIL import Image

DIR = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "testdata_real"))


def load(name: str, max_edge: int = 550) -> np.ndarray:
    im = Image.open(os.path.join(DIR, name)).convert("RGB")
    w, h = im.size
    s = min(1.0, max_edge / float(max(w, h)))
    if s < 1.0:
        im = im.resize((max(1, int(round(w * s))), max(1, int(round(h * s)))), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def luma(rgb: np.ndarray) -> np.ndarray:
    return 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]


def inspect(rgb: np.ndarray) -> dict:
    h, w = rgb.shape[:2]
    y = luma(rgb)
    # 1) 边框带：四边各 6%
    bw = max(2, int(round(w * 0.06)))
    bh = max(2, int(round(h * 0.06)))
    strips = [y[:bh, :], y[-bh:, :], y[:, :bw], y[:, -bw:]]
    border = float(np.mean([float(np.mean((s < 0.03) | (s > 0.97))) for s in strips]))

    # 2) 恒定行列
    row_std = y.std(axis=1)
    col_std = y.std(axis=0)
    const_rows = float(np.mean(row_std < 0.008))
    const_cols = float(np.mean(col_std < 0.008))

    # 3) 量化色数（每通道 5 bit）
    q = (rgb * 31.0).round().astype(np.int32)
    packed = (q[..., 0] << 10) | (q[..., 1] << 5) | q[..., 2]
    colors = int(np.unique(packed).size)

    hit_border = border > 0.65
    hit_lines = const_rows > 0.35 or const_cols > 0.35
    hit_colors = colors < 3000
    votes = int(hit_border) + int(hit_lines) + int(hit_colors)
    is_screen = hit_border and (hit_lines or hit_colors)
    return dict(border=border, const_rows=const_rows, const_cols=const_cols,
                colors=colors, votes=votes, is_screen=is_screen,
                flags=(hit_border, hit_lines, hit_colors))


def main() -> None:
    files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(DIR, "*.jpg")))
    print(f"{'file':<28} {'border':>7} {'rowC':>6} {'colC':>6} {'colors':>7}  命中(B/行/色)  判定")
    print("-" * 96)
    for name in files:
        v = inspect(load(name))
        flags = "/".join("Y" if f else "-" for f in v["flags"])
        print(f"{name:<28} {v['border']:>7.3f} {v['const_rows']:>6.3f} {v['const_cols']:>6.3f} "
              f"{v['colors']:>7d}  {flags:<12} {'SCREENSHOT' if v['is_screen'] else 'photo'}")


if __name__ == "__main__":
    main()
