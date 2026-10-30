"""类型矩阵：把精修管线在多种「类型」上真跑一遍，出图 + 出质检结论。

背景：之前只验证了人像（wiki_05）。商业交付里还有风景、户外野生动物、
室内建筑、静物微距、老照片/黑白肖像、夜景通透等类型，每一类走的
`RetouchLook`、参数档位和门禁口径都不同，必须逐类跑通。

这个脚本做三件事：
1. 按配置表逐类跑 `retouch_portrait` / `retouch_scene`（Python 参考实现，
   与 Swift `RetouchPipeline` 同算法、同阈值）；
2. 用 **V22 的门禁口径**（人像：纹理 0.50–1.15 + 肤色ΔE/明度/p95 + 皮肤裁切
   + 接缝 + 瑕疵；风景：纹理 0.60–1.20 + 全图裁切 + SSIM）判定并打印；
3. 把 before/after 存到 build/type_matrix/，并拼一张 contact sheet。

用法：
    python -m tools.retouch_lab.type_matrix
    python -m tools.retouch_lab.type_matrix --only portrait,landscape
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
from tools.retouch_lab.qc_probe import judge, print_table  # noqa: E402

def _find_testdata() -> str:
    """找测试图目录：环境变量优先，其次从本文件往上逐级找 opa_v15/testdata。"""
    env = os.environ.get("RETOUCH_TESTDATA", "")
    if env and os.path.isdir(env):
        return os.path.abspath(env)
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = []
    node = here
    for _ in range(6):
        node = os.path.dirname(node)
        candidates.append(os.path.join(node, "opa_v15", "testdata"))
    candidates.append(os.path.join(here, "..", "..", "..", "opa_v15", "testdata"))
    for candidate in candidates:
        if os.path.isdir(candidate):
            return os.path.abspath(candidate)
    return ""


TESTDATA = _find_testdata()

OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "build", "type_matrix"))

# 类型配置：
#   key, 中文名, 源图, look, 分支(portrait/scene), 是否用 faces.json 的官方脸框
CASES = [
    ("portrait_commercial", "人像·商业自然", "wiki_05.jpg", "commercial_natural", "portrait", True),
    ("portrait_refined", "人像·精致写真", "wiki_04.jpg", "refined_portrait", "portrait", False),
    ("landscape", "风景·自然风光", "scene_00.jpg", "landscape_natural", "scene", False),
    ("outdoor_cinematic", "户外·电影感", "scene_01.jpg", "cinematic", "scene", False),
    ("interior", "室内建筑·通透", "wiki_01.jpg", "landscape_natural", "scene", False),
    ("night_clear", "暗调室内·夜景通透", "wiki_03.jpg", "night_clear", "scene", False),
    ("still_life", "静物微距·清新", "scene_00.jpg", "fresh_japanese", "scene", False),
]

# 没有官方脸框的肖像：按经验给一个归一化框（清晰正面肖像，脸在上半部中央）。
# 这类行会标注「估算脸框」，提醒读者皮肤指标比有官方元数据时弱。
ESTIMATED_FACE = {
    "wiki_04.jpg": (0.26, 0.02, 0.80, 0.40),
}


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


def face_geometry(name: str) -> tuple["portrait.FaceGeometry | None", bool]:
    """返回 (FaceGeometry, 是否官方元数据)。"""
    root = os.path.dirname(TESTDATA)
    faces_path = os.path.join(TESTDATA, "faces.json")
    if os.path.isfile(faces_path):
        with open(faces_path, "r", encoding="utf-8") as fh:
            meta = json.load(fh)
        if name in meta:
            m = meta[name]
            return portrait.FaceGeometry(
                box=tuple(m["box"]),
                left_eye=tuple(m["left_eye"]) if m.get("left_eye") else None,
                right_eye=tuple(m["right_eye"]) if m.get("right_eye") else None,
                lips=tuple(m["lips"]) if m.get("lips") else None,
                nose=tuple(m["nose"]) if m.get("nose") else None,
            ), True
    if name in ESTIMATED_FACE:
        return portrait.FaceGeometry(box=ESTIMATED_FACE[name],
                                     left_eye=None, right_eye=None,
                                     lips=None, nose=None), False
    return None, False


def run_case(key: str, label: str, source: str, look: str, branch: str, official: bool):
    src = os.path.join(TESTDATA, source)
    if not os.path.isfile(src):
        print(f"  [跳过] 找不到源图 {src}")
        return None
    rgb = load(src)
    started = time.time()
    if branch == "portrait":
        face, is_official = face_geometry(source)
        if face is None:
            print("  [跳过] 人像分支但没有脸框")
            return None
        result = pipeline.retouch_portrait(rgb, face, look=look)
        analysis = portrait.analyze(rgb, face)
        skin_soft = analysis.skin
        face_note = "官方 faces.json" if is_official else "估算脸框（非官方元数据）"
    else:
        result = pipeline.retouch_scene(rgb, look=look)
        skin_soft = np.ones(rgb.shape[:2], dtype=np.float32)
        face_note = "—"
    elapsed = time.time() - started

    out_before = os.path.join(OUT_DIR, f"{key}_before.jpg")
    out_after = os.path.join(OUT_DIR, f"{key}_after.jpg")
    save(out_before, rgb)
    save(out_after, result.image)

    metrics = dict(result.report.metrics)
    scene_mode = branch == "scene"
    passed, problems = judge(metrics, scene=scene_mode)
    coverage = float((skin_soft > 0.6).mean())

    print(f"\n### {label}  ({key})")
    print(f"    源图 {source} · look={look} · 分支={branch} · 脸框={face_note} · "
          f"肤色覆盖 {coverage*100:.1f}% · 耗时 {elapsed:.1f}s")
    print_table(metrics, scene=scene_mode)
    print(f"    结论：{'通过' if passed else '未通过'}")
    for line in problems:
        print("      - " + line)

    return {
        "key": key, "label": label, "source": source, "look": look, "branch": branch,
        "seconds": round(elapsed, 2), "passed": passed, "problems": problems,
        "skin_coverage": round(coverage, 4), "face_note": face_note,
        "metrics": {k: round(float(v), 4) for k, v in metrics.items()},
        "before": out_before, "after": out_after,
    }


def contact_sheet(rows: list[dict], path: str, tile_h: int = 420) -> None:
    tiles = []
    for row in rows:
        try:
            before = Image.open(row["before"]).convert("RGB")
            after = Image.open(row["after"]).convert("RGB")
        except OSError:
            continue
        w, h = after.size
        nw = max(1, int(w * tile_h / h))
        pair = Image.new("RGB", (nw * 2 + 6, tile_h), (18, 18, 18))
        pair.paste(before.resize((nw, tile_h), Image.LANCZOS), (0, 0))
        pair.paste(after.resize((nw, tile_h), Image.LANCZOS), (nw + 6, 0))
        tiles.append((pair, row["label"], row["look"]))
    if not tiles:
        return
    width = sum(t[0].size[0] for t in tiles) + 10 * (len(tiles) - 1)
    canvas = Image.new("RGB", (width, tile_h + 40), (18, 18, 18))
    draw = ImageDraw.Draw(canvas)
    x = 0
    for im, label, look in tiles:
        canvas.paste(im, (x, 40))
        draw.text((x + 6, 22), f"{label}  [{look}]   before | after", fill=(238, 238, 238))
        x += im.size[0] + 10
    canvas.save(path, quality=90)
    print(f"\ncontact sheet: {path}  {canvas.size}")


def main() -> int:
    parser = argparse.ArgumentParser(description="多类型精修回归矩阵")
    parser.add_argument("--only", default="", help="只跑某些 key，逗号分隔")
    args = parser.parse_args()
    wanted = [k.strip() for k in args.only.split(",") if k.strip()]

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"源图目录：{os.path.abspath(TESTDATA)}")
    print(f"输出目录：{OUT_DIR}")

    rows = []
    for key, label, source, look, branch, official in CASES:
        if wanted and key not in wanted:
            continue
        row = run_case(key, label, source, look, branch, official)
        if row:
            rows.append(row)

    if rows:
        with open(os.path.join(OUT_DIR, "report.json"), "w", encoding="utf-8") as fh:
            json.dump(rows, fh, ensure_ascii=False, indent=2)
        contact_sheet(rows, os.path.join(OUT_DIR, "matrix.jpg"))

    total = len(rows)
    passed = sum(1 for r in rows if r["passed"])
    print(f"\n== 汇总：{passed}/{total} 类通过 ==")
    for r in rows:
        flag = "PASS" if r["passed"] else "FAIL"
        print(f"  {flag}  {r['label']:<18} look={r['look']:<20} {r['seconds']:>5.1f}s")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
