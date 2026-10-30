#!/usr/bin/env python3
"""dxbc_dump.py — 从 Camera Raw.8bi 里切出所有 DXBC 着色器并提取 RDEF 里的绑定名/常量名"""
import os, re, sys, json, struct, hashlib

TARGET = sys.argv[1] if len(sys.argv) > 1 else \
    r"C:\Program Files\Common Files\Adobe\Plug-Ins\CC\File Formats\Camera Raw.8bi"
OUT = os.path.dirname(os.path.abspath(__file__))
STR = re.compile(rb"[\x20-\x7e]{3,120}")

BOILER = {"Microsoft (R) HLSL Shader Compiler", "DXBC", "RDEF", "ISGN", "OSGN",
          "SHEX", "SHDR", "STAT", "IFCE", "SFI0", "PSVI"}

def strings_of(blob):
    return [s.decode("latin1") for s in STR.findall(blob) if s not in (b"DXBC",)]

def parse_dxbc(buf, off):
    """解析 DXBC 容器头。头部 offset+32 起是 nchunk 个 u32 偏移表，
    每个 chunk 自身开头为 fourcc(4)+size(4)。"""
    if buf[off:off + 4] != b"DXBC":
        return None
    total, nchunk = struct.unpack_from("<II", buf, off + 24)
    if not (32 <= total <= 4_000_000) or nchunk > 64:
        return None
    chunks = []
    for i in range(nchunk):
        p = off + 32 + i * 4
        if p + 4 > len(buf):
            return None
        (coff,) = struct.unpack_from("<I", buf, p)
        cstart = off + coff
        if cstart + 8 > len(buf):
            return None
        fourcc = buf[cstart:cstart + 4].decode("latin1")
        (csize,) = struct.unpack_from("<I", buf, cstart + 4)
        chunks.append((fourcc, cstart + 8, csize))
    return total, chunks

def main():
    size = os.path.getsize(TARGET)
    found = []
    seen = set()
    with open(TARGET, "rb") as f:
        buf = f.read()
    pos = 0
    while True:
        i = buf.find(b"DXBC", pos)
        if i < 0:
            break
        pos = i + 4
        r = parse_dxbc(buf, i)
        if not r:
            continue
        total, chunks = r
        blob = buf[i:i + total]
        h = hashlib.md5(blob).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        strs = strings_of(blob)
        rdef = [c for c in chunks if c[0] == "RDEF"]
        # 取 RDEF 里的可读标识符（常量缓冲成员名、纹理绑定名、入口名）
        names, cbufs = [], []
        for fourcc, coff, csize in rdef:
            body = buf[coff:coff + csize]
            for s in strings_of(body):
                if "HLSL Shader Compiler" in s or "." in s and len(s) < 6:
                    continue
                names.append(s)
        targets = [s for s in strs if re.match(r"^[a-z]{2}_5_\d$", s)]
        found.append({
            "offset": i, "size": total, "md5": h,
            "chunks": [c[0] for c in chunks],
            "target": targets[:3],
            "rdef_names": sorted(set(names))[:80],
            "all_strings_sample": sorted(set(strs))[:40],
        })
    json.dump(found, open(os.path.join(OUT, "d_dxbc.json"), "w", encoding="utf-8"),
              indent=1, ensure_ascii=False)
    print(f"[dxbc] total={len(found)}  dedup_by_md5")
    tgt = {}
    for f in found:
        for t in f["target"]:
            tgt[t] = tgt.get(t, 0) + 1
    print("[dxbc] targets:", tgt)
    # 汇总 RDEF 标识符，出现频次高的是通用绑定，低频的是专有参数
    from collections import Counter
    c = Counter()
    for f in found:
        for n in f["rdef_names"]:
            c[n] += 1
    generic = {n for n, k in c.items() if k >= len(found) * 0.5}
    specific = [(n, k) for n, k in c.most_common() if n not in generic]
    print(f"\n[dxbc] 通用绑定 ({len(generic)}): {sorted(generic)[:30]}")
    print(f"\n[dxbc] 专有参数/绑定 (top 60):")
    for n, k in specific[:60]:
        print(f"  {k:>4}  {n}")

if __name__ == "__main__":
    main()
