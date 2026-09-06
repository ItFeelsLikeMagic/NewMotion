#!/usr/bin/env python3
"""Generate a local Xcode project when XcodeGen is not installed.

The generated project and schemes are ignored by Git. project.yml remains the
source of truth for installations that have XcodeGen available.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import shutil


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "PhoneRemote.xcodeproj"

# Override with PHONE_REMOTE_BUNDLE_PREFIX for a different signing account.
DEFAULT_BUNDLE_PREFIX = "com.davidliao.phoneremote"


def oid(key: str) -> str:
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:24].upper()


def quote(value: str) -> str:
    value = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{value}"'


def swift_paths(relative_directory: str) -> list[str]:
    """Return repository-relative Swift sources in stable order."""
    directory = ROOT / relative_directory
    if not directory.exists():
        return []
    return sorted(
        str(path.relative_to(ROOT))
        for path in directory.rglob("*.swift")
        if path.is_file()
    )


class Builder:
    def __init__(self) -> None:
        self.objects: dict[str, str] = {}
        self.order: list[str] = []

    def add(self, key: str, body: str) -> str:
        object_id = oid(key)
        if object_id in self.objects:
            raise RuntimeError(f"duplicate object: {key}")
        self.objects[object_id] = body
        self.order.append(object_id)
        return object_id

    def file(self, path: str, file_type: str = "sourcecode.swift", product: bool = False) -> str:
        if product:
            body = f"""{{
            isa = PBXFileReference;
            explicitFileType = {file_type};
            includeInIndex = 0;
            path = {quote(path)};
            sourceTree = BUILT_PRODUCTS_DIR;
        }}"""
        else:
            body = f"""{{
            isa = PBXFileReference;
            lastKnownFileType = {file_type};
            path = {quote(path)};
            sourceTree = \"<group>\";
        }}"""
        return self.add(f"file:{path}:{product}", body)

    def group(self, name: str, children: list[str], path: str | None = None) -> str:
        child_text = "\n".join(f"                {child}," for child in children)
        path_text = f"            path = {quote(path)};\n" if path else ""
        body = f"""{{
            isa = PBXGroup;
            children = (
{child_text}
            );
{path_text}            name = {quote(name)};
            sourceTree = \"<group>\";
        }}"""
        return self.add(f"group:{name}:{path or ''}", body)

    def build_file(self, file_ref: str, label: str, settings: str | None = None) -> str:
        settings_text = f"            settings = {settings};\n" if settings else ""
        body = f"""{{
            isa = PBXBuildFile;
            fileRef = {file_ref};
{settings_text}        }}"""
        return self.add(f"build:{label}:{file_ref}:{settings or ''}", body)

    def phase(self, phase_type: str, files: list[str], label: str, *, destination: int | None = None) -> str:
        file_text = "\n".join(f"                {file_id}," for file_id in files)
        destination_text = ""
        if destination is not None:
            destination_text = f"            dstPath = \"\";\n            dstSubfolderSpec = {destination};\n            name = {quote(label)};\n"
        body = f"""{{
            isa = {phase_type};
            buildActionMask = 2147483647;
            files = (
{file_text}
            );
{destination_text}            runOnlyForDeploymentPostprocessing = 0;
        }}"""
        return self.add(f"phase:{label}:{phase_type}:{','.join(files)}", body)

    def configuration(self, name: str, settings: dict[str, str]) -> str:
        lines = []
        for key, value in settings.items():
            if value in {"YES", "NO"} or value.isdigit() or value.startswith("-"):
                lines.append(f"                {key} = {value};")
            elif value.startswith("("):
                lines.append(f"                {key} = {value};")
            else:
                lines.append(f"                {key} = {quote(value)};")
        body = f"""{{
            isa = XCBuildConfiguration;
            buildSettings = {{
{chr(10).join(lines)}
            }};
            name = {quote(name)};
        }}"""
        settings_key = ",".join(f"{key}={value}" for key, value in settings.items())
        return self.add(f"config:{name}:{settings_key}", body)

    def config_list(self, name: str, configs: list[str]) -> str:
        config_text = "\n".join(f"                {config_id}," for config_id in configs)
        body = f"""{{
            isa = XCConfigurationList;
            buildConfigurations = (
{config_text}
            );
            defaultConfigurationIsVisible = 0;
            defaultConfigurationName = \"Debug\";
        }}"""
        return self.add(f"config-list:{name}", body)

    def dependency(self, target_id: str, project_id: str, target_name: str, owner_name: str) -> str:
        proxy = self.add(
            f"proxy:{owner_name}:{target_name}",
            f"""{{
            isa = PBXContainerItemProxy;
            containerPortal = {project_id};
            proxyType = 1;
            remoteGlobalIDString = {target_id};
            remoteInfo = {quote(target_name)};
        }}""",
        )
        return self.add(
            f"dependency:{owner_name}:{target_name}",
            f"""{{
            isa = PBXTargetDependency;
            target = {target_id};
            targetProxy = {proxy};
        }}""",
        )

    def target(
        self,
        *,
        name: str,
        product_name: str,
        product_type: str,
        source_refs: list[str],
        product_ref: str,
        config_list: str,
        framework_refs: list[str] | None = None,
        dependencies: list[str] | None = None,
        embed_refs: list[str] | None = None,
        resource_refs: list[str] | None = None,
    ) -> str:
        source_files = [self.build_file(ref, f"{name}:source:{index}") for index, ref in enumerate(source_refs)]
        source_phase = self.phase("PBXSourcesBuildPhase", source_files, f"{name}:sources")
        framework_files = [self.build_file(ref, f"{name}:framework:{index}") for index, ref in enumerate(framework_refs or [])]
        framework_phase = self.phase("PBXFrameworksBuildPhase", framework_files, f"{name}:frameworks")
        resource_files = [self.build_file(ref, f"{name}:resource:{index}") for index, ref in enumerate(resource_refs or [])]
        resource_phase = self.phase("PBXResourcesBuildPhase", resource_files, f"{name}:resources")
        phases = [source_phase, framework_phase, resource_phase]
        if embed_refs:
            embed_files = [
                self.build_file(
                    ref,
                    f"{name}:embed:{index}",
                    "{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy);}",
                )
                for index, ref in enumerate(embed_refs)
            ]
            phases.append(self.phase("PBXCopyFilesBuildPhase", embed_files, f"{name}:embed", destination=10))
        phase_text = "\n".join(f"                {phase_id}," for phase_id in phases)
        dependency_text = "\n".join(f"                {dep}," for dep in dependencies or [])
        body = f"""{{
            isa = PBXNativeTarget;
            buildConfigurationList = {config_list};
            buildPhases = (
{phase_text}
            );
            buildRules = (
            );
            dependencies = (
{dependency_text}
            );
            name = {quote(name)};
            productName = {quote(product_name)};
            productReference = {product_ref};
            productType = {quote(product_type)};
        }}"""
        return self.add(f"target:{name}", body)


def base_settings(kind: str, release: bool = False) -> dict[str, str]:
    settings = {
        "ARCHS": "arm64",
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "CODE_SIGN_STYLE": "Manual",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "MARKETING_VERSION": "0.1.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_VERSION": "6.0",
    }
    bundle_prefix = os.environ.get("PHONE_REMOTE_BUNDLE_PREFIX", DEFAULT_BUNDLE_PREFIX)
    if kind == "shared":
        settings.update({
            "DEFINES_MODULE": "YES",
            "GENERATE_INFOPLIST_FILE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "LD_DYLIB_INSTALL_NAME": "@rpath/PhoneRemoteShared.framework/PhoneRemoteShared",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "PRODUCT_BUNDLE_IDENTIFIER": f"{bundle_prefix}.shared",
            "PRODUCT_NAME": "PhoneRemoteShared",
            "SKIP_INSTALL": "YES",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
        })
    elif kind == "ios":
        settings.update({
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGN_IDENTITY": "",
            "ENABLE_TESTABILITY": "YES",
            "INFOPLIST_FILE": "Config/iPhone-Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
            "PRODUCT_BUNDLE_IDENTIFIER": f"{bundle_prefix}.ios",
            "PRODUCT_MODULE_NAME": "PhoneRemote_iOS",
            "PRODUCT_NAME": "PhoneRemote",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO",
            "TARGETED_DEVICE_FAMILY": "1",
        })
    elif kind == "mac":
        settings.update({
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "CODE_SIGN_IDENTITY": "",
            "ENABLE_DEBUG_DYLIB": "NO",
            # Notarization refuses a build without the hardened runtime.
            "ENABLE_HARDENED_RUNTIME": "YES",
            "ENABLE_TESTABILITY": "YES",
            "INFOPLIST_FILE": "Config/Mac-Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @executable_path/Frameworks",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "PRODUCT_BUNDLE_IDENTIFIER": f"{bundle_prefix}.macos",
            "PRODUCT_MODULE_NAME": "PhoneRemote_macOS",
            "PRODUCT_NAME": "PhoneRemoteMac",
            "SUPPORTED_PLATFORMS": "macosx",
        })
    elif kind == "ios-test":
        settings.update({
            "BUNDLE_LOADER": "$(TEST_HOST)",
            "GENERATE_INFOPLIST_FILE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "PRODUCT_BUNDLE_IDENTIFIER": f"{bundle_prefix}.ios-tests",
            "PRODUCT_NAME": "PhoneRemoteiOSTests",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/PhoneRemote.app/PhoneRemote",
        })
    elif kind == "mac-test":
        settings.update({
            "BUNDLE_LOADER": "$(TEST_HOST)",
            "GENERATE_INFOPLIST_FILE": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "PRODUCT_BUNDLE_IDENTIFIER": f"{bundle_prefix}.macos-tests",
            "PRODUCT_NAME": "PhoneRemoteMacTests",
            "SUPPORTED_PLATFORMS": "macosx",
            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/PhoneRemoteMac.app/Contents/MacOS/PhoneRemoteMac",
        })
    elif kind == "shared-test":
        settings.update({
            "GENERATE_INFOPLIST_FILE": "YES",
            # No test host to embed the framework, so the bundle loads it from
            # the build products directory three levels above the executable.
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @loader_path/../../..",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "PRODUCT_BUNDLE_IDENTIFIER": f"{bundle_prefix}.shared-tests",
            "PRODUCT_NAME": "PhoneRemoteSharedTests",
            "SUPPORTED_PLATFORMS": "macosx",
        })
    else:
        raise ValueError(kind)
    settings["SWIFT_OPTIMIZATION_LEVEL"] = "-O" if release else "-Onone"
    if not release:
        # Debug-only code (the on-screen debug log) is compiled out of Release.
        settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        settings["GCC_OPTIMIZATION_LEVEL"] = "0"
        if kind == "shared":
            settings["ENABLE_TESTABILITY"] = "YES"
    return settings


def scheme(name: str, target_id: str) -> str:
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
    <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        <BuildActionEntries>
            <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{name}" BlueprintName="{name}" ReferencedContainer="container:PhoneRemote.xcodeproj"/>
            </BuildActionEntry>
        </BuildActionEntries>
    </BuildAction>
    <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
        <Testables>
            <TestableReference skipped="NO">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{name}.xctest" BlueprintName="{name}" ReferencedContainer="container:PhoneRemote.xcodeproj"/>
            </TestableReference>
        </Testables>
    </TestAction>
    <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersion="0" debugServiceExtension="internal" allowLocationSimulation="YES"/>
    <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersion="0"/>
    <AnalyzeAction buildConfiguration="Debug"/>
    <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''


def generate() -> None:
    if PROJECT_DIR.exists():
        shutil.rmtree(PROJECT_DIR)
    PROJECT_DIR.mkdir(parents=True)
    b = Builder()

    project_id = oid("project:PhoneRemote")
    root_files = [
        b.file("project.yml", "text.yaml"),
        b.file("README.md", "net.daringfireball.markdown"),
    ]
    config_files = [
        b.file("Config/iPhone-Info.plist", "text.plist.xml"),
        b.file("Config/Mac-Info.plist", "text.plist.xml"),
    ]
    source_paths = {
        # Include future shared protocol/crypto sources automatically. Feature
        # agents can add files below these roots without editing this fallback.
        "shared": swift_paths("Shared"),
        "ios": swift_paths("iPhone"),
        "mac": swift_paths("Mac"),
        "shared-tests": swift_paths("Tests/Shared"),
        "ios-test": swift_paths("Tests/iOS"),
        "mac-test": swift_paths("Tests/macOS"),
    }
    refs = {path: b.file(path) for paths in source_paths.values() for path in paths}
    # The app icon and the privacy manifest are copied, not compiled, so they
    # ride the iOS target's resources phase rather than its sources phase.
    ios_resources = [
        b.file("iPhone/Resources/Assets.xcassets", "folder.assetcatalog"),
        b.file("iPhone/Resources/PrivacyInfo.xcprivacy", "text.plist.xml"),
    ]
    mac_resources = [b.file("Mac/Resources/Assets.xcassets", "folder.assetcatalog")]
    shared_protocol = [path for path in source_paths["shared"] if path.startswith("Shared/Protocol/")]
    shared_transport = [path for path in source_paths["shared"] if path.startswith("Shared/TestTransport/")]
    shared_observability = [path for path in source_paths["shared"] if path.startswith("Shared/Observability/")]
    groups = {
        # File references retain repository-relative paths, so these logical
        # groups intentionally have no physical path (otherwise Xcode would
        # prepend the group path a second time).
        "protocol": b.group("Protocol", [refs[path] for path in shared_protocol]),
        "transport": b.group("TestTransport", [refs[path] for path in shared_transport]),
        "observability": b.group("Observability", [refs[path] for path in shared_observability]),
        "ios": b.group("iPhone", [refs[path] for path in source_paths["ios"]] + ios_resources),
        "mac": b.group("Mac", [refs[path] for path in source_paths["mac"]] + mac_resources),
        "shared-tests": b.group("SharedTests", [refs[path] for path in source_paths["shared-tests"]]),
        "ios-test": b.group("iOSTests", [refs[path] for path in source_paths["ios-test"]]),
        "mac-test": b.group("macOSTests", [refs[path] for path in source_paths["mac-test"]]),
    }
    groups["shared"] = b.group("Shared", [groups["protocol"], groups["transport"], groups["observability"]])
    groups["tests"] = b.group("Tests", [groups["shared-tests"], groups["ios-test"], groups["mac-test"]])
    groups["config"] = b.group("Config", config_files)
    products_group = b.group("Products", [])
    groups["root"] = b.group("PhoneRemote", root_files + [groups["config"], groups["shared"], groups["ios"], groups["mac"], groups["tests"], products_group])

    products = {
        "shared": b.file("PhoneRemoteShared.framework", "wrapper.framework", True),
        "ios": b.file("PhoneRemote.app", "wrapper.application", True),
        "mac": b.file("PhoneRemoteMac.app", "wrapper.application", True),
        "shared-tests": b.file("PhoneRemoteSharedTests.xctest", "wrapper.cfbundle", True),
        "ios-test": b.file("PhoneRemoteiOSTests.xctest", "wrapper.cfbundle", True),
        "mac-test": b.file("PhoneRemoteMacTests.xctest", "wrapper.cfbundle", True),
    }
    # Products are referenced by the build graph but also shown in the root
    # group, matching an Xcode-generated project.
    old_products = b.objects[products_group]
    product_text = "\n".join(f"                {ref}," for ref in products.values())
    b.objects[products_group] = old_products.replace("            );", f"{product_text}\n            );", 1)

    kinds = {"shared": "shared", "ios": "ios", "mac": "mac", "shared-tests": "shared-test", "ios-test": "ios-test", "mac-test": "mac-test"}
    config_lists: dict[str, str] = {}
    for key, kind in kinds.items():
        debug = b.configuration("Debug", base_settings(kind))
        release = b.configuration("Release", base_settings(kind, release=True))
        config_lists[key] = b.config_list(f"{key}:configs", [debug, release])

    names = {"shared": "PhoneRemoteShared", "ios": "PhoneRemote-iOS", "mac": "PhoneRemote-macOS", "shared-tests": "PhoneRemoteSharedTests", "ios-test": "PhoneRemote-iOSTests", "mac-test": "PhoneRemote-macOSTests"}
    target_ids = {key: oid(f"target:{name}") for key, name in names.items()}
    dependency_specs = {"ios": ["shared"], "mac": ["shared"], "shared-tests": ["shared"], "ios-test": ["ios", "shared"], "mac-test": ["mac", "shared"]}
    dependencies = {
        key: [b.dependency(target_ids[dep], project_id, names[dep], names[key]) for dep in deps]
        for key, deps in dependency_specs.items()
    }
    product_types = {
        "shared": "com.apple.product-type.framework",
        "ios": "com.apple.product-type.application",
        "mac": "com.apple.product-type.application",
        "shared-tests": "com.apple.product-type.bundle.unit-test",
        "ios-test": "com.apple.product-type.bundle.unit-test",
        "mac-test": "com.apple.product-type.bundle.unit-test",
    }
    embeds = {"ios": [products["shared"]], "mac": [products["shared"]]}
    for key in names:
        target_id = b.target(
            name=names[key],
            product_name=names[key],
            product_type=product_types[key],
            source_refs=[refs[path] for path in source_paths[key if key in source_paths else key]],
            product_ref=products[key],
            config_list=config_lists[key],
            framework_refs=[products["shared"]] if key != "shared" else [],
            dependencies=dependencies.get(key),
            embed_refs=embeds.get(key),
            resource_refs={"ios": ios_resources, "mac": mac_resources}.get(key),
        )
        if target_id != target_ids[key]:
            raise RuntimeError(f"target ID mismatch for {key}")

    project_debug = b.configuration("Debug", {"SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete"})
    project_release = b.configuration("Release", {"SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete"})
    project_configs = b.config_list("project:configs", [project_debug, project_release])
    targets_text = "\n".join(f"                {target_id}," for target_id in target_ids.values())
    b.objects[project_id] = f"""{{
            isa = PBXProject;
            attributes = {{
                LastSwiftUpdateCheck = 2700;
                LastUpgradeCheck = 2700;
                ORGANIZATIONNAME = PhoneRemote;
                TargetAttributes = {{
                }};
            }};
            buildConfigurationList = {project_configs};
            compatibilityVersion = \"Xcode 3.2\";
            developmentRegion = en;
            hasScannedForEncodings = 0;
            knownRegions = (
                en,
                Base,
            );
            mainGroup = {groups['root']};
            productRefGroup = {products_group};
            projectDirPath = \"\";
            projectRoot = \"\";
            targets = (
{targets_text}
            );
        }}"""
    b.order.append(project_id)

    lines = ["// !$*UTF8*$!", "{", "    archiveVersion = 1;", "    classes = {};", "    objectVersion = 77;", "    objects = {"]
    lines.extend(f"        {object_id} = {b.objects[object_id]};" for object_id in b.order)
    lines.extend(["    };", f"    rootObject = {project_id};", "}", ""])
    (PROJECT_DIR / "project.pbxproj").write_text("\n".join(lines), encoding="utf-8")

    schemes_dir = PROJECT_DIR / "xcshareddata" / "xcschemes"
    schemes_dir.mkdir(parents=True)
    for key in ("shared-tests", "mac-test", "ios-test"):
        scheme_name = names[key]
        (schemes_dir / f"{scheme_name}.xcscheme").write_text(scheme(scheme_name, target_ids[key]), encoding="utf-8")
    print(f"Generated {PROJECT_DIR}")


if __name__ == "__main__":
    generate()
