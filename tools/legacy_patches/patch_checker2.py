import io

p = 'scripts/check_retouch_sources.py'
s = io.open(p, encoding='utf-8').read()
s = s.replace('FEATURE_DIR = os.path.join(ROOT, "OutdoorPhotoAssistant", "Features", "CommercialRetouch")',
              'FEATURE_DIR = os.path.join(ROOT, "OutdoorPhotoAssistant", "Features", "CommercialRetouch")\n'
              'CLOUD_DIR = os.path.join(ROOT, "OutdoorPhotoAssistant", "Core", "Cloud")')
s = s.replace('    for folder in (MODULE_DIR, FEATURE_DIR):',
              '    for folder in (MODULE_DIR, FEATURE_DIR, CLOUD_DIR):')
io.open(p, 'w', encoding='utf-8').write(s)
print('checker now scans Core/Cloud too')
