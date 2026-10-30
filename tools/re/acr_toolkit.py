#!/usr/bin/env python3
"""
acr_toolkit.py — Adobe Camera Raw / Lightroom Develop 引擎逆向工具集

用法:
  python acr_toolkit.py xmp  <dir>            # 枚举所有 crs: 精修参数键 + 取值域 + 出现频次
  python acr_toolkit.py dcp  <dir>            # 解析 .dcp 色彩科学: ColorMatrix / ForwardMatrix / ToneCurve / HueSatMap
  python acr_toolkit.py pe   <file.dll|8bi>    # PE 体检: 节表 / 导出 / 导入 / RTTI 类名 / 算法关键字
  python acr_toolkit.py gpu  <dir>            # 扫描目录里的 DXBC/DXIL 着色器 blob 与常量表线索
"""
import os, re, sys, json, struct, glob, collections

# ---------------------------------------------------------------- XMP 参数面
CRS_RE = re.compile(r'crs:([A-Za-z0-9_]+)="([^"]*)"')

def cmd_xmp(root):
    keys = collections.defaultdict(list)
    files = 0
    for path in glob.iglob(os.path.join(root, "**", "*.xmp"), recursive=True):
        files += 1
        try:
            txt = open(path, "r", encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for k, v in CRS_RE.findall(txt):
            keys[k].append(v)
    report = {}
    for k, vals in sorted(keys.items()):
        num = []
        for v in vals:
            try:
                num.append(float(v))
            except ValueError:
                pass
        entry = {"count": len(vals), "sample": vals[0][:80]}
        if num:
            entry.update({"min": min(num), "max": max(num),
                          "distinct": len(set(num))})
        report[k] = entry
    out = os.path.join(os.getcwd(), "_crs_params.json")
    json.dump(report, open(out, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"[xmp] files={files} param_keys={len(report)} -> {out}\n")
    print(f"{'crs:key':38} {'n':>4} {'min':>9} {'max':>9} {'distinct':>8}")
    for k, e in sorted(report.items(), key=lambda x: -x[1]["count"]):
        if e["count"] < 2:
            continue
        print(f"{k:38} {e['count']:>4} {str(e.get('min','')):>9} "
              f"{str(e.get('max','')):>9} {str(e.get('distinct','')):>8}")
    return report

# ---------------------------------------------------------------- DCP / TIFF
DNG_TAGS = {
    0xC612: "DNGVersion", 0xC614: "UniqueCameraModel",
    0xC621: "ColorMatrix1", 0xC622: "ColorMatrix2",
    0xC623: "CameraCalibration1", 0xC624: "CameraCalibration2",
    0xC625: "ReductionMatrix1", 0xC626: "ReductionMatrix2",
    0xC627: "AnalogBalance", 0xC628: "AsShotNeutral", 0xC629: "AsShotWhiteXY",
    0xC62A: "BaselineExposure", 0xC62B: "BaselineNoise",
    0xC62C: "BaselineSharpness", 0xC62F: "LensInfo",
    0xC65A: "CalibrationIlluminant1", 0xC65B: "CalibrationIlluminant2",
    0xC6F3: "CameraCalibrationSig", 0xC6F4: "ProfileCalibrationSig",
    0xC6F6: "AsShotProfileName", 0xC6F8: "ProfileName",
    0xC6F9: "ProfileHueSatMapDims", 0xC6FA: "ProfileHueSatMapData1",
    0xC6FB: "ProfileHueSatMapData2", 0xC6FC: "ProfileToneCurve",
    0xC6FD: "ProfileEmbedPolicy", 0xC6FE: "ProfileCopyright",
    0xC714: "ForwardMatrix1", 0xC715: "ForwardMatrix2",
    0xC71A: "PreviewColorSpace",
}
TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}
TYPE_FMT = {3: "H", 4: "I", 5: "II", 9: "i", 10: "ii", 11: "f", 12: "d"}

def _decode(buf, endian, typ, cnt, off):
    """按 TIFF 类型正确解码；rational 会自动除法归一。"""
    if typ == 2:                                   # ASCII
        return buf[off:off + cnt].split(b"\x00")[0].decode("utf-8", "ignore")
    if typ == 3:
        return list(struct.unpack_from(endian + "H" * cnt, buf, off))
    if typ == 4:
        return list(struct.unpack_from(endian + "I" * cnt, buf, off))
    if typ == 9:
        return list(struct.unpack_from(endian + "i" * cnt, buf, off))
    if typ == 11:
        return list(struct.unpack_from(endian + "f" * cnt, buf, off))
    if typ == 12:
        return list(struct.unpack_from(endian + "d" * cnt, buf, off))
    if typ in (5, 10):                             # URATIONAL / SRATIONAL
        fmt = "I" if typ == 5 else "i"
        raw = struct.unpack_from(endian + fmt * (2 * cnt), buf, off)
        return [raw[2 * i] / raw[2 * i + 1] if raw[2 * i + 1] else 0.0
                for i in range(cnt)]
    return None

def _read_ifd(buf, off, endian, hits, depth=0):
    if depth > 4 or off <= 0 or off + 2 > len(buf):
        return
    n = struct.unpack_from(endian + "H", buf, off)[0]
    subifds = []
    for i in range(n):
        p = off + 2 + i * 12
        if p + 12 > len(buf):
            break
        tag, typ, cnt = struct.unpack_from(endian + "HHI", buf, p)
        total = TYPE_SIZE.get(typ, 1) * cnt
        valoff = p + 8 if total <= 4 else struct.unpack_from(endian + "I", buf, p + 8)[0]
        if typ == 13 or tag == 0xC6F5:              # 子 IFD 指针
            if total <= 4:
                subifds.append(struct.unpack_from(endian + "I", buf, p + 8)[0])
            continue
        if tag not in DNG_TAGS or valoff + total > len(buf):
            continue
        vals = _decode(buf, endian, typ, cnt, valoff)
        if vals is not None:
            hits[DNG_TAGS[tag]] = vals
    for s in subifds:
        _read_ifd(buf, s, endian, hits, depth + 1)

def parse_dcp(path):
    buf = open(path, "rb").read()
    if buf[:2] == b"II":
        endian = "<"
    elif buf[:2] == b"MM":
        endian = ">"
    else:
        return {"error": "not TIFF"}
    ifd0 = struct.unpack_from(endian + "I", buf, 4)[0]
    hits = {}
    _read_ifd(buf, ifd0, endian, hits)
    return hits

def _fmt_matrix(v, rows=3, cols=3, scale=1.0):
    if not v or len(v) < rows * cols:
        return "n/a"
    cells = []
    for r in range(rows):
        cells.append(" ".join(f"{v[r*cols+c]/scale:+.5f}" for c in range(cols)))
    return "  [" + " | ".join(cells) + "]"

def cmd_dcp(root):
    files = sorted(glob.iglob(os.path.join(root, "**", "*.dcp"), recursive=True))
    print(f"[dcp] profiles={len(files)}\n")
    samples = collections.Counter()
    parsed = 0
    for path in files:
        d = parse_dcp(path)
        if "error" in d or not d:
            continue
        parsed += 1
        samples[path] = d
    print(f"parsed_ok={parsed}")
    # 打印 3 个代表样本的完整色彩科学参数
    for path, d in list(samples.items())[:3]:
        print(f"\n=== {os.path.basename(path)}")
        print(" ProfileName   :", d.get("ProfileName"))
        print(" UniqueCamera  :", d.get("UniqueCameraModel"))
        print(" Illuminants   :", d.get("CalibrationIlluminant1"), d.get("CalibrationIlluminant2"))
        print(" ColorMatrix1  :", _fmt_matrix(d.get("ColorMatrix1"), scale=1.0))
        print(" ColorMatrix2  :", _fmt_matrix(d.get("ColorMatrix2"), scale=1.0))
        print(" ForwardMatrix1:", _fmt_matrix(d.get("ForwardMatrix1"), scale=1.0))
        print(" BaselineExp   :", [x / 65536.0 for x in d.get("BaselineExposure", [])] or "n/a")
        hs = d.get("ProfileHueSatMapDims")
        print(" HueSatMapDims :", hs, " (hue entries / sat entries / values per point)")
        tc = d.get("ProfileToneCurve", [])
        print(" ToneCurve     : points =", len(tc) // 2,
              "first =", [round(x, 5) for x in tc[:4]] or "n/a",
              "last =", [round(x, 5) for x in tc[-2:]] or "n/a")
    # 统计分布
    dims = collections.Counter(tuple(d.get("ProfileHueSatMapDims", [])) for d in samples.values())
    print("\n HueSatMapDims 分布:", dict(dims))
    has_fm = sum(1 for d in samples.values() if d.get("ForwardMatrix1"))
    print(f" 含 ForwardMatrix 的 profile: {has_fm}/{len(samples)}")
    return parsed

# ---------------------------------------------------------------- PE 静态体检
KW = re.compile(rb"(?i)(clarity|texture|dehaze|vibrance|tonemap|tonecurve|"
                rb"luminance|saturation|sharpen|unsharp|demosaic|gaussian|"
                rb"wavelet|bilateral|guided|profile|pipeline|kernel|shader|"
                rb"hlsl|dxbc|dxil|compute|dispatch|mask|linearize|gamma|"
                rb"whitepoint|blackpoint|huesat|colormatrix|opcode)")

def cmd_pe(path):
    try:
        import pefile
    except ImportError:
        print("[pe] need: pip install pefile"); return
    pe = pefile.PE(path, fast_load=False)
    print(f"[pe] {path}")
    print(f" machine=0x{pe.FILE_HEADER.Machine:04X} ts=0x{pe.FILE_HEADER.TimeDateStamp:08X}")
    try:
        print(f" pdb={pe.DIRECTORY_ENTRY_DEBUG[0].entry.PdbFileName.decode(errors='ignore')}")
    except Exception:
        pass
    print("\n sections:")
    for s in pe.sections:
        name = s.Name.rstrip(b"\x00").decode(errors="ignore")
        print(f"  {name:10} va=0x{s.VirtualAddress:08X} raw={s.SizeOfRawData:>10} "
              f"entropy={s.get_entropy():.2f}")
    exp = getattr(pe, "DIRECTORY_ENTRY_EXPORT", None)
    if exp:
        syms = exp.symbols
        print(f"\n exports: {len(syms)}")
        for s in syms[:40]:
            print(f"  0x{s.address:08X} {s.name.decode(errors='ignore') if s.name else s.ordinal}")
    imp = getattr(pe, "DIRECTORY_ENTRY_IMPORT", None)
    if imp:
        print("\n imported dlls:", ", ".join(e.dll.decode(errors="ignore") for e in imp))
        d3d = [e.dll.decode(errors="ignore") for e in imp
               if re.search(rb"(?i)d3d|dxgi|compiler|cuda|opencl|directml|onnx", e.dll)]
        if d3d:
            print(" GPU/AI 相关依赖:", d3d)
    # 关键字字符串 + 地址
    data = open(path, "rb").read()
    print("\n alg keyword hits (str -> count):")
    counts = collections.Counter(m.group(0).lower() for m in KW.finditer(data))
    for k, c in counts.most_common(40):
        print(f"  {k.decode():14} {c}")
    # 浮点常量表: 找 0.299/0.587/0.114 这类 luma 系数相邻出现
    print("\n float triples (luma/color constants):")
    pats = [(0.299, 0.587, 0.114), (0.2126, 0.7152, 0.0722), (0.04045, 0.0031308)]
    for a, b, c in pats:
        blob = struct.pack("<fff", a, b, c)
        idx = data.find(blob)
        print(f"  {(a,b,c)} -> {'0x%X' % idx if idx >= 0 else 'not found'}")

# ---------------------------------------------------------------- GPU 着色器
def cmd_gpu(root):
    found = 0
    for path in glob.iglob(os.path.join(root, "**", "*"), recursive=True):
        if not os.path.isfile(path):
            continue
        try:
            if os.path.getsize(path) < 64:
                continue
            buf = open(path, "rb").read(4 * 1024 * 1024)
        except OSError:
            continue
        hits = []
        for magic in (b"DXBC", b"DXIL", b"cso\x00", b"SHDR", b"\x01\x00\x00\x00DX"):
            i = buf.find(magic)
            if i >= 0:
                hits.append((magic.decode(errors="ignore"), i))
        if hits:
            found += 1
            print(f"{os.path.getsize(path):>12}  {path}  {hits}")
    print(f"\n[gpu] blobs found in {found} files")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    mode, target = sys.argv[1], sys.argv[2]
    if mode == "xmp":
        cmd_xmp(target)
    elif mode == "dcp":
        cmd_dcp(target)
    elif mode == "pe":
        cmd_pe(target)
    elif mode == "gpu":
        cmd_gpu(target)
    else:
        print(__doc__)
