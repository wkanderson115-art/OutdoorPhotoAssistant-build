import os, re

root = os.path.dirname(os.path.abspath(__file__))
core = os.path.join(root, "OutdoorPhotoAssistant", "Core", "CommercialRetouch")
feat = os.path.join(root, "OutdoorPhotoAssistant", "Features", "CommercialRetouch")

def swift_names(folder):
    return sorted(n for n in os.listdir(folder) if n.endswith(".swift"))

core_files = swift_names(core)
feat_files = swift_names(feat)

p = os.path.join(root, "scripts", "gen_pbxproj.py")
s = open(p, encoding="utf-8").read()

core_line = '"Core/CommercialRetouch": [' + ", ".join(f'"{n}"' for n in core_files) + "],"
feat_line = '"Features/CommercialRetouch": [' + ", ".join(f'"{n}"' for n in feat_files) + "],"

s = re.sub(r'"Core/CommercialRetouch": \[[^\]]*\],', core_line, s, count=1)
s = re.sub(r'"Features/CommercialRetouch": \[[^\]]*\],', feat_line, s, count=1)
open(p, "w", encoding="utf-8").write(s)

print("core:", len(core_files), "files")
for n in core_files:
    print("  ", n)
print("features:", feat_files)
