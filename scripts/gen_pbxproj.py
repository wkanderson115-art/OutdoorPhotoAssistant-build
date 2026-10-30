"""Generate a valid Xcode project.pbxproj + shared scheme for OutdoorPhotoAssistant.

Deterministic IDs, so re-running produces identical files. Run from repo root:
    python scripts/gen_pbxproj.py

Also prints a short summary and self-checks the generated project file.
"""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT_DIR = ROOT / "OutdoorPhotoAssistant.xcodeproj"
OUT = PROJECT_DIR / "project.pbxproj"
SCHEME = PROJECT_DIR / "xcshareddata" / "xcschemes" / "OutdoorPhotoAssistant.xcscheme"

GROUPS = {
    "App": ["OutdoorPhotoAssistantApp.swift", "RootView.swift", "AppTheme.swift", "OrientationPolicy.swift"],
    "Core/Camera": ["AdaptiveCameraEngine.swift", "CameraService.swift", "CaptureHandoff.swift", "DepthPortraitProcessor.swift"],
    "Core/Analysis": [
        "FrameAnalyzer.swift",
        "DirectorEngine.swift", "DirectorVision.swift", "DirectorMLModel.swift",
        "PhotoFilter.swift",
        "ColorGrade.swift",
        "PortraitBeautyEngine.swift",
        "SmartShutterEngine.swift",
        "PhotoPostProcessor.swift",
        "FrameScoring.swift",
    ],
    "Core/Storage": ["PhotoLibraryService.swift", "AppPhotoStore.swift"],
    "Core/Cloud": ["CloudAPI.swift", "CloudConfiguration.swift", "CloudEscalationPolicy.swift", "RetouchPlanMapper.swift"],
    "Features/Gallery": ["GalleryView.swift"],
    "Core/CommercialRetouch": ["BlemishLearnedModel.swift", "BlemishModelBridge+Proxy.swift", "BlemishModelBridge.swift", "CommercialQuality.swift", "HybridFusion.swift", "LocalRetouchPreflight.swift", "PresetCatalog.swift", "RetouchAnalyzer.swift", "RetouchBackground.swift", "RetouchBatchRunner.swift", "RetouchDelivery.swift", "RetouchEngine.swift", "RetouchMaskKit.swift", "RetouchParameters.swift", "RetouchPipeline.swift", "RetouchPixelAudit.swift", "RetouchProofing.swift", "RetouchQualityGate.swift", "RetouchRecovery.swift", "RetouchReshape.swift", "RetouchSpecialist.swift", "RetouchStudioModel.swift", "SafeFusion.swift", "ACRDevelopEngine.swift", "ACRDevelopBridge.swift", "ACRLensRepairEngine.swift"],
    "Features/CommercialRetouch": ["CommercialRetouchView.swift", "RetouchStudioView.swift"],
    "Features/Cloud": ["CloudAPISettingsView.swift"],
    "Core/Location": ["LocationService.swift"],
    "Core/Motion": ["MotionService.swift"],
    "Features/Capture": ["CaptureView.swift", "CaptureLayout.swift", "CompositionOverlay.swift"],
    "Features/Review": ["ReviewView.swift"],
    "Features/Settings": ["SettingsView.swift"],
}

GROUP_HIERARCHY = {
    "": ["App", "Core", "Features"],
    "Core": ["Core/Camera", "Core/Analysis", "Core/Storage", "Core/Cloud", "Core/Location", "Core/Motion", "Core/CommercialRetouch"],
    "Features": ["Features/Capture", "Features/Review", "Features/Settings", "Features/Gallery", "Features/Cloud", "Features/CommercialRetouch"],
}

BUNDLE_ID = "com.example.outdoorphotoassistant"


class Ids:
    """Xcode object IDs: 24 hex characters, unique."""

    def __init__(self, prefix: str) -> None:
        self.prefix = prefix
        self.counter = 0
        self.seen: set[str] = set()

    def next(self) -> str:
        self.counter += 1
        value = f"{self.prefix}{self.counter:022d}"
        assert len(value) == 24, value
        assert value not in self.seen, value
        self.seen.add(value)
        return value


