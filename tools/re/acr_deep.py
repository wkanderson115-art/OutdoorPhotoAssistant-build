#!/usr/bin/env python3
"""acr_deep.py — Camera Raw.8bi 深度静态扫描（流式，不占内存，结果落文件）"""
import os, re, sys, json, struct, hashlib
import pefile

TARGET = r"C:\Program Files\Common Files\Adobe\Plug-Ins\CC\File Formats\Camera Raw.8bi"
OUT = os.path.dirname(os.path.abspath(__file__))

KW = ["clarity", "texture", "dehaze", "haze", "vibrance", "saturation", "tonemap",
      "tonecurve", "tone_curve", "luminance", "sharpen", "unsharp", "demosaic",
      "wavelet", "bilateral", "guided", "detail", "noise", "profile", "pipeline",
      "kernel", "shader", "hlsl", "dxbc", "dxil", "compute", "dispatch", "mask",
      "linearize", "gamma", "whitepoint", "blackpoint", "huesat", "colormatrix",
      "opcode", "localcontrast", "detailcontrast", "highlight", "shadow",
      "cameraraw", "crs:", "ProcessVersion"]
KW_B = [k.encode() for k in KW]
INT_RES = [(b"dxbc", "DXBC"), (b"dxil", "DXIL"), (b"cso\x00", "CSO"),
           (b"onnx", "ONNX"), (b".tflite", "TFLITE"), (b"snpe", "SNPE"),
           (b"directml", "DML"), (b"openvino", "OV")]
RTTI = re.compile(rb"\.\?A[VU][^\x00]{3,120}@@")
# 连续可打印 ASCII 片段
ASCII_RUN = re.compile(rb"[\x20-\x7e]{6,}")
# UTF-16LE
UTF16_RUN = re.compile(rb"(?:[\x20-\x7e]\x00){6,}")
# PE 里 DXBC 容器头: "DXBC" + 16字节 checksum 后跟版本
CHUNK = 8 << 20
OVER = 512

def main():
    size = os.path.getsize(TARGET)
    md5 = hashlib.md5(open(TARGET, "rb").read()).hexdigest()
    pe = pefile.PE(TARGET, fast_load=False)
    secs = [(s.Name.rstrip(b"\x00").decode(), s.VirtualAddress,
             s.PointerToRawData, s.SizeOfRawData, s.get_entropy()) for s in pe.sections]

    imgbase = pe.OPTIONAL_HEADER.ImageBase
    exports = []
    exp = getattr(pe, "DIRECTORY_ENTRY_EXPORT", None)
    if exp:
        for s in exp.symbols:
            exports.append((s.address, s.name.decode(errors="ignore") if s.name else str(s.ordinal)))
    imports = {}
    for e in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []):
        dll = e.dll.decode(errors="ignore")
        imports[dll] = [i.name.decode(errors="ignore") for i in e.imports if i.name]
    pdb = ""
    try:
        pdb = pe.DIRECTORY_ENTRY_DEBUG[0].entry.PdbFileName.decode(errors="ignore").strip("\x00")
    except Exception:
        pass

    kw_hits = {k: 0 for k in KW}
    kw_ctx = []
    rtti_hits = set()
    magic_hits = {}
    strings_keep = set()

    with open(TARGET, "rb") as f:
        off = 0
        buf = b""
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            data = buf + chunk
            for m in RTTI.finditer(data):
                rtti_hits.add(m.group(0).decode("latin1"))
            for m in ASCII_RUN.finditer(data):
                s = m.group(0)
                strings_keep.add(s)
            for m in UTF16_RUN.finditer(data):
                try:
                    strings_keep.add(m.group(0).decode("utf-16-le").encode("latin1"))
                except Exception:
                    pass
            for pat, name in INT_RES:
                if pat in data.lower():
                    magic_hits.setdefault(name, 0)
                    magic_hits[name] += data.lower().count(pat)
            low = data.lower()
            for kb in KW_B:
                c = low.count(kb)
                if c:
                    kw_hits[kb.decode()] = kw_hits.get(kb.decode(), 0) + c
                    if len(kw_ctx) < 40000:
                        i = 0
                        while len(kw_ctx) < 40000:
                            j = low.find(kb, i)
                            if j < 0:
                                break
                            a = data.rfind(b"\x00", max(0, j - 80), j)
                            b = data.find(b"\x00", j, j + 120)
                            if b > 0:
                                seg = data[a + 1:b]
                                if 6 <= len(seg) <= 160:
                                    kw_ctx.append((off - len(buf) + j, seg.decode("latin1")))
                            i = j + 1
            off += len(chunk)
            buf = data[-OVER:]

    # ---- 落盘 ----
    def dump(name, lines):
        p = os.path.join(OUT, name)
        with open(p, "w", encoding="utf-8", errors="ignore") as fh:
            fh.writelines(l + "\n" for l in lines)
        return p, len(lines)

    rtti_lines = sorted(rtti_hits)
    p1, n1 = dump("d_rtti.txt", rtti_lines)
    p2, n2 = dump("d_exports.txt", [f"0x{a:08X}\t{s}" for a, s in exports])
    imp_lines = [f"{dll}: {', '.join(syms)}" for dll, syms in imports.items()]
    p3, n3 = dump("d_imports.txt", imp_lines)
    # 关键字上下文去重
    seen = set(); ctx_lines = []
    for offv, s in kw_ctx:
        key = s[:90]
        if key in seen:
            continue
        seen.add(key)
        ctx_lines.append(f"0x{offv:08X}\t{s}")
    p4, n4 = dump("d_kw_context.txt", ctx_lines)
    # 只保留带算法/模块语义的字符串
    interesting = [s for s in strings_keep
                   if len(s) < 200 and re.search(
                       rb"(?i)clarity|texture|dehaze|sharpen|noise|detail|mask|"
                       rb"tonecurve|curve|huesat|colormatrix|profile|kernel|shader|"
                       rb"pipeline|demosaic|wavelet|bilateral|vibrance|luminance", s)]
    p5, n5 = dump("d_interesting_strings.txt",
                  [s.decode("latin1", "ignore") for s in sorted(interesting)])

    summary = {
        "file": TARGET, "size": size, "md5": md5,
        "machine": f"0x{pe.FILE_HEADER.Machine:04X}",
        "timestamp": f"0x{pe.FILE_HEADER.TimeDateStamp:08X}",
        "imagebase": f"0x{imgbase:X}",
        "pdb": pdb,
        "sections": [{"name": n, "va": f"0x{v:X}", "raw": r, "entropy": round(e, 2)}
                     for n, v, r, sz, e in secs],
        "exports_count": len(exports),
        "imports_dll_count": len(imports),
        "rtti_classes": len(rtti_lines),
        "kw_hits": {k: v for k, v in sorted(kw_hits.items(), key=lambda x: -x[1]) if v},
        "magic_hits": magic_hits,
        "files": {"rtti": p1, "exports": p2, "imports": p3, "kwctx": p4, "strings": p5},
        "counts": {"rtti": n1, "exports": n2, "imports": n3, "kwctx": n4, "strings": n5},
    }
    json.dump(summary, open(os.path.join(OUT, "d_summary.json"), "w", encoding="utf-8"),
              indent=1, ensure_ascii=False)
    print(json.dumps(summary, indent=1, ensure_ascii=False)[:6000])

if __name__ == "__main__":
    main()
