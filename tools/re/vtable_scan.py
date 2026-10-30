#!/usr/bin/env python3
"""
vtable_scan.py — 从 Camera Raw.8bi 里把 cr_stage_* 的 vtable 与虚函数地址挖出来。

不依赖 Ghidra/IDA，只用 PE 结构：
  1. 扫 .rdata 找 MSVC TypeDescriptor（名字在 TD+16）
  2. 找 CompleteObjectLocator：signature=1 且 pTypeDescriptor(RVA) 指向该 TD
  3. vtable[-1] 存的是 COL 的绝对地址（ImageBase + COL_RVA），据此定位 vtable
  4. 顺着一串函数指针读到 NULL 为止

输出：
  stage_vtables.csv          —— stage 名 / vtable RVA / 虚函数 RVA 列表
  ghidra_rename_stages.py    —— 丢进 Ghidra Script Manager 一键给函数改名
"""
import os
import struct
import sys
import csv

import numpy as np
import pefile

TARGET = sys.argv[1] if len(sys.argv) > 1 else \
    r"C:\Program Files\Common Files\Adobe\Plug-Ins\CC\File Formats\Camera Raw.8bi"
OUT = r"D:\360MoveData\Users\Dell\Documents\deepseek-harness\default-workspace\acr_re"

TD_PREFIX = b".?AVcr_stage_"
MAX_VFUNC = 64


def load():
    pe = pefile.PE(TARGET, fast_load=True)
    image_base = pe.OPTIONAL_HEADER.ImageBase
    raw = open(TARGET, "rb").read()
    secs = []
    for s in pe.sections:
        name = s.Name.rstrip(b"\x00").decode(errors="ignore")
        secs.append({
            "name": name,
            "va": s.VirtualAddress,
            "raw_off": s.PointerToRawData,
            "raw_size": s.SizeOfRawData,
            "vsize": s.Misc_VirtualSize,
        })
    return pe, image_base, raw, secs


def rva_to_off(secs, rva):
    for s in secs:
        start = s["va"]
        end = start + max(s["raw_size"], s["vsize"])
        if start <= rva < end:
            delta = rva - start
            if delta < s["raw_size"]:
                return s["raw_off"] + delta
    return None


