"""Static checks for the CommercialRetouch module (no Swift toolchain on Windows).

The real verification still has to happen with `xcodebuild` on macOS, but this
script catches the failure modes that a text port to a new language actually
produces: unbalanced braces, Core Image builtins that do not exist, API calls
that drifted from the agreed PixelKit contract, duplicate type definitions and
missing framework imports.

Usage:  python scripts/check_retouch_sources.py [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_DIR = os.path.join(ROOT, "OutdoorPhotoAssistant", "Core", "CommercialRetouch")
FEATURE_DIR = os.path.join(ROOT, "OutdoorPhotoAssistant", "Features", "CommercialRetouch")
CLOUD_DIR = os.path.join(ROOT, "OutdoorPhotoAssistant", "Core", "Cloud")

# CIFilterBuiltins that this module is allowed to use. Anything else must be
# reviewed before it ships (a wrong builtin name is a silent nil at runtime).
KNOWN_CI_BUILTINS = {
    "gaussianBlur", "boxBlur", "colorControls", "colorMatrix", "exposureAdjust",
    "highlightShadowAdjust", "toneCurve", "vibrance", "colorCube", "colorInvert",
    "unsharpMask", "sharpenLuminance", "radialGradient", "constantColorGenerator",
    "blendWithMask", "sourceOverCompositing", "additionCompositing", "multiplyCompositing",
    "colorBlendMode", "luminosityBlendMode", "softLightBlendMode", "overlayBlendMode",
    "colorClamp", "median", "noiseReduction", "temperatureAndTint", "colorPolynomial",
    "blendWithAlphaMask", "circularScreen", "randomGenerator", "areaAverage",
    "edges", "areaHistogram", "linearGradient", "radialGradient",
    "morphologyMinimum", "morphologyMaximum", "bumpDistortion", "pinchDistortion",
    "vortexDistortion", "displacementDistortion", "colorCubeWithColorSpace",
    "maximumCompositing", "minimumCompositing", "sourceInCompositing",
}

# PixelKit surface agreed with the engine (see RetouchMaskKit contract).
PIXELKIT_API = {
    "renderRGBA8", "cgImage", "image", "colorImage", "maskImage", "luma",
    "srgbToLinear", "linearToSrgb", "rgbToLab", "labToRGB", "deltaE2000",
    "boxBlur", "gaussianBlur", "guidedFilter", "minimumFilter", "maximumFilter",
    "morphologicalClose", "percentile", "median", "mean", "medianRGB", "ycbcr",
    "lab", "gaussian", "blend", "constantMask", "scaledMask", "downscale",
    # internal constants used inside RetouchMaskKit itself
    "lutSize", "srgbLinearCut",
}


def read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def strip_strings_and_comments(src: str) -> str:
    """Remove string literals and comments so bracket counting is meaningful."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check_balance(name: str, src: str, problems: list[str]) -> None:
    clean = strip_strings_and_comments(src)
    for open_c, close_c in (("{", "}"), ("(", ")"), ("[", "]")):
        if clean.count(open_c) != clean.count(close_c):
            problems.append(f"{name}: unbalanced {open_c}{close_c} "
                            f"({clean.count(open_c)} vs {clean.count(close_c)})")


def check_builtins(name: str, src: str, problems: list[str]) -> None:
    for match in re.finditer(r"CIFilter\.([A-Za-z0-9_]+)\(", src):
        builtin = match.group(1)
        if builtin not in KNOWN_CI_BUILTINS:
            problems.append(f"{name}: CIFilter.{builtin}() is not in the reviewed builtin list")


def check_pixelkit(name: str, src: str, problems: list[str]) -> None:
    for match in re.finditer(r"PixelKit\.([A-Za-z0-9_]+)", src):
        api = match.group(1)
        if api not in PIXELKIT_API:
            problems.append(f"{name}: PixelKit.{api} is outside the agreed contract")


def check_imports(name: str, src: str, problems: list[str]) -> None:
    needs = []
    if re.search(r"\bUI(Image|View|Screen|Color|Graphics|Kit)\b|\bUIImage\b", src):
        needs.append("UIKit")
    if "CIFilter" in src or "CIImage" in src:
        needs.append("CoreImage")
    if "VN" in src and "Vision" not in src:
        needs.append("Vision")
    imports = set(re.findall(r"^\s*import\s+([A-Za-z0-9_.]+)", src, re.M))
    for need in needs:
        if need not in imports and not (need == "CoreImage" and "CoreImage.CIFilterBuiltins" in imports):
            problems.append(f"{name}: missing `import {need}`")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    problems: list[str] = []
    files = []
    for folder in (MODULE_DIR, FEATURE_DIR, CLOUD_DIR):
        if not os.path.isdir(folder):
            continue
        for entry in sorted(os.listdir(folder)):
            if entry.endswith(".swift"):
                files.append(os.path.join(folder, entry))

    type_owner: dict[str, list[str]] = {}
    for path in files:
        src = read(path)
        name = os.path.basename(path)
        check_balance(name, src, problems)
        check_builtins(name, src, problems)
        check_pixelkit(name, src, problems)
        check_imports(name, src, problems)
        for match in re.finditer(r"^(?:final\s+|public\s+|private\s+)?(?:struct|class|enum|protocol)\s+([A-Za-z0-9_]+)",
                                 strip_strings_and_comments(src), re.M):
            type_owner.setdefault(match.group(1), []).append(name)

    for type_name, owners in sorted(type_owner.items()):
        if len(owners) > 1:
            # extension-only helpers are fine; duplicate primary declarations are not
            problems.append(f"duplicate type `{type_name}` declared in: {', '.join(sorted(set(owners)))}")

    summary = {
        "files": [os.path.basename(p) for p in files],
        "problems": problems,
        "ok": not problems,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, ensure_ascii=False, indent=2)
    sys.exit(0 if not problems else 1)


if __name__ == "__main__":
    main()
