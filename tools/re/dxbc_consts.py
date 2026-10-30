#!/usr/bin/env python3
"""
dxbc_consts.py — 从 Camera Raw.8bi 的 DXBC SHEX 里挖立即数浮点常量。

没有 fxc/dxc 做反汇编时，用"短十进制可表示"做筛子：
随机 float32 只有几个百分点能写成 6 位有效数字还完全相等，
所以能过筛的基本都是 shader 里写死的常量（0.92 / 0.25 / 0.001 这类）。

输出：
  dxbc_consts.csv      每张着色器：uniform 结构名 + 挖到的常量
  dxbc_const_family.md 关键家族（dehaze / clarity / sharpen / denoise）的常量表
"""
import os
import struct
import sys
import csv
from collections import defaultdict

TARGET = r"C:\Program Files\Common Files\Adobe\Plug-Ins\CC\File Formats\Camera Raw.8bi"
WS = r"D:\360MoveData\Users\Dell\Documents\deepseek-harness\default-workspace\acr_re"
KEYWORDS = ("Dehaze", "LocalContrast", "Sharpen", "Denoise", "Texture", "Glow",
            "Vignette", "Grain", "SplitTone", "HSLTuner", "LuminanceTuner",
            "ToneMap", "RGBCurve", "LumaCurve", "LocalHue", "BoxBlur", "MinFilter",
            "DarkChannel", "OutputSharpen", "Pyramid")


def is_clean_float(v):
    if not (v == v):          # NaN
        return False
    if v in (0.0,):
        return False
    av = abs(v)
    if av < 1e-7 or av > 1e5:
        return False
    s = "%.6g" % v
    try:
        back = float(s)
    except ValueError:
        return False
    return abs(back - v) <= max(1e-9, av * 1e-6)


def parse_chunks(buf, off):
    if buf[off:off + 4] != b"DXBC":
        return None
    total, nchunk = struct.unpack_from("<II", buf, off + 24)
    if not (32 <= total <= 4_000_000) or nchunk > 64:
        return None
    out = {}
    for i in range(nchunk):
        p = off + 32 + i * 4
        if p + 4 > len(buf):
            return None
        (coff,) = struct.unpack_from("<I", buf, p)
        start = off + coff
        if start + 8 > len(buf):
            return None
        fourcc = buf[start:start + 4].decode("latin1")
        (size,) = struct.unpack_from("<I", buf, start + 4)
        out[fourcc] = (start + 8, size)
    return total, out


def strings_of(b):
    out = []
    cur = bytearray()
    for c in b:
        if 32 <= c < 127:
            cur.append(c)
        else:
            if len(cur) >= 3:
                out.append(cur.decode("latin1"))
            cur = bytearray()
    if len(cur) >= 3:
        out.append(cur.decode("latin1"))
    return out


def main():
    raw = open(TARGET, "rb").read()
    print(f"[+] file {len(raw):,} bytes")

    # 复用上一轮已经切好的 DXBC 偏移表
    import json
    idx_path = os.path.join(WS, "d_dxbc.json")
    blobs = json.load(open(idx_path, encoding="utf-8"))
    print(f"[+] shaders from d_dxbc.json: {len(blobs)}")

    rows = []
    family = defaultdict(lambda: defaultdict(int))

    for b in blobs:
        off = b["offset"]
        parsed = parse_chunks(raw, off)
        if not parsed:
            continue
        total, chunks = parsed
        rdef = chunks.get("RDEF")
        shex = chunks.get("SHEX") or chunks.get("SHDR")
        if not rdef or not shex:
            continue
        rdef_body = raw[rdef[0]:rdef[0] + rdef[1]]
        uniforms = [s for s in strings_of(rdef_body) if s.startswith("Uniforms")]
        name = ",".join(sorted(set(uniforms))[:4]) or "(none)"

        body = raw[shex[0]:shex[0] + shex[1]]
        consts = defaultdict(int)
        n = len(body) // 4
        for i in range(n):
            (bits,) = struct.unpack_from("<I", body, i * 4)
            (v,) = struct.unpack("<f", struct.pack("<I", bits))
            if is_clean_float(v):
                consts[v] += 1
        # 去掉明显的重复桶（同一常量在 shader 里被多次引用是正常的，保留计数）
        cs = sorted(consts.items(), key=lambda kv: -kv[1])
        rows.append({
            "name": name,
            "offset": off,
            "size": total,
            "consts": cs,
        })
        for key in KEYWORDS:
            if any(key.lower() in u.lower() for u in uniforms):
                for v, c in cs:
                    family[key][v] += c

    # ---- CSV ----
    csv_path = os.path.join(WS, "dxbc_consts.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["offset", "size", "uniforms", "top_constants"])
        for r in rows:
            top = " ".join("%g(x%d)" % (v, c) for v, c in r["consts"][:24])
            w.writerow([f"0x{r['offset']:08X}", r["size"], r["name"], top])
    print(f"[+] wrote {csv_path}  ({len(rows)} shaders)")

    # ---- 家族汇总 ----
    md = os.path.join(WS, "dxbc_const_family.md")
    with open(md, "w", encoding="utf-8") as f:
        f.write("# 关键着色器家族里的立即数常量\n\n")
        f.write("筛子：float32 且能被 `%.6g` 精确还原（随机浮点几乎过不了）。\n\n")
        for key in KEYWORDS:
            if key not in family:
                continue
            vals = sorted(family[key].items(), key=lambda kv: -kv[1])[:16]
            f.write(f"## {key}\n\n")
            f.write("| 常量 | 出现次数 |\n|---|---|\n")
            for v, c in vals:
                f.write(f"| {v:g} | {c} |\n")
            f.write("\n")
    print(f"[+] wrote {md}")
    print("\n[=] 家族常量预览：")
    for key in ("Dehaze", "LocalContrast", "Sharpen", "Denoise"):
        if key in family:
            vals = sorted(family[key].items(), key=lambda kv: -kv[1])[:10]
            print(f"  {key:14} " + "  ".join(f"{v:g}" for v, _ in vals))


if __name__ == "__main__":
    main()
