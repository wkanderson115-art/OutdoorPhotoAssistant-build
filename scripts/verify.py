"""Static verification for the generated Xcode project (runs on Windows, no Xcode).

These checks do not type-check Swift or replace an Xcode build.

Checks:
  1. project.pbxproj parses and its object graph is consistent
  2. every Swift file on disk is in Sources, and every Sources entry exists on disk
  3. target has Debug + Release build configurations
  4. scheme XML parses and references the real target id
  5. Info.plist / PrivacyInfo.xcprivacy parse as plists and contain required keys
  6. asset catalog JSON is valid, app icon is 1024x1024 RGB PNG
  7. workflow YAML parses
  8. Swift files parse (tree-sitter) and known-bad iOS 27 APIs are absent

Usage: python scripts/verify.py
"""
from __future__ import annotations

import json
import pathlib
import plistlib
import sys
import xml.etree.ElementTree as ET

import tree_sitter_swift as tss
import yaml
from tree_sitter import Language, Parser

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "OutdoorPhotoAssistant"
PBX = ROOT / "OutdoorPhotoAssistant.xcodeproj" / "project.pbxproj"
SCHEME = ROOT / "OutdoorPhotoAssistant.xcodeproj" / "xcshareddata" / "xcschemes" / "OutdoorPhotoAssistant.xcscheme"

failures: list[str] = []
notes: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"  PASS  {message}")
    else:
        print(f"  FAIL  {message}")
        failures.append(message)


print("== 1. project.pbxproj ==")
from pbxproj import XcodeProject  # noqa: E402

project = XcodeProject.load(str(PBX))
check(project is not None, "pbxproj parses")

objects = project.objects.get_objects_in_section("PBXFileReference")
refs_by_id = {o.get_id(): o for o in objects}
print(f"  info  file references: {len(objects)}")

build_files = project.objects.get_objects_in_section("PBXBuildFile")
print(f"  info  build files: {len(build_files)}")

targets = project.objects.get_objects_in_section("PBXNativeTarget")
check(len(targets) == 1, "exactly one native target")
target = targets[0]
check(str(target.productType) == "com.apple.product-type.application", "target is an app")

config_list_id = target.buildConfigurationList
config_lists = {o.get_id(): o for o in project.objects.get_objects_in_section("XCConfigurationList")}
configs = {o.get_id(): o for o in project.objects.get_objects_in_section("XCBuildConfiguration")}
target_configs = config_lists[config_list_id].buildConfigurations
config_names = sorted(str(configs[cid].name) for cid in target_configs)
check(config_names == ["Debug", "Release"], f"target configurations = Debug + Release (got {config_names})")

# target build settings sanity
def setting(obj, key):
    try:
        value = obj.get(key, None)
    except TypeError:
        value = obj.get(key)
    return value


target_debug = next(configs[cid] for cid in target_configs if str(configs[cid].name) == "Debug")
settings = target_debug.buildSettings
check(str(setting(settings, "INFOPLIST_FILE")) == "OutdoorPhotoAssistant/Info.plist", "INFOPLIST_FILE is set")
check("17.6" in str(setting(settings, "IPHONEOS_DEPLOYMENT_TARGET")), "deployment target 17.6")
check(str(setting(settings, "TARGETED_DEVICE_FAMILY")) == "1", "iPhone-only target")
check(str(setting(settings, "SWIFT_VERSION")) == "5.0", "SWIFT_VERSION = 5.0 (valid language mode)")

print("== 2. sources vs disk ==")
disk_swift = sorted(p.relative_to(APP).as_posix() for p in APP.rglob("*.swift"))
sources_phase = next(o for o in project.objects.get_objects_in_section("PBXSourcesBuildPhase"))
source_ref_ids = []
for build_file_id in sources_phase.files:
    build_file = next(bf for bf in build_files if bf.get_id() == build_file_id)
    source_ref_ids.append(build_file.fileRef)

source_paths = sorted(str(refs_by_id[rid].path) for rid in source_ref_ids)
# file refs are relative to their group; group paths are the parent dirs. Compare basenames + count.
source_basenames = sorted(pathlib.PurePosixPath(p).name for p in source_paths)
disk_basenames = sorted(pathlib.PurePosixPath(p).name for p in disk_swift)
check(len(disk_swift) >= 27, f"at least 27 Swift files on disk (got {len(disk_swift)})")
check(source_basenames == disk_basenames, "Sources phase matches Swift files on disk")

print("== 3. resources ==")
resources_phase = next(o for o in project.objects.get_objects_in_section("PBXResourcesBuildPhase"))
resource_paths = []
for build_file_id in resources_phase.files:
    build_file = next(bf for bf in build_files if bf.get_id() == build_file_id)
    resource_paths.append(str(refs_by_id[build_file.fileRef].path))
check("Assets.xcassets" in resource_paths, "Assets.xcassets is in Resources")
check("PrivacyInfo.xcprivacy" in resource_paths, "PrivacyInfo.xcprivacy is in Resources")

print("== 4. scheme ==")
scheme_root = ET.parse(SCHEME).getroot()
check(scheme_root.tag == "Scheme", "scheme XML parses")
blueprints = {
    element.get("BlueprintIdentifier")
    for element in scheme_root.iter("BuildableReference")
}
check(str(target.get_id()) in blueprints, f"scheme references target {target.get_id()}")
launch = scheme_root.find("LaunchAction")
check(launch is not None and launch.get("buildConfiguration") == "Debug", "LaunchAction uses Debug")

print("== 5. Info.plist / PrivacyInfo ==")
info = plistlib.loads((APP / "Info.plist").read_bytes())
for key in [
    "NSCameraUsageDescription",
    "NSPhotoLibraryAddUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSMotionUsageDescription",
    "UILaunchScreen",
    "UISupportedInterfaceOrientations",
]:
    check(key in info, f"Info.plist has {key}")
