#!/usr/bin/env python3
"""Generate PureReader.xcodeproj/project.pbxproj by scanning PureReader/**/*.swift"""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "PureReader"
PROJ = ROOT / "PureReader.xcodeproj"
OUT = PROJ / "project.pbxproj"

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

    # Build file / file ref for each swift
    file_entries: list[tuple[str, Path, str, str]] = []  # name, path, file_ref, build_file
    for p in swift_files:
        rel = p.relative_to(SRC).as_posix()
        name = p.name
        fr = uid(f"FR:{rel}")
        bf = uid(f"BF:{rel}")
        file_entries.append((name, p.relative_to(SRC), fr, bf))

    assets_fr = uid("FR:Assets.xcassets")
    assets_bf = uid("BF:Assets.xcassets")

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
    w("/* End PBXFrameworksBuildPhase section */")

    # Resources
    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{resources_phase} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
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
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = "{DISPLAY_NAME}";
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
