import re

# allow the additional real Core Image builtins used by the studio layer
p = 'scripts/check_retouch_sources.py'
s = open(p, encoding='utf-8').read()
s = s.replace('    "edges", "areaHistogram",\n}',
              '    "edges", "areaHistogram", "linearGradient", "radialGradient",\n'
              '    "morphologyMinimum", "morphologyMaximum", "bumpDistortion", "pinchDistortion",\n'
              '    "vortexDistortion", "displacementDistortion", "colorCubeWithColorSpace",\n}')
open(p, 'w', encoding='utf-8').write(s)

# RootView: expose the studio screen
p = 'OutdoorPhotoAssistant/App/RootView.swift'
s = open(p, encoding='utf-8').read()
print('rootview has CommercialRetouchView:', 'CommercialRetouchView(' in s)
open(p, 'w', encoding='utf-8').write(s)
print('patched')
