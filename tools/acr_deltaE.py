#!/usr/bin/env python3
"""
acr_deltaE.py — 把本引擎输出和 Lightroom/Camera Raw 导出图逐像素对表。

用法：
    python tools/acr_deltaE.py ours.png lr_export.png
    python tools/acr_deltaE.py ours.png lr_export.png --mask skin.png

输出：
    ΔE76 / ΔE2000 的 mean / p95 / max、PSNR、平均绝对差、超阈值像素占比

依赖：numpy（PNG 解码自己用 zlib 做，不依赖 Pillow）
支持：8bit RGB / RGBA，非隔行 PNG
"""
import struct
import sys
import zlib

import numpy as np


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: " + path)
    pos = 8
    w = h = bit = ctype = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack_from(">I", data, pos)
        ctag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctag == b"IHDR":
            w, h, bit, ctype, comp, filt, inter = struct.unpack(">IIBBBBB", body)
            if bit != 8 or inter != 0 or ctype not in (2, 6):
                raise ValueError(f"unsupported PNG (bit={bit} color={ctype} interlace={inter})")
        elif ctag == b"IDAT":
            idat += body
        elif ctag == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    channels = 3 if ctype == 2 else 4
    stride = w * channels
    out = np.zeros((h, stride), dtype=np.uint8)
    prev = np.zeros(stride, dtype=np.int32)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = np.frombuffer(raw[p:p + stride], dtype=np.uint8).astype(np.int32)
        p += stride
        if ft == 0:
            cur = line
        elif ft == 1:                       # Sub
            cur = line.copy()
            for i in range(channels, stride):
                cur[i] = (cur[i] + cur[i - channels]) & 0xFF
        elif ft == 2:                       # Up
            cur = (line + prev) & 0xFF
        elif ft == 3:                       # Average
            cur = line.copy()
            for i in range(stride):
                left = cur[i - channels] if i >= channels else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:                       # Paeth
            cur = line.copy()
            for i in range(stride):
                a = cur[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 0xFF
        else:
            raise ValueError("bad filter " + str(ft))
        out[y] = cur.astype(np.uint8)
        prev = cur
    img = out.reshape(h, w, channels)[:, :, :3].astype(np.float64) / 255.0
    return img


def srgb_to_lab(rgb):
    """sRGB(0..1) → CIE Lab (D65)"""
    m = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    r, g, b = m[..., 0], m[..., 1], m[..., 2]
    x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
    wn = np.array([0.95047, 1.0, 1.08883])
    xyz = np.stack([x, y, z], -1) / wn
    d = 6.0 / 29.0
    f = np.where(xyz > d ** 3, np.cbrt(xyz), xyz / (3 * d * d) + 4.0 / 29.0)
    L = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    bb = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, bb], -1)


def delta_e76(lab1, lab2):
    return np.sqrt(np.sum((lab1 - lab2) ** 2, axis=-1))


def delta_e2000(lab1, lab2):
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1 = np.hypot(a1, b1)
    C2 = np.hypot(a2, b2)
    Cbar = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cbar ** 7 / (Cbar ** 7 + 25.0 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1
    dCp = C2p - C1p
    dhp = h2p - h1p
    dhp = np.where(dhp > 180, dhp - 360, np.where(dhp < -180, dhp + 360, dhp))
    dhp = np.where(C1p * C2p == 0, 0, dhp)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp) / 2)
    Lbar = (L1 + L2) / 2
    Cbarp = (C1p + C2p) / 2
    hsum = h1p + h2p
    hbar = np.where(np.abs(h1p - h2p) <= 180, hsum / 2, np.where(hsum < 360, (hsum + 360) / 2, (hsum - 360) / 2))
    T = (1 - 0.17 * np.cos(np.radians(hbar - 30))
         + 0.24 * np.cos(np.radians(2 * hbar))
         + 0.32 * np.cos(np.radians(3 * hbar + 6))
         - 0.20 * np.cos(np.radians(4 * hbar - 63)))
    dTheta = 30 * np.exp(-((hbar - 275) / 25) ** 2)
    Rc = 2 * np.sqrt(Cbarp ** 7 / (Cbarp ** 7 + 25.0 ** 7))
    Sl = 1 + (0.015 * (Lbar - 50) ** 2) / np.sqrt(20 + (Lbar - 50) ** 2)
    Sc = 1 + 0.045 * Cbarp
    Sh = 1 + 0.015 * Cbarp * T
    Rt = -np.sin(np.radians(2 * dTheta)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2
                   + Rt * (dCp / Sc) * (dHp / Sh))


def psnr(a, b):
    mse = np.mean((a - b) ** 2)
    if mse <= 1e-12:
        return 99.0
    return 10 * np.log10(1.0 / mse)


def report(ours, ref, name=""):
    lab1 = srgb_to_lab(ours)
    lab2 = srgb_to_lab(ref)
    de76 = delta_e76(lab1, lab2)
    de00 = delta_e2000(lab1, lab2)
    mad = np.mean(np.abs(ours - ref)) * 255

    def stat(x):
        return (float(np.mean(x)), float(np.percentile(x, 95)), float(np.max(x)))

    m, p95, mx = stat(de76)
    m00, p9500, mx00 = stat(de00)
    print(f"== {name or 'compare'} ==")
    print(f"  resolved       : {ours.shape[1]}x{ours.shape[0]}")
    print(f"  ΔE76   mean/p95/max : {m:.3f} / {p95:.3f} / {mx:.3f}")
    print(f"  ΔE2000 mean/p95/max : {m00:.3f} / {p9500:.3f} / {mx00:.3f}")
    print(f"  PSNR           : {psnr(ours, ref):.2f} dB")
    print(f"  mean |diff|    : {mad:.2f} / 255")
    over = float(np.mean(de76 > 2.0)) * 100
    print(f"  ΔE76>2 占比     : {over:.2f}%")
    print("")
    print("  验收线（单滑杆消融）：ΔE76 mean < 1.5，p95 < 4，全开叠加 mean < 3.0")
    return {"de76_mean": m, "de76_p95": p95, "de2000_mean": m00,
            "psnr": psnr(ours, ref), "mad": mad, "over2_pct": over}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ours = read_png(sys.argv[1])
    ref = read_png(sys.argv[2])
    if ours.shape != ref.shape:
        raise SystemExit(f"尺寸不一致: {ours.shape} vs {ref.shape}")
    report(ours, ref, name=f"{sys.argv[1]} vs {sys.argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
