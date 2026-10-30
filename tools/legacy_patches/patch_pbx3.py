import os, re

root = os.path.dirname(os.path.abspath(__file__))
groups = {
    "Core/CommercialRetouch": os.path.join(root, "OutdoorPhotoAssistant", "Core", "CommercialRetouch"),
    "Features/CommercialRetouch": os.path.join(root, "OutdoorPhotoAssistant", "Features", "CommercialRetouch"),
    "Core/Cloud": os.path.join(root, "OutdoorPhotoAssistant", "Core", "Cloud"),
    "Core/Camera": os.path.join(root, "OutdoorPhotoAssistant", "Core", "Camera"),
}

p = os.path.join(root, "scripts", "gen_pbxproj.py")
s = open(p, encoding="utf-8").read()
for key, folder in groups.items():
    names = sorted(n for n in os.listdir(folder) if n.endswith(".swift"))
    line = f'"{key}": [' + ", ".join(f'"{n}"' for n in names) + "],"
    s, n = re.subn(r'"' + re.escape(key) + r'": \[[^\]]*\],', line, s, count=1)
    print(key, "->", len(names), "files, patched:", n)
open(p, "w", encoding="utf-8").write(s)
