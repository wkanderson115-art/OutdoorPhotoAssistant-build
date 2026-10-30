#!/usr/bin/env python3
"""acr_parity.py — 用 Python 复算 ACRDevelopEngine 的关键公式，产出 Swift 测试的参考值，
并顺手校验 tests/acrdevelop/main.swift 里手搓的那段 DCP TIFF 字节是否真能被解析。
"""
import struct, math

# ---------- 1. 手搓 DCP 的字节自检（和 Swift 测试里的构造逐字节一致） ----------
def build_dcp_bytes():
    body = bytearray()
    body += b"II\x2a\x00"            # TIFF little-endian
    body += struct.pack("<I", 8)     # IFD0 offset
    body += struct.pack("<H", 2)     # 2 entries
    # ProfileName 0xC6F8 ASCII count=5 offset=74
    body += struct.pack("<HHI", 0xC6F8, 2, 5) + struct.pack("<I", 74)
    # ColorMatrix1 0xC621 SRATIONAL count=9 offset=80
    body += struct.pack("<HHI", 0xC621, 10, 9) + struct.pack("<I", 80)
    body += struct.pack("<I", 0)     # next IFD
    while len(body) < 74:
        body.append(0)
    body += b"Test\x00"
    while len(body) < 80:
        body.append(0)
    for num, den in [(1,1),(0,1),(0,1),(0,1),(1,1),(0,1),(0,1),(0,1),(1,1)]:
        body += struct.pack("<ii", num, den)
    return bytes(body)

def parse_dcp(data):
    if data[:2] == b"II":
        e = "<"
    elif data[:2] == b"MM":
        e = ">"
    else:
        return None
    ifd = struct.unpack_from(e + "I", data, 4)[0]
    count = struct.unpack_from(e + "H", data, ifd)[0]
    out = {"name": "", "colorMatrix1": []}
    for i in range(count):
        p = ifd + 2 + i * 12
        tag, typ, n = struct.unpack_from(e + "HHI", data, p)
        size = {1:1,2:1,3:2,4:4,5:8,6:1,7:1,8:2,9:4,10:8,11:4,12:8}[typ] * n
        off = p + 8 if size <= 4 else struct.unpack_from(e + "I", data, p + 8)[0]
        if tag == 0xC6F8:
            out["name"] = data[off:off+n].split(b"\x00")[0].decode("latin1")
        elif tag == 0xC621 and typ == 10:
            vals = []
            for k in range(n):
                num, den = struct.unpack_from(e + "ii", data, off + k*8)
                vals.append(num / den if den else 0.0)
            out["colorMatrix1"] = vals
    return out

# ---------- 2. 引擎公式复算 ----------
def encode(x):
    x = min(1.0, max(0.0, x))
    return 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1/2.4) - 0.055

def decode(x):
    x = min(1.0, max(0.0, x))
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4

def contrast_value(x, pivot=0.5, slope=2.2):
    d = x - pivot
    k = max(slope - 1.0, 0.0)
    y = d * slope / (1.0 + abs(d) * k * 1.6)
    return min(1.0, max(0.0, pivot + y))

def endpoint_value(x, black=0.0225, white=1.0):
    return min(1.0, max(0.0, (x - black) / max(white - black, 1e-4)))

def maximal_slope(contrast):
    c = min(100.0, max(-100.0, contrast)) / 100.0
    return 1.0 + c * 1.2 if c >= 0 else 1.0 + c * 0.6

def fristsch_carlson(points, x):
    pts = sorted(points)
    n = len(pts)
    d = [(pts[i+1][1] - pts[i][1]) / max(1e-6, pts[i+1][0] - pts[i][0]) for i in range(n-1)]
    m = [0.0] * n
    m[0] = d[0]; m[n-1] = d[-2]
    for i in range(1, n-1):
        m[i] = (d[i-1] + d[i]) * 0.5
    for i in range(n-1):
        if d[i] == 0:
            m[i] = 0.0; m[i+1] = 0.0
        else:
            a = m[i] / d[i]; b = m[i+1] / d[i]
            h = 3.0 / math.hypot(a, b) if (a*a + b*b) > 9 else 1.0
            m[i] = h * a * d[i]; m[i+1] = h * b * d[i]
    if x <= pts[0][0]:
        return min(1, max(0, pts[0][1] + (x - pts[0][0]) * m[0]))
    if x >= pts[n-1][0]:
        return min(1, max(0, pts[n-1][1] + (x - pts[n-1][0]) * m[-1]))
    seg = 0
    while seg < n - 2 and x > pts[seg+1][0]:
        seg += 1
    h = max(1e-6, pts[seg+1][0] - pts[seg][0])
    t = (x - pts[seg][0]) / h
    t2, t3 = t*t, t*t*t
    h00 = 2*t3 - 3*t2 + 1
    h10 = t3 - 2*t2 + t
    h01 = -2*t3 + 3*t2
    h11 = t3 - t2
    v = h00*pts[seg][1] + h10*h*m[seg] + h01*pts[seg+1][1] + h11*h*m[seg+1]
    return min(1, max(0, v))