def quote(value: str) -> str:
    if value == "" or any(ch in value for ch in " /:()$"):
        return f'"{value}"'
    return value


def build() -> tuple[str, dict[str, str]]:
    a = Ids("A0")
    d = Ids("D0")
    f = Ids("F0")
    b = Ids("B0")

    project_id = a.next()
    main_group = a.next()
    products_group = a.next()
    target_id = a.next()
    app_product_ref = a.next()
    source_group = a.next()
    sources_phase = a.next()
    frameworks_phase = a.next()
    resources_phase = a.next()
    project_cfg_list = a.next()
    target_cfg_list = a.next()
    project_debug = a.next()
    project_release = a.next()
    target_debug = a.next()
    target_release = a.next()

    group_ids: dict[str, str] = {name: d.next() for name in GROUPS}
    for name in GROUP_HIERARCHY:
        if name and name not in group_ids:
            group_ids[name] = d.next()

    swift_refs: dict[str, str] = {}
    for group, names in GROUPS.items():
        for name in names:
            swift_refs[f"{group}/{name}"] = f.next()
    info_ref = f.next()
    assets_ref = f.next()
    privacy_ref = f.next()

    swift_build: dict[str, str] = {}
    for group, names in GROUPS.items():
        for name in names:
            swift_build[f"{group}/{name}"] = b.next()
    assets_build = b.next()
    privacy_build = b.next()

    out: list[str] = []
    add = out.append

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add("\tobjectVersion = 56;")
    add("\tobjects = {")
    add("")

    add("/* Begin PBXBuildFile section */")
    for group, names in GROUPS.items():
        for name in names:
            key = f"{group}/{name}"
            add(
                f"\t\t{swift_build[key]} /* {name} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {swift_refs[key]} /* {name} */; }};"
            )
    add(
        f"\t\t{assets_build} /* Assets.xcassets in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};"
    )
    add(
        f"\t\t{privacy_build} /* PrivacyInfo.xcprivacy in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {privacy_ref} /* PrivacyInfo.xcprivacy */; }};"
    )
    add("/* End PBXBuildFile section */")
    add("")

    add("/* Begin PBXFileReference section */")
    add(
        f"\t\t{app_product_ref} /* OutdoorPhotoAssistant.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = OutdoorPhotoAssistant.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    for group, names in GROUPS.items():
        for name in names:
            key = f"{group}/{name}"
            add(
                f"\t\t{swift_refs[key]} /* {name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = sourcecode.swift; path = {quote(name)}; sourceTree = \"<group>\"; }};"
            )
    add(
        f"\t\t{info_ref} /* Info.plist */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};"
    )
    add(
        f"\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};"
    )
    add(
        f"\t\t{privacy_ref} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = \"<group>\"; }};"
    )
    add("/* End PBXFileReference section */")
    add("")

    add("/* Begin PBXFrameworksBuildPhase section */")
    add(
        f"\t\t{frameworks_phase} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; "
        f"buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};"
    )
    add("/* End PBXFrameworksBuildPhase section */")
    add("")

    add("/* Begin PBXGroup section */")
    add(
        f"\t\t{main_group} = {{isa = PBXGroup; children = ("
        f"{source_group} /* OutdoorPhotoAssistant */, {products_group} /* Products */, ); "
        f"sourceTree = \"<group>\"; }};"
    )
    add(
        f"\t\t{products_group} /* Products */ = {{isa = PBXGroup; children = ("
        f"{app_product_ref} /* OutdoorPhotoAssistant.app */, ); name = Products; sourceTree = \"<group>\"; }};"
    )
    add(
        f"\t\t{source_group} /* OutdoorPhotoAssistant */ = {{isa = PBXGroup; children = ("
        f"{group_ids['App']} /* App */, {group_ids['Core']} /* Core */, {group_ids['Features']} /* Features */, "
        f"{info_ref} /* Info.plist */, {assets_ref} /* Assets.xcassets */, "
        f"{privacy_ref} /* PrivacyInfo.xcprivacy */, ); "
        f"path = OutdoorPhotoAssistant; sourceTree = \"<group>\"; }};"
    )
    for parent, children in GROUP_HIERARCHY.items():
        if not parent:
            continue  # source_group already defined above; skip to avoid duplicate PBXGroup ID
        child_ids = " ".join(f"{group_ids[child]} /* {child.split('/')[-1]} */," for child in children)
        parent_path = parent.split("/")[-1]
        parent_id = group_ids[parent]
        add(
            f"\t\t{parent_id} /* {parent_path} */ = {{isa = PBXGroup; children = ("
            f"{child_ids} ); path = {quote(parent_path)}; sourceTree = \"<group>\"; }};"
        )
    for group, names in GROUPS.items():
        refs = " ".join(f"{swift_refs[f'{group}/{name}']} /* {name} */," for name in names)
        add(
            f"\t\t{group_ids[group]} /* {group.split('/')[-1]} */ = {{isa = PBXGroup; children = ({refs} ); "
            f"path = {quote(group.split('/')[-1])}; sourceTree = \"<group>\"; }};"
        )
    add("/* End PBXGroup section */")
    add("")

    add("/* Begin PBXNativeTarget section */")
    add(
        f"\t\t{target_id} /* OutdoorPhotoAssistant */ = {{isa = PBXNativeTarget; "
        f"buildConfigurationList = {target_cfg_list}; "
        f"buildPhases = ({sources_phase} /* Sources */, {frameworks_phase} /* Frameworks */, "
        f"{resources_phase} /* Resources */, ); "
        f"buildRules = (); dependencies = (); name = OutdoorPhotoAssistant; "
        f"productName = OutdoorPhotoAssistant; "
        f"productReference = {app_product_ref} /* OutdoorPhotoAssistant.app */; "
        f"productType = \"com.apple.product-type.application\"; }};"
    )
    add("/* End PBXNativeTarget section */")
    add("")

    add("/* Begin PBXProject section */")
    add(
        f"\t\t{project_id} /* Project object */ = {{isa = PBXProject; attributes = {{ "
        f"BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2600; LastUpgradeCheck = 2600; "
        f"TargetAttributes = {{ {target_id} = {{ CreatedOnToolsVersion = 26.0; }}; }}; }}; "
        f"buildConfigurationList = {project_cfg_list}; compatibilityVersion = \"Xcode 14.0\"; "
        f"developmentRegion = en; hasScannedForEncodings = 0; "
        f"knownRegions = (en, Base, \"zh-Hans\", ); mainGroup = {main_group}; "
        f"productRefGroup = {products_group} /* Products */; projectDirPath = \"\"; projectRoot = \"\"; "
        f"targets = ({target_id} /* OutdoorPhotoAssistant */, ); }};"
    )
    add("/* End PBXProject section */")
    add("")

    add("/* Begin PBXResourcesBuildPhase section */")
    add(
        f"\t\t{resources_phase} /* Resources */ = {{isa = PBXResourcesBuildPhase; "
        f"buildActionMask = 2147483647; files = ("
        f"{assets_build} /* Assets.xcassets in Resources */, "
        f"{privacy_build} /* PrivacyInfo.xcprivacy in Resources */, ); "
        f"runOnlyForDeploymentPostprocessing = 0; }};"
    )
    add("/* End PBXResourcesBuildPhase section */")
    add("")

    add("/* Begin PBXSourcesBuildPhase section */")
    source_files = " ".join(
        f"{swift_build[f'{group}/{name}']} /* {name} in Sources */,"
        for group, names in GROUPS.items()
        for name in names
    )
    add(
        f"\t\t{sources_phase} /* Sources */ = {{isa = PBXSourcesBuildPhase; "
        f"buildActionMask = 2147483647; files = ({source_files} ); "
        f"runOnlyForDeploymentPostprocessing = 0; }};"
    )
    add("/* End PBXSourcesBuildPhase section */")
    add("")

    add("/* Begin XCBuildConfiguration section */")
    project_common = [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "CLANG_ANALYZER_NONNULL = YES;",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "CLANG_WARN_BOOL_CONVERSION = YES;",
        "CLANG_WARN_EMPTY_BODY = YES;",
        "CLANG_WARN_UNREACHABLE_CODE = YES;",
        "COPY_PHASE_STRIP = NO;",
        "ENABLE_STRICT_OBJC_MSGSEND = YES;",
        "GCC_C_LANGUAGE_STANDARD = gnu17;",
        "GCC_NO_COMMON_BLOCKS = YES;",
        "IPHONEOS_DEPLOYMENT_TARGET = 17.6;",
        "SDKROOT = iphoneos;",
        "SWIFT_VERSION = 5.0;",
    ]
    project_debug_settings = project_common + [
        "DEBUG_INFORMATION_FORMAT = dwarf;",
        "ENABLE_TESTABILITY = YES;",
        "GCC_DYNAMIC_NO_PIC = NO;",
        "GCC_OPTIMIZATION_LEVEL = 0;",
        "GCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\", );",
        "MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;",
        "ONLY_ACTIVE_ARCH = YES;",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;",
        "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
    ]
    project_release_settings = project_common + [
        "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";",
        "ENABLE_NS_ASSERTIONS = NO;",
        "SWIFT_COMPILATION_MODE = wholemodule;",
        "SWIFT_OPTIMIZATION_LEVEL = \"-O\";",
        "VALIDATE_PRODUCT = YES;",
    ]
    target_common = [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;",
        "CODE_SIGN_STYLE = Automatic;",
        "CURRENT_PROJECT_VERSION = 27;",
        "DEVELOPMENT_TEAM = \"\";",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        "INFOPLIST_FILE = OutdoorPhotoAssistant/Info.plist;",
        "IPHONEOS_DEPLOYMENT_TARGET = 17.6;",
        "LD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\", );",
        "MARKETING_VERSION = 1.1;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};",
        "PRODUCT_NAME = \"$(TARGET_NAME)\";",
        "SWIFT_VERSION = 5.0;",
        "TARGETED_DEVICE_FAMILY = 1;",
    ]

    def configuration(cid: str, name: str, settings: list[str]) -> None:
        body = " ".join(settings)
        add(
            f"\t\t{cid} /* {name} */ = {{isa = XCBuildConfiguration; buildSettings = "
            f"{{ {body} }}; name = {name}; }};"
        )

    configuration(project_debug, "Debug", project_debug_settings)
    configuration(project_release, "Release", project_release_settings)
    configuration(target_debug, "Debug", target_common)
    configuration(target_release, "Release", target_common)
    add("/* End XCBuildConfiguration section */")
    add("")

    add("/* Begin XCConfigurationList section */")
    add(
        f"\t\t{project_cfg_list} = {{isa = XCConfigurationList; buildConfigurations = ("
        f"{project_debug} /* Debug */, {project_release} /* Release */, ); "
        f"defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};"
    )
    add(
        f"\t\t{target_cfg_list} = {{isa = XCConfigurationList; buildConfigurations = ("
        f"{target_debug} /* Debug */, {target_release} /* Release */, ); "
        f"defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};"
    )
    add("/* End XCConfigurationList section */")
    add("")
    add("\t};")
    add(f"\trootObject = {project_id} /* Project object */;")
    add("}")

    ids = {
        "project": project_id,
        "target": target_id,
    }
    return "\n".join(out) + "\n", ids


def scheme(target_id: str) -> str:
    reference = (
        f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" '
        f'BuildableName="OutdoorPhotoAssistant.app" BlueprintName="OutdoorPhotoAssistant" '
        f'ReferencedContainer="container:OutdoorPhotoAssistant.xcodeproj"/>'
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            {reference}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         {reference}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         {reference}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
"""


def main() -> None:
    text, ids = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    SCHEME.parent.mkdir(parents=True, exist_ok=True)
    SCHEME.write_text(scheme(ids["target"]), encoding="utf-8")
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
    print(f"wrote {SCHEME} ({SCHEME.stat().st_size} bytes)")
    print(f"project={ids['project']} target={ids['target']}")


if __name__ == "__main__":
    main()
