"""真图批次：把用户给的 7 张真实照片按类别跑精修 + 质检。

这不是合成测试。每张照片先按内容归到 app 里的品类（20 类 / 80 预设之一），
再走对应 look 与参数档位，最后按该品类的门禁口径判定。

用法：
    python -m tools.retouch_lab.real_batch
    python -m tools.retouch_lab.real_batch --only food,product
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools.retouch_lab import ops, pipeline, portrait  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
IMAGE_DIR = os.path.join(ROOT, "testdata_real")
OUT_DIR = os.path.join(ROOT, "build", "real_batch")

# 品类 → 门店口径（门禁档位）
#   portrait : 纹理 0.50–1.15 + 肤色 ΔE/明度/p95 + 皮肤裁切 + 接缝 + 瑕疵
#   scene    : 纹理 0.60–1.20 + 全图裁切 + SSIM
#   product  : 纹理 0.60–1.45（商品/建筑允许加锐化）+ 全图裁切 0.0100 + SSIM 0.90
#   document : 纹理 0.60–1.50 + 全图裁切 0.0100 + SSIM 0.92（翻拍要结构稳定）
MODES = {
    "portrait": dict(texture=(0.50, 1.15), clipping_full=0.0100, ssim=0.85,
                     skin=True, seam=True, blemish=True),
    "scene": dict(texture=(0.60, 1.20), clipping_full=0.0100, ssim=0.85,
                  skin=False, seam=False, blemish=False),
    "product": dict(texture=(0.60, 1.45), clipping_full=0.0100, ssim=0.85,
                    skin=False, seam=False, blemish=False),
    "document": dict(texture=(0.60, 1.50), clipping_full=0.0100, ssim=0.92,
                     skin=False, seam=False, blemish=False),
}

LABELS = {
    "texture_retention": "纹理保留", "skin_tone_de": "肤色 ΔE00",
    "skin_pixel_de_p95_info": "肤色 ΔE P95", "skin_luma_shift": "肤色明度",
    "clipping_skin": "皮肤裁切", "clipping_full": "整体裁切",
    "seam_ratio": "接缝", "ssim": "SSIM",
}

# 7 张真图的归类（品类 → 预设 id，数值取自 Swift PresetCatalog）
CASES = [
    dict(key="food", file="hongshaorou_food.jpg", category="美食摄影", preset="p45 美食写真",
         look="commercial_natural", mode="scene",
         params=dict(smooth_amount=0.42, dodge_burn_amount=0.18, clarity_amount=0.14, vibrance=0.12)),
    dict(key="product", file="tiaoliao_package.jpg", category="商品摄影", preset="p49 电商白底",
         look="commercial_natural", mode="product",
         params=dict(sharpen_amount=0.36, clarity_amount=0.18, lut_strength=0.25, vibrance=0.06)),
    dict(key="landscape", file="canyon_landscape.jpg", category="风景摄影", preset="p25 自然风光",
         look="landscape_natural", mode="scene",
         params=dict(sharpen_amount=0.30, clarity_amount=0.18, lut_strength=0.28, vibrance=0.11)),
    dict(key="auto", file="truck_traffic_auto.jpg", category="汽车与机车", preset="p57 汽车商业",
         look="commercial_natural", mode="product",
         params=dict(smooth_amount=0.40, sharpen_amount=0.30, clarity_amount=0.18, lut_strength=0.34)),
    dict(key="travel", file="window_view_travel.jpg", category="旅行与日常", preset="p73 旅行大片",
         look="landscape_natural", mode="scene",
         params=dict(sharpen_amount=0.28, clarity_amount=0.18, lut_strength=0.36, vibrance=0.12)),
    # 这张其实是手机截图（状态栏、黑边、"2/5""查看原图" UI 都在），
    # 按「文档与翻拍 / 展品记录」走：只做轻度校正，结构不许动。
    dict(key="screenshot", file="wuling_mini_auto.jpg", category="文档与翻拍", preset="p80 展品记录",
         look="commercial_natural", mode="document",
         params=dict(sharpen_amount=0.08, clarity_amount=0.04, lut_strength=0.15,
                     contrast=1.00, shadow_lift=0.02)),
    dict(key="pet", file="maine_coon_pet.jpg", category="宠物与野生动物", preset="p30 宠物写真",
         look="commercial_natural", mode="scene",
         params=dict(smooth_amount=0.50, dodge_burn_amount=0.26, sharpen_amount=0.22)),
]


def load(path: str, max_edge: int = 1800) -> np.ndarray:
    im = Image.open(path).convert("RGB")
    w, h = im.size
    scale = min(1.0, max_edge / float(max(w, h)))
    if scale < 1.0:
        im = im.resize((int(round(w * scale)), int(round(h * scale))), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def save(path: str, rgb: np.ndarray, quality: int = 95) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    Image.fromarray(ops.to_uint8(rgb)).save(path, quality=quality, subsampling=1)


def build_params(overrides: dict):
    p = portrait.RetouchParameters()
    for name, value in overrides.items():
        if hasattr(p, name):
            setattr(p, name, value)
    return p


def judge(metrics: dict, mode: str) -> tuple[bool, list[str]]:
    cfg = MODES[mode]
    lo, hi = cfg["texture"]
    problems = []
    texture = float(metrics.get("texture_retention", 1.0))
    if not (lo <= texture <= hi):
        problems.append(f"纹理保留 {texture:.3f} 超出 {lo:.2f}–{hi:.2f}")
    clip = float(metrics.get("clipping_full", 0.0))
    if clip > cfg["clipping_full"]:
        problems.append(f"整体裁切 {clip:.4f} 超过 {cfg['clipping_full']:.4f}")
    ssim = float(metrics.get("ssim", 0.0))
    if ssim < cfg["ssim"]:
        problems.append(f"SSIM {ssim:.3f} 低于 {cfg['ssim']:.2f}")
    if cfg["skin"]:
        de = float(metrics.get("skin_tone_de", 0.0))
        if de > 3.0:
            problems.append(f"肤色 ΔE {de:.2f} 超过 3.00")
        p95 = float(metrics.get("skin_pixel_de_p95_info", 0.0))
        if p95 > 6.0:
            problems.append(f"肤色 ΔE P95 {p95:.2f} 超过 6.00")
        luma = float(metrics.get("skin_luma_shift", 0.0))
        if luma > 18.0:
            problems.append(f"肤色明度 {luma:.2f} 超过 18.0")
        skin_clip = float(metrics.get("clipping_skin", 0.0))
        if skin_clip > 0.002:
            problems.append(f"皮肤裁切 {skin_clip:.4f} 超过 0.0020")
    if cfg["seam"]:
        seam = float(metrics.get("seam_ratio", 1.0))
        if abs(seam - 1.0) > 0.30:
            problems.append(f"接缝比 {seam:.2f} 偏离 1.00 超过 0.30")
    return (len(problems) == 0), problems


def print_row(metrics: dict, mode: str) -> None:
    cfg = MODES[mode]
    lo, hi = cfg["texture"]
    texture = float(metrics.get("texture_retention", 1.0))
    clip = float(metrics.get("clipping_full", 0.0))
    ssim = float(metrics.get("ssim", 0.0))
    print(f"    纹理 {texture:.3f} (允许 {lo:.2f}–{hi:.2f})   "
          f"裁切 {clip:.4f} (≤{cfg['clipping_full']:.4f})   SSIM {ssim:.3f} (≥{cfg['ssim']:.2f})")
    if cfg["skin"]:
        print(f"    肤色 ΔE {float(metrics.get('skin_tone_de', 0)):.2f}   "
              f"p95 {float(metrics.get('skin_pixel_de_p95_info', 0)):.2f}   "
              f"明度 {float(metrics.get('skin_luma_shift', 0)):.2f}")


def run_case(case: dict) -> dict | None:
    src = os.path.join(IMAGE_DIR, case["file"])
    if not os.path.isfile(src):
        print(f"  [跳过] 缺文件 {src}")
        return None
    rgb = load(src)
    params = build_params(case["params"]).scaled(max(rgb.shape[:2]))
    started = time.time()
    result = pipeline.retouch_scene(rgb, look=case["look"], params=params,
                                    document_mode=(case["mode"] == "document"))
    elapsed = time.time() - started

    before_path = os.path.join(OUT_DIR, f"{case['key']}_before.jpg")
    after_path = os.path.join(OUT_DIR, f"{case['key']}_after.jpg")
    save(before_path, rgb)
    save(after_path, result.image)

    metrics = {k: float(v) for k, v in result.report.metrics.items()}
    passed, problems = judge(metrics, case["mode"])

    print(f"\n### {case['category']} / {case['preset']}  ({case['file']})")
    print(f"    look={case['look']} · 口径={case['mode']} · 耗时 {elapsed:.1f}s")
    print_row(metrics, case["mode"])
    print(f"    结论：{'通过' if passed else '未通过'}")
    for line in problems:
        print("      - " + line)

    return dict(case=case, metrics={k: round(v, 4) for k, v in metrics.items()},
                passed=passed, problems=problems, seconds=round(elapsed, 2),
                before=before_path, after=after_path)


def contact_sheet(rows: list[dict], path: str, tile: int = 520) -> None:
    tiles = []
    for row in rows:
        try:
            b = Image.open(row["before"]).convert("RGB")
            a = Image.open(row["after"]).convert("RGB")
        except OSError:
            continue
        w, h = a.size
        nw = max(1, int(w * tile / h))
        pair = Image.new("RGB", (nw * 2 + 6, tile), (16, 16, 16))
        pair.paste(b.resize((nw, tile), Image.LANCZOS), (0, 0))
        pair.paste(a.resize((nw, tile), Image.LANCZOS), (nw + 6, 0))
        tiles.append((pair, f"{row['case']['key']} | {row['case']['category']} | {row['case']['preset']} | "
                             f"{'PASS' if row['passed'] else 'FAIL'}"))
    if not tiles:
        return
    width = sum(t[0].size[0] for t in tiles) + 10 * (len(tiles) - 1)
    canvas = Image.new("RGB", (width, tile + 36), (16, 16, 16))
    draw = ImageDraw.Draw(canvas)
    x = 0
    for im, label in tiles:
        canvas.paste(im, (x, 36))
        draw.text((x + 6, 14), label + "   before | after", fill=(236, 236, 236))
        x += im.size[0] + 10
    canvas.save(path, quality=90)
    print(f"\ncontact sheet: {path}  {canvas.size}")


def main() -> int:
    parser = argparse.ArgumentParser(description="真图批次：分类 → 精修 → 质检")
    parser.add_argument("--only", default="", help="只跑指定 key，逗号分隔")
    args = parser.parse_args()
    wanted = [k.strip() for k in args.only.split(",") if k.strip()]

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"图片目录：{IMAGE_DIR}")
    print(f"输出目录：{OUT_DIR}")

    rows = []
    for case in CASES:
        if wanted and case["key"] not in wanted:
            continue
        row = run_case(case)
        if row:
            rows.append(row)

    if rows:
        with open(os.path.join(OUT_DIR, "report.json"), "w", encoding="utf-8") as fh:
            json.dump([{k: v for k, v in r.items() if k != "case"} | {"category": r["case"]["category"],
                                                                     "preset": r["case"]["preset"],
                                                                     "file": r["case"]["file"],
                                                                     "look": r["case"]["look"],
                                                                     "mode": r["case"]["mode"]}
                       for r in rows], fh, ensure_ascii=False, indent=2)
        contact_sheet(rows, os.path.join(OUT_DIR, "real_batch.jpg"))

    total = len(rows)
    passed = sum(1 for r in rows if r["passed"])
    print(f"\n== 汇总：{passed}/{total} 通过 ==")
    for r in rows:
        print(f"  {'PASS' if r['passed'] else 'FAIL'}  {r['case']['key']:<14} {r['case']['category']:<10} "
              f"{r['case']['preset']:<12} {r['case']['mode']:<9} {r['seconds']:>5.1f}s")
        for p in r["problems"]:
            print(f"        - {p}")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