def guided_filter_1d(signal, radius, eps):
    """1D 版引导滤波（guide=src），只为验证 a/b 编码数学与引擎实现一致。"""
    n = len(signal)
    def box(arr, r):
        out = []
        for i in range(n):
            lo = max(0, i - r); hi = min(n, i + r + 1)
            out.append(sum(arr[lo:hi]) / (hi - lo))
        return out
    mI = box(signal, radius)
    mII = box([v*v for v in signal], radius)
    a = [(mII[i] - mI[i]*mI[i]) / max(mII[i] - mI[i]*mI[i], 0.0) + 0.0 for i in range(n)]
    # 自引导且无噪声时 var≈0，直接给解析对照
    return mI, mII

def main():
    print("== 1. 手搓 DCP 字节解析自检 ==")
    data = build_dcp_bytes()
    p = parse_dcp(data)
    print("   bytes =", len(data), "name =", p["name"], "matrix =", p["colorMatrix1"])
    ok = p["name"] == "Test" and len(p["colorMatrix1"]) == 9 \
        and abs(p["colorMatrix1"][0] - 1.0) < 1e-9 and abs(p["colorMatrix1"][8] - 1.0) < 1e-9
    print("   ->", "OK" if ok else "BROKEN（Swift 测试里的 DCP 断言会失败）")

    print("\n== 2. 曝光参考值（sRGB 0.5 进） ==")
    lin = decode(0.5)
    for ev in (-1.0, 1.0, 2.0):
        print("   EV %+0.1f -> %.4f" % (ev, encode(lin * 2 ** ev)))

    print("\n== 3. 对比度参考值（slope=%.2f） ==" % maximal_slope(100))
    s100 = maximal_slope(100)
    print("   0.40 -> %.4f   0.60 -> %.4f   diff = %.4f"
          % (contrast_value(0.4, 0.5, s100), contrast_value(0.6, 0.5, s100),
             contrast_value(0.6, 0.5, s100) - contrast_value(0.4, 0.5, s100)))
    print("   slope(-100) = %.2f" % maximal_slope(-100))

    print("\n== 4. 端点参考值（blacks +15） ==")
    print("   0.5 -> %.4f" % endpoint_value(0.5, 0.15 * 0.15, 1.0))

    print("\n== 5. 点曲线参考值（(0,0)(0.5,0.62)(1,1)） ==")
    pts = [(0.0, 0.0), (0.5, 0.62), (1.0, 1.0)]
    for x in (0.0, 0.25, 0.5, 0.75, 1.0):
        print("   tone(%.2f) = %.4f" % (x, fristsch_carlson(pts, x)))
    mono = all(fristsch_carlson(pts, i/100) <= fristsch_carlson(pts, (i+1)/100) + 1e-9
               for i in range(100))
    print("   monotone =", mono)

    print("\n== 6. 引导滤波 a/b 编码的数值范围 ==")
    # 典型 var/eps 下的 a 值，确认 0.5+0.25a 不会溢出 [0,1]
    for var, eps in [(0.0, 1e-3), (1e-4, 1e-3), (0.01, 1e-3), (0.04, 2.5e-2)]:
        a = var / (var + eps)
        print("   var=%.5f eps=%.4f -> a=%.4f code=%.4f" % (var, eps, a, 0.5 + 0.25 * a))
    print("   b 的范围：|b| <= 1 时 code in [0.25, 0.75]，安全")

if __name__ == "__main__":
    main()