def main():
    pe, image_base, raw, secs = load()
    print(f"[+] image base 0x{image_base:X}  file {len(raw):,} bytes")

    # --- 1. 找所有 cr_stage_* 的 TypeDescriptor ---
    td_map = {}   # name -> TD RVA
    pos = 0
    while True:
        i = raw.find(TD_PREFIX, pos)
        if i < 0:
            break
        pos = i + 1
        end = raw.find(b"\x00", i)
        if end < 0:
            continue
        name = raw[i:end].decode("latin1")
        # TypeDescriptor 的 name 字段在 TD+16，所以 TD RVA = 该字符串文件偏移 - 16
        td_file_off = i - 16
        if td_file_off < 0:
            continue
        # 反查 TD 的 RVA
        td_rva = None
        for s in secs:
            if s["raw_off"] <= td_file_off < s["raw_off"] + s["raw_size"]:
                td_rva = s["va"] + (td_file_off - s["raw_off"])
                break
        if td_rva is None:
            continue
        td_map[name] = td_rva
    print(f"[+] stage TypeDescriptors: {len(td_map)}")

    # --- 2. 扫 COL：signature=1, offset=0, cdOffset=0, pTypeDescriptor=td_rva ---
    # COL 布局（x64，RVA 形式）：u32 sig, u32 offset, u32 cdOffset, u32 tdRVA, u32 chdRVA
    col_rva = {}     # col_rva -> stage name
    td_to_name = {v: k for k, v in td_map.items()}
    for sec in secs:
        if sec["name"] not in (".rdata", "_RDATA", ".data"):
            continue
        base_off = sec["raw_off"]
        base_rva = sec["va"]
        size = sec["raw_size"]
        chunk = raw[base_off:base_off + size]
        arr = np.frombuffer(chunk[: (len(chunk) // 4) * 4], dtype="<u4")
        if arr.size < 5:
            continue
        sig = arr[:-4] == 1
        td = arr[3:-1]
        mask = sig.copy()
        # 只保留 td 命中 stage 的候选
        targets = np.array(sorted(td_to_name.keys()), dtype="<u4")
        hit = np.isin(td, targets) & mask
        idxs = np.nonzero(hit)[0]
        for idx in idxs:
            rva = base_rva + int(idx) * 4
            td_rva = int(arr[idx + 3])
            name = td_to_name.get(td_rva)
            if name:
                col_rva[rva] = name
    print(f"[+] CompleteObjectLocator hits: {len(col_rva)}")

    # --- 3. 找 vtable：某处 8 字节等于 image_base + col_rva ---
    wanted = {image_base + col: name for col, name in col_rva.items()}
    want_vals = np.array(sorted(wanted.keys()), dtype="<u8")
    vtable_by_name = {}
    for sec in secs:
        if sec["name"] not in (".rdata", "_RDATA", ".data"):
            continue
        chunk = raw[sec["raw_off"]:sec["raw_off"] + sec["raw_size"]]
        arr = np.frombuffer(chunk[: (len(chunk) // 8) * 8], dtype="<u8")
        if arr.size == 0:
            continue
        hits = np.isin(arr, want_vals)
        for idx in np.nonzero(hits)[0]:
            col_abs = int(arr[idx])
            name = wanted.get(col_abs)
            if not name:
                continue
            vt_rva = sec["va"] + int(idx) * 8 + 8
            vtable_by_name.setdefault(name, vt_rva)
    print(f"[+] vtables resolved: {len(vtable_by_name)} / {len(td_map)}")

    # --- 4. 读虚函数指针 ---
    text = next((s for s in secs if s["name"] == ".text"), None)
    if text is None:
        raise SystemExit("no .text section")
    text_lo = image_base + text["va"]
    text_hi = text_lo + max(text["raw_size"], text["vsize"])
    known_vt = set(image_base + r["vt"] for r in
                   [{"vt": v} for v in vtable_by_name.values()])

    rows = []
    for name in sorted(vtable_by_name):
        vt_rva = vtable_by_name[name]
        vt_off = rva_to_off(secs, vt_rva)
        if vt_off is None:
            continue
        funcs = []
        for k in range(MAX_VFUNC):
            o = vt_off + k * 8
            if o + 8 > len(raw):
                break
            ptr = struct.unpack_from("<Q", raw, o)[0]
            # 只认落在 .text 里、且不是"下一个 vtable 起点"的指针
            if ptr < text_lo or ptr >= text_hi or ptr in known_vt:
                break
            funcs.append(ptr - image_base)
        short = name.replace(".?AV", "").replace("@@", "")
        rows.append({
            "stage": short,
            "vtable_rva": vt_rva,
            "vfunc_count": len(funcs),
            "vfuncs": funcs,
        })

    os.makedirs(OUT, exist_ok=True)
    csv_path = os.path.join(OUT, "stage_vtables.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["stage", "vtable_rva", "vfunc_count", "vfunc_rvas"])
        for r in rows:
            w.writerow([r["stage"], f"0x{r['vtable_rva']:X}", r["vfunc_count"],
                        " ".join(f"0x{x:X}" for x in r["vfuncs"])])
    print(f"[+] wrote {csv_path}  ({len(rows)} stages)")

    # --- 5. Ghidra 改名脚本 ---
    ghidra = os.path.join(OUT, "ghidra_rename_stages.py")
    with open(ghidra, "w", encoding="utf-8") as f:
        f.write('''# Ghidra script: rename Camera Raw cr_stage_* virtual functions
# 用法：Ghidra 打开 Camera Raw.8bi（No 分析完成后），Script Manager 运行本脚本。
# 依据：vtable_scan.py 从 RTTI 里解出来的 vtable 布局。
from ghidra.program.model.symbol import SourceType

IMAGE_BASE = %d
TABLE = [
''' % image_base)
        for r in rows:
            f.write('    (%r, 0x%X, [%s]),\n' % (
                r["stage"], r["vtable_rva"],
                ", ".join(f"0x{x:X}" for x in r["vfuncs"])))
        f.write('''
]
listing = currentProgram.getListing()
fm = currentProgram.getFunctionManager()
st = currentProgram.getSymbolTable()

for stage, vt_rva, funcs in TABLE:
    for i, rva in enumerate(funcs):
        addr = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(IMAGE_BASE + rva)
        fn = fm.getFunctionAt(addr)
        name = "%s_v%d" % (stage, i)
        if fn is None:
            try:
                fn = createFunction(addr, name)
            except Exception:
                continue
        try:
            fn.setName(name, SourceType.USER_DEFINED)
        except Exception:
            pass
print("renamed %%d stages" %% len(TABLE))
''')
    print(f"[+] wrote {ghidra}")

    # 统计
    total = sum(len(r["vfuncs"]) for r in rows)
    print(f"\n[=] stages={len(rows)}  total_virtual_functions={total}")
    print(f"{'stage':44} {'vtable':>10} {'#vf':>4}")
    for r in sorted(rows, key=lambda x: -x["vfunc_count"])[:20]:
        print(f"{r['stage']:44} 0x{r['vtable_rva']:08X} {r['vfunc_count']:4d}")


if __name__ == "__main__":
    main()