check(set(info.get("UISupportedInterfaceOrientations", [])) == {
    "UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight"}, "portrait and landscape camera orientations")

privacy = plistlib.loads((APP / "PrivacyInfo.xcprivacy").read_bytes())
api_types = privacy.get("NSPrivacyAccessedAPITypes", [])
check(any(item.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults" for item in api_types),
      "privacy manifest declares UserDefaults (CA92.1 reason)")
check(privacy.get("NSPrivacyTracking") is False, "privacy manifest declares no tracking")

print("== 6. asset catalog + icon ==")
assets = json.loads((APP / "Assets.xcassets" / "Contents.json").read_text(encoding="utf-8"))
check("info" in assets, "asset catalog root Contents.json valid")
icon_json = json.loads((APP / "Assets.xcassets" / "AppIcon.appiconset" / "Contents.json").read_text(encoding="utf-8"))
check(icon_json["images"][0]["size"] == "1024x1024", "AppIcon declares 1024x1024")
accent = json.loads((APP / "Assets.xcassets" / "AccentColor.colorset" / "Contents.json").read_text(encoding="utf-8"))
check("colors" in accent, "AccentColor colorset valid")

icon_path = APP / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
data = icon_path.read_bytes()
signature_ok = data[:8] == b"\x89PNG\r\n\x1a\n"
width = int.from_bytes(data[16:20], "big")
height = int.from_bytes(data[20:24], "big")
color_type = data[25]
check(signature_ok, "app icon is a PNG")
check((width, height) == (1024, 1024), f"app icon is 1024x1024 (got {width}x{height})")
check(color_type == 2, f"app icon is RGB without alpha (color type {color_type})")

print("== 7. workflow YAML ==")
workflow_path = ROOT / ".github" / "workflows" / "ios-unsigned-build.yml"
workflow = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))
check("jobs" in workflow, "workflow YAML parses")
check("build" in workflow["jobs"], "workflow has build job")
steps_text = yaml.dump(workflow)
check("CODE_SIGNING_ALLOWED=NO" in (ROOT / "scripts/build_unsigned_ipa.sh").read_text(), "workflow builds unsigned")
build_script = (ROOT / "scripts/build_unsigned_ipa.sh").read_text()
check("scripts/build_unsigned_ipa.sh" in steps_text and "for CONFIG in Debug Release" in build_script,
      "workflow builds both Debug and Release")

print("== 8. Swift syntax + risky API scan ==")
language = Language(tss.language())
parser = Parser(language)
syntax_failures = []
total_lines = 0
for path in sorted(APP.rglob("*.swift")):
    source = path.read_bytes()
    total_lines += source.count(b"\n") + 1
    tree = parser.parse(source)
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            syntax_failures.append(f"{path.name}:{node.start_point[0] + 1}")
            break
        stack.extend(node.children)
check(not syntax_failures, f"all Swift files parse ({total_lines} lines)")
if syntax_failures:
    for item in syntax_failures:
        notes.append(item)

forbidden = {
    "recommendedLensApertureStops": "iOS 27 API (not available in iOS 26 SDK)",
    "AVCaptureISOAuto": "iOS 27 constant / renamed in Swift",
    "AVCaptureExposureDurationAuto": "iOS 27 constant / renamed in Swift",
    "setExposureModeCustom(lensAperture": "iOS 27 API",
    "supportsExposureModeCustom(lensAperture": "iOS 27 API",
    "isAppleProRAWSupported": "removed feature (was broken)",
    "AVCaptureSystemZoomSlider": "dropped for first-compile safety",
    "lowLightBoostSupported": "typo API (should be isLowLightBoostSupported)",
}
all_swift = "\n".join(p.read_text(encoding="utf-8") for p in APP.rglob("*.swift"))
for token, reason in forbidden.items():
    check(token not in all_swift, f"absent: {token} ({reason})")

# 硬件快门：AVCaptureEventInteraction 是 iOS 17.2 的 AVKit API，之前为了首编安全整段删掉。
# 现在不是一票否决，而是「必须带正确保护」才放行：
#   * 必须 import AVKit（或 canImport(AVKit)），否则类型都找不到；
#   * 必须有 iOS 17.2 的可用性保护，否则低版本/旧 SDK 编译直接炸；
#   * 只允许出现在相机预览层里（其它位置出现说明用法跑偏了）。
shutter_file = APP / "Core" / "Camera" / "CameraService.swift"
shutter_text = shutter_file.read_text(encoding="utf-8") if shutter_file.exists() else ""
if "AVCaptureEventInteraction" in shutter_text:
    check("import AVKit" in shutter_text or "canImport(AVKit)" in shutter_text,
          "AVCaptureEventInteraction requires import AVKit")
    check("#available(iOS 17.2" in shutter_text,
          "AVCaptureEventInteraction guarded by #available(iOS 17.2)")
    for other in APP.rglob("*.swift"):
        if other.name == shutter_file.name:
            continue
        if "AVCaptureEventInteraction" in other.read_text(encoding="utf-8"):
            check(False, f"AVCaptureEventInteraction must live only in CameraService, also found in {other.name}")

aesthetic_file = (APP / "Core" / "Analysis" / "FrameAnalyzer.swift").read_text(encoding="utf-8")
check('if #available(iOS 18.0, *)' in aesthetic_file, "aesthetics request guarded by #available(iOS 18.0)")

print()
print(f"RESULT: {len(failures)} failures" + (f" -> {failures}" if failures else " (all checks passed)"))
if notes:
    print("notes:", notes)
sys.exit(1 if failures else 0)
