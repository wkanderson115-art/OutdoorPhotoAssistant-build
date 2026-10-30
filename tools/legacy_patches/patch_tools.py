import re, io

# 1) allow PixelKit's own internal constants in the static checker
p = 'scripts/check_retouch_sources.py'
s = open(p, encoding='utf-8').read()
s = s.replace('''    "lab", "gaussian", "blend", "constantMask", "scaledMask", "downscale",
}''', '''    "lab", "gaussian", "blend", "constantMask", "scaledMask", "downscale",
    # internal constants used inside RetouchMaskKit itself
    "lutSize", "srgbLinearCut",
}''')
open(p, 'w', encoding='utf-8').write(s)

# 2) register the new files in the Xcode project generator
p = 'scripts/gen_pbxproj.py'
s = open(p, encoding='utf-8').read()
old = '"Core/CommercialRetouch": ["PresetCatalog.swift", "RetouchPipeline.swift", "CommercialQuality.swift", "SafeFusion.swift"],'
new = ('"Core/CommercialRetouch": ["PresetCatalog.swift", "RetouchPipeline.swift", "CommercialQuality.swift", '
       '"SafeFusion.swift", "RetouchParameters.swift", "RetouchMaskKit.swift", "RetouchAnalyzer.swift", '
       '"RetouchEngine.swift", "RetouchQualityGate.swift"],')
assert old in s, "generator file list not found"
s = s.replace(old, new)
open(p, 'w', encoding='utf-8').write(s)
print('patched checker + pbxproj generator')
