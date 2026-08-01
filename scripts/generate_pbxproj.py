#!/usr/bin/env python3
"""Generate PureReader.xcodeproj/project.pbxproj by scanning PureReader/**/*.swift"""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "PureReader"
PROJ = ROOT / "PureReader.xcodeproj"
OUT = PROJ / "project.pbxproj"

# Some community sources in the supported XIU2/Yuedu collection are HTTP-only.
# ATS exceptions are narrowly scoped to those exact hosts in PureReader/Info.plist.
# Do not replace them with a global NSAllowsArbitraryLoads exception.
# API-key services still enforce HTTPS in code; see AIConfig.isTransportAcceptable.
BUNDLE_ID = "com.wynx.PureReader"
DISPLAY_NAME = "纯享阅读"
DEPLOY = "17.0"
MARKETING = "1.0"
BUILD = "1"


def uid(key: str) -> str:
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def main() -> None:
    swift_files = sorted(SRC.rglob("*.swift"))
    assert swift_files, "no swift files"
    assets = SRC / "Resources" / "Assets.xcassets"
    assert assets.is_dir()

    # IDs
    project_id = uid("PROJECT")
    target_id = uid("TARGET")
    sources_phase = uid("SOURCES")
    resources_phase = uid("RESOURCES")
    frameworks_phase = uid("FRAMEWORKS")
    product_ref = uid("PRODUCT_REF")
    main_group = uid("MAIN_GROUP")
    products_group = uid("PRODUCTS_GROUP")
    src_root_group = uid("SRC_ROOT_GROUP")
    conf_list_project = uid("CONFLIST_PROJECT")
    conf_list_target = uid("CONFLIST_TARGET")
    conf_proj_debug = uid("CONF_PROJ_DEBUG")
    conf_proj_release = uid("CONF_PROJ_RELEASE")
    conf_tgt_debug = uid("CONF_TGT_DEBUG")
    conf_tgt_release = uid("CONF_TGT_RELEASE")
    tests_target_id = uid("TESTS_TARGET")
    tests_sources_phase = uid("TESTS_SOURCES")
    tests_frameworks_phase = uid("TESTS_FRAMEWORKS")
    tests_product_ref = uid("TESTS_PRODUCT_REF")
    conf_list_tests = uid("CONFLIST_TESTS")
    conf_tests_debug = uid("CONF_TESTS_DEBUG")
    conf_tests_release = uid("CONF_TESTS_RELEASE")

    # Build file / file ref for each swift
    file_entries: list[tuple[str, Path, str, str]] = []  # name, path, file_ref, build_file
    for p in swift_files:
        rel = p.relative_to(SRC).as_posix()
        name = p.name
        fr = uid(f"FR:{rel}")
        bf = uid(f"BF:{rel}")
        file_entries.append((name, p.relative_to(SRC), fr, bf))

    tests_dir = ROOT / "PureReaderTests"
    # 注意：iSH 沙箱中新建目录的枚举（glob/readdir）可能不可见，
    # 因此用固定文件名 + 单文件 stat 判定，避免依赖目录枚举。
    test_entries: list[tuple[str, object, str, str]] = []
    for name in ("RuleParserTests.swift", "OnlineLibraryServiceTests.swift"):
        if (tests_dir / name).is_file():
            test_entries.append((name, tests_dir / name, uid(f"FR:T:{name}"), uid(f"BF:T:{name}")))

    assets_fr = uid("FR:Assets.xcassets")
    assets_bf = uid("BF:Assets.xcassets")

    # 内置书源 JSON（Resources/Sources/*.json）作为资源打进 App Bundle，
    # 首次启动时由 BookSourceImporter.seedBuiltInIfNeeded 导入。
    sources_dir = SRC / "Resources" / "Sources"
    # 以 folder reference 打包：Bundle 内保留 Sources/ 目录结构，
    # BookSourceImporter.seedBuiltInIfNeeded 用 Bundle.main.url(forResource: "Sources") 定位。
    sources_folder_ref = uid("FR:SRC:DIR")
    sources_folder_bf = uid("BF:SRC:DIR")
    has_sources_folder = sources_dir.is_dir() and any(sources_dir.glob("*.json"))

    lines: list[str] = []
    w = lines.append

    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    # PBXBuildFile
    w("/* Begin PBXBuildFile section */")
    for name, rel, fr, bf in file_entries:
        w(f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")
    if has_sources_folder:
        w(f"\t\t{sources_folder_bf} /* Sources in Resources */ = {{isa = PBXBuildFile; fileRef = {sources_folder_ref} /* Sources */; }};")
    w(f"\t\t{assets_bf} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_fr} /* Assets.xcassets */; }};")
    w("/* End PBXBuildFile section */")

    # PBXFileReference
    w("/* Begin PBXFileReference section */")
    w(
        f'\t\t{product_ref} /* PureReader.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PureReader.app; sourceTree = BUILT_PRODUCTS_DIR; }};'
    )
    for name, rel, fr, bf in file_entries:
        quoted = name if all(c.isalnum() or c in "._-" for c in name) else f'"{name}"'
        w(
            f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted}; sourceTree = "<group>"; }};'
        )
    if has_sources_folder:
        w(
            f'\t\t{sources_folder_ref} /* Sources */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = Sources; sourceTree = "<group>"; }};'
        )
    for name, rel, fr, bf in test_entries:
        w(
            f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};'
        )
    if test_entries:
        w(
            f'\t\t{tests_product_ref} /* PureReaderTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = PureReaderTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};'
        )
    w(
        f'\t\t{assets_fr} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};'
    )
    w("/* End PBXFileReference section */")

    # Groups: mirror directory structure under PureReader/
    # Collect directories
    dir_to_children: dict[str, list[tuple[str, str, bool]]] = {}
    # value: (id, comment, is_group)

    def ensure_dir(d: str) -> str:
        if d not in dir_to_children:
            dir_to_children[d] = []
            # register in parent
            if d != ".":
                parent = str(Path(d).parent.as_posix()) if Path(d).parent.as_posix() != "." else "."
                # parent may be "" for top
                if parent == "":
                    parent = "."
                ensure_dir(parent)
                gid = uid(f"GRP:{d}")
                # avoid dup
                if not any(x[0] == gid for x in dir_to_children[parent]):
                    dir_to_children[parent].append((gid, Path(d).name, True))
        return uid(f"GRP:{d}") if d != "." else src_root_group

    ensure_dir(".")
    for name, rel, fr, bf in file_entries:
        parent = str(rel.parent.as_posix()) if rel.parent.as_posix() != "." else "."
        ensure_dir(parent)
        dir_to_children[parent].append((fr, name, False))

    # Assets under Resources
    ensure_dir("Resources")
    dir_to_children["Resources"].append((assets_fr, "Assets.xcassets", False))
    # 内置书源 under Resources/Sources（folder reference）
    if has_sources_folder:
        dir_to_children["Resources"].append((sources_folder_ref, "Sources", False))
    if test_entries:
        ensure_dir("PureReaderTests")
        for name, rel, fr, bf in test_entries:
            dir_to_children["PureReaderTests"].append((fr, name, False))

    w("/* Begin PBXGroup section */")
    # Main group
    w(f"\t\t{main_group} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{src_root_group} /* PureReader */,")
    w(f"\t\t\t\t{products_group} /* Products */,")
    w("\t\t\t);")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")
    w(f"\t\t{products_group} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{product_ref} /* PureReader.app */,")
    if test_entries:
        w(f"\t\t\t\t{tests_product_ref} /* PureReaderTests.xctest */,")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w('\t\t\tsourceTree = "<group>";')
    w("\t\t};")

    # Emit each dir group
    for d, children in sorted(dir_to_children.items(), key=lambda x: x[0]):
        gid = src_root_group if d == "." else uid(f"GRP:{d}")
        name = "PureReader" if d == "." else Path(d).name
        w(f"\t\t{gid} /* {name} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        # sort: groups first then files
        groups = [c for c in children if c[2]]
        files = [c for c in children if not c[2]]
        # de-dup by id
        seen = set()
        ordered = []
        for item in groups + files:
            if item[0] in seen:
                continue
            seen.add(item[0])
            ordered.append(item)
        for cid, cname, _ in ordered:
            w(f"\t\t\t\t{cid} /* {cname} */,")
        w("\t\t\t);")
        if d == ".":
            w("\t\t\tpath = PureReader;")
        else:
            w(f"\t\t\tpath = {name};")
        w('\t\t\tsourceTree = "<group>";')
        w("\t\t};")
    w("/* End PBXGroup section */")

    # Native target
    w("/* Begin PBXNativeTarget section */")
    w(f"\t\t{target_id} /* PureReader */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {conf_list_target} /* Build configuration list for PBXNativeTarget \"PureReader\" */;")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{sources_phase} /* Sources */,")
    w(f"\t\t\t\t{frameworks_phase} /* Frameworks */,")
    w(f"\t\t\t\t{resources_phase} /* Resources */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w("\t\t\tname = PureReader;")
    w(f"\t\t\tproductName = PureReader;")
    w(f"\t\t\tproductReference = {product_ref} /* PureReader.app */;")
    w('\t\t\tproductType = "com.apple.product-type.application";')
    w("\t\t};")
    if test_entries:
        w(f"\t\t{tests_target_id} /* PureReaderTests */ = {{")
        w("\t\t\tisa = PBXNativeTarget;")
        w(f"\t\t\tbuildConfigurationList = {conf_list_tests} /* Build configuration list for PBXNativeTarget \"PureReaderTests\" */;")
        w("\t\t\tbuildPhases = (")
        w(f"\t\t\t\t{tests_sources_phase} /* Sources */,")
        w(f"\t\t\t\t{tests_frameworks_phase} /* Frameworks */,")
        w("\t\t\t);")
        w("\t\t\tbuildRules = (")
        w("\t\t\t);")
        w("\t\t\tdependencies = (")
        w("\t\t\t);")
        w("\t\t\tname = PureReaderTests;")
        w("\t\t\tproductName = PureReaderTests;")
        w(f"\t\t\tproductReference = {tests_product_ref} /* PureReaderTests.xctest */;")
        w('\t\t\tproductType = "com.apple.product-type.bundle.unit-test";')
        w("\t\t};")
    w("/* End PBXNativeTarget section */")

    # Project
    w("/* Begin PBXProject section */")
    w(f"\t\t{project_id} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w('\t\t\t\tLastSwiftUpdateCheck = 1620;')
    w("\t\t\t\tLastUpgradeCheck = 1620;")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {conf_list_project} /* Build configuration list for PBXProject \"PureReader\" */;")
    w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    w("\t\t\tdevelopmentRegion = \"zh-Hans\";")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t\t\"zh-Hans\",")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {main_group};")
    w(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w("\t\t\ttargets = (")
    w(f"\t\t\t\t{target_id} /* PureReader */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    # Sources
    w("/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{sources_phase} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for name, rel, fr, bf in file_entries:
        w(f"\t\t\t\t{bf} /* {name} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    if test_entries:
        w(f"\t\t{tests_sources_phase} /* Sources */ = {{")
        w("\t\t\tisa = PBXSourcesBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        for name, rel, fr, bf in test_entries:
            w(f"\t\t\t\t{bf} /* {name} in Sources */,")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")

    # Frameworks empty
    w("/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{frameworks_phase} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    if test_entries:
        w(f"\t\t{tests_frameworks_phase} /* Frameworks */ = {{")
        w("\t\t\tisa = PBXFrameworksBuildPhase;")
        w("\t\t\tbuildActionMask = 2147483647;")
        w("\t\t\tfiles = (")
        w("\t\t\t);")
        w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")

    # Resources
    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{resources_phase} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    if has_sources_folder:
        w(f"\t\t\t\t{sources_folder_bf} /* Sources in Resources */,")
    w(f"\t\t\t\t{assets_bf} /* Assets.xcassets in Resources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")

    # Build configurations
    common_target = f"""
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGNING_ALLOWED = NO;
				CODE_SIGNING_REQUIRED = NO;
				CODE_SIGN_STYLE = Manual;
				CURRENT_PROJECT_VERSION = {BUILD};
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = PureReader/Info.plist;
				INFOPLIST_KEY_LSRequiresIPhoneOS = YES;
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIBackgroundModes = "audio";
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = {MARKETING};
				PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
				PRODUCT_NAME = "$(TARGET_NAME)";
				PROVISIONING_PROFILE_SPECIFIER = "";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
"""

    w("/* Begin XCBuildConfiguration section */")
    for conf_id, name, is_debug in [
        (conf_proj_debug, "Debug", True),
        (conf_proj_release, "Release", False),
    ]:
        w(f"\t\t{conf_id} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        w("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
        w("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
        w("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
        w(f"\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = {DEPLOY};")
        w("\t\t\t\tONLY_ACTIVE_ARCH = YES;" if is_debug else "\t\t\t\tONLY_ACTIVE_ARCH = NO;")
        w("\t\t\t\tSDKROOT = iphoneos;")
        if is_debug:
            w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
            w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
            w("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
            w("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
            w('\t\t\t\t\t"DEBUG=1",')
            w("\t\t\t\t\t\"$(inherited)\",")
            w("\t\t\t\t);")
        else:
            w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
            w('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
            w("\t\t\t\tVALIDATE_PRODUCT = YES;")
        w("\t\t\t};")
        w(f'\t\t\tname = {name};')
        w("\t\t};")

    for conf_id, name in [(conf_tgt_debug, "Debug"), (conf_tgt_release, "Release")]:
        w(f"\t\t{conf_id} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        for line in common_target.strip("\n").splitlines():
            w(line)
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")
    if test_entries:
        tests_settings = [
            "ALWAYS_SEARCH_USER_PATHS = NO;",
            'BUNDLE_LOADER = "$(TEST_HOST)";',
            "CLANG_ENABLE_MODULES = YES;",
            'CODE_SIGN_STYLE = Automatic;',
            'CURRENT_PROJECT_VERSION = 1;',
            "DEVELOPMENT_TEAM = "";",
            'GENERATE_INFOPLIST_FILE = YES;',
            "IPHONEOS_DEPLOYMENT_TARGET = 17.0;",
            "LD_RUNPATH_SEARCH_PATHS = (",
            '\t\t\t\t"$(inherited)",',
            '\t\t\t\t"@executable_path/Frameworks",',
            '\t\t\t\t"@loader_path/Frameworks",',
            "\t\t\t);",
            "MARKETING_VERSION = 1.0;",
            "PRODUCT_BUNDLE_IDENTIFIER = com.purereader.tests;",
            "PRODUCT_NAME = \"$(TARGET_NAME)\";",
            "SDKROOT = iphoneos;",
            "SWIFT_VERSION = 5.0;",
            "TARGETED_DEVICE_FAMILY = \"1,2\";",
            "TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/PureReader.app/PureReader\";",
        ]
        for conf_id, name, is_debug in [
            (conf_tests_debug, "Debug", True),
            (conf_tests_release, "Release", False),
        ]:
            w(f"\t\t{conf_id} /* {name} */ = {{")
            w("\t\t\tisa = XCBuildConfiguration;")
            w("\t\t\tbuildSettings = {")
            for line in tests_settings:
                w(line)
            if is_debug:
                w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;")
                w('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
                w("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
            else:
                w('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";')
                w('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
                w("\t\t\t\tVALIDATE_PRODUCT = YES;")
            w("\t\t\t};")
            w(f"\t\t\tname = {name};")
            w("\t\t};")
    w("/* End XCBuildConfiguration section */")

    # Config lists
    w("/* Begin XCConfigurationList section */")
    w(f'\t\t{conf_list_project} /* Build configuration list for PBXProject "PureReader" */ = {{')
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{conf_proj_debug} /* Debug */,")
    w(f"\t\t\t\t{conf_proj_release} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w('\t\t\tdefaultConfigurationName = Release;')
    w("\t\t};")
    w(f'\t\t{conf_list_target} /* Build configuration list for PBXNativeTarget "PureReader" */ = {{')
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w(f"\t\t\t\t{conf_tgt_debug} /* Debug */,")
    w(f"\t\t\t\t{conf_tgt_release} /* Release */,")
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w('\t\t\tdefaultConfigurationName = Release;')
    w("\t\t};")
    if test_entries:
        w(f'\t\t{conf_list_tests} /* Build configuration list for PBXNativeTarget "PureReaderTests" */ = {{')
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w(f"\t\t\t\t{conf_tests_debug} /* Debug */,")
        w(f"\t\t\t\t{conf_tests_release} /* Release */,")
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")

    w("\t};")
    w(f"\trootObject = {project_id} /* Project object */;")
    w("}")

    PROJ.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {OUT} with {len(swift_files)} swift sources")
    for p in swift_files:
        print(" ", p.relative_to(ROOT))


if __name__ == "__main__":
    main()
