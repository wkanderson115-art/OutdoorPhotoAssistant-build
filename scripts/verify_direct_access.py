"""Source/config audit, not a Swift execution or provider connectivity test."""
from pathlib import Path
import plistlib
import yaml

root = Path(__file__).resolve().parents[1]
app = root / 'OutdoorPhotoAssistant'
cloud = (app / 'Core/Cloud/CloudAPI.swift').read_text()
config = (app / 'Core/Cloud/CloudConfiguration.swift').read_text()
settings = (app / 'Features/Cloud/CloudAPISettingsView.swift').read_text()
gallery = (app / 'Features/Gallery/GalleryView.swift').read_text()
store = (app / 'Core/Storage/AppPhotoStore.swift').read_text()
app_source = '\n'.join(x.read_text() for x in app.rglob('*.swift'))
checks = {
    'direct official endpoints present': 'https://api.deepseek.com/chat/completions' in cloud and 'https://ark.cn-beijing.volces.com/api/v3/images/generations' in cloud,
    'backend client and Apple cloud login removed': all(x not in app_source for x in ['BackendClient', 'SignInWithAppleButton', 'import AuthenticationServices', 'CloudConfiguration.client()']),
    'no deployment at repository root': not (root / 'render.yaml').exists() and not (root / 'server').exists(),
    'no backend URL in app plist': 'PhotoBackendURL' not in plistlib.loads((app / 'Info.plist').read_bytes()),
    'no Apple-login signing entitlement': 'CODE_SIGN_ENTITLEMENTS' not in (root / 'OutdoorPhotoAssistant.xcodeproj/project.pbxproj').read_text(),
    'keys saved only to Keychain': 'SecItemAdd' in config and 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in config and 'UserDefaults.standard.set' not in config,
    'secure input does not load saved key text': 'SecureField' in settings and 'deepSeekKey = APIKeyStore.read' not in settings and 'seedreamKey = APIKeyStore.read' not in settings,
    'real photo bytes uploaded': cloud.count('jpeg.base64EncodedString()') == 2,
    'result URL persisted before downloading': gallery.index('url: reply.imageURL.absoluteString') < gallery.index('client.download(reply.imageURL)'),
    'recovery does not request generation': '.edit(' not in gallery[gallery.index('    func retryDownload'):gallery.index('    func cancel()')],
    'download-only block does not attach API key': 'Authorization' not in cloud[cloud.index('    static func downloadRequest'):],
    'new jobs identify direct transport': 'transport: "direct-v1"' in store,
    'generated versions deduplicate by job id': 'record.versions.contains(where: { $0.cloudJobID == cloudJobID })' in store,
    'natural policy remains active': 'NaturalPhotoPolicy.rules' in cloud and 'NaturalPhotoPolicy.editPrompt(prompt)' in cloud,
    'camera still uses live effects': 'realtimePreview.consume(sampleBuffer)' in (app / 'Core/Camera/CameraService.swift').read_text(),
    'CI no longer requires backend deployment': 'backend-tests' not in yaml.safe_load((root / '.github/workflows/ios-unsigned-build.yml').read_text())['jobs'],
}
for label, passed in checks.items():
    print(('PASS: ' if passed else 'FAIL: ') + label)
raise SystemExit(0 if all(checks.values()) else 1)
