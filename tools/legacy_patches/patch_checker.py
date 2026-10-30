import io

p = 'scripts/check_retouch_sources.py'
s = io.open(p, encoding='utf-8').read()
old = '"vortexDistortion", "displacementDistortion", "colorCubeWithColorSpace",'
new = ('"vortexDistortion", "displacementDistortion", "colorCubeWithColorSpace",\n'
       '    "maximumCompositing", "minimumCompositing", "sourceInCompositing",')
assert old in s, 'allowlist anchor not found'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('checker allowlist updated')
