#!/usr/bin/env python3
"""Regenerate Forma's Xcode project with the local Apache-2.0 Metal training engine."""
from pathlib import Path
import os

root = Path(__file__).resolve().parent.parent
objects = []
def add(key, kind, body):
    objects.append(f'{key} = {{ isa = {kind}; {body} }};')

project='A00000000000000000000001'
main='A00000000000000000000002'
products='A00000000000000000000003'
project_configs='A00000000000000000000004'
native_group='A00000000000000000000005'
native_library='A00000000000000000000006'
native_buildfile='A00000000000000000000007'
native_verify='A00000000000000000000008'
add(native_verify, 'PBXShellScriptBuildPhase', 'buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); alwaysOutOfDate = 1; name = "Verify native Metal artifacts"; shellPath = /bin/sh; shellScript = "python3 \\"$SRCROOT/scripts/verify_msplat_bundle.py\\""; runOnlyForDeploymentPostprocessing = 0;')
add(native_group,'PBXGroup',f'children = ({native_library}); name = "Motor Gaussian local"; sourceTree = "<group>";')
add(native_library,'PBXFileReference','lastKnownFileType = wrapper.xcframework; path = Vendor/Msplat/Build/MsplatCore.xcframework; sourceTree = "<group>";')
add(native_buildfile,'PBXBuildFile',f'fileRef = {native_library};')
widget_target='E10000000000000000000001'
widget_product='E10000000000000000000002'
widget_group='E10000000000000000000003'
widget_sources='E10000000000000000000004'
widget_resources='E10000000000000000000005'
widget_frameworks='E10000000000000000000006'
widget_configs='E10000000000000000000007'
widget_dependency='E10000000000000000000008'
widget_proxy='E10000000000000000000009'
widget_embed='E10000000000000000000010'
widget_embed_file='E10000000000000000000011'
activity_ref='E10000000000000000000012'
activity_app_build='E10000000000000000000013'
activity_widget_build='E10000000000000000000014'
activity_group='E10000000000000000000015'
add(activity_ref,'PBXFileReference','lastKnownFileType = sourcecode.swift; path = Shared/ProcessingActivityAttributes.swift; sourceTree = SOURCE_ROOT;')
add(activity_app_build,'PBXBuildFile',f'fileRef = {activity_ref};')
add(activity_widget_build,'PBXBuildFile',f'fileRef = {activity_ref};')
add(activity_group,'PBXGroup',f'children = ({activity_ref}); name = "Actividad compartida"; sourceTree = "<group>";')
add(widget_embed_file,'PBXBuildFile',f'fileRef = {widget_product}; settings = {{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy); }};')
add(widget_embed,'PBXCopyFilesBuildPhase',f'buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({widget_embed_file}); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
add(widget_proxy,'PBXContainerItemProxy',f'containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {widget_target}; remoteInfo = FormaLiveActivity;')
add(widget_dependency,'PBXTargetDependency',f'target = {widget_target}; targetProxy = {widget_proxy};')
targets=[]
for n, name, folder, kind in [(1,'Forma','Forma','application'), (2,'FormaTests','Tests','bundle.unit-test'), (3,'FormaUITests','UITests','bundle.ui-testing')]:
    prefix=f'B{n}'
    key=lambda i: prefix+f'{i:022d}'
    target, group, product, sources, resources, frameworks, configs = [key(i) for i in range(1,8)]
    targets.append(target)
    add(group, 'PBXFileSystemSynchronizedRootGroup', f'path = {folder}; sourceTree = "<group>";')
    ext='app' if n==1 else 'xctest'
    add(product,'PBXFileReference',f'explicitFileType = {"wrapper.application" if n==1 else "wrapper.cfbundle"}; includeInIndex = 0; path = {name}.{ext}; sourceTree = BUILT_PRODUCTS_DIR;')
    for phase, typ in [(sources,'PBXSourcesBuildPhase'), (resources,'PBXResourcesBuildPhase'), (frameworks,'PBXFrameworksBuildPhase')]:
        linked = native_buildfile if n == 1 and typ == 'PBXFrameworksBuildPhase' else (activity_app_build if n == 1 and typ == 'PBXSourcesBuildPhase' else '')
        add(phase,typ,f'buildActionMask = 2147483647; files = ({linked}); runOnlyForDeploymentPostprocessing = 0;')
    dep=widget_dependency if n==1 else ''
    if n!=1:
        proxy, dependency=key(10),key(11)
        add(proxy,'PBXContainerItemProxy',f'containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {targets[0]}; remoteInfo = Forma;')
        add(dependency,'PBXTargetDependency',f'target = {targets[0]}; targetProxy = {proxy};')
        dep=dependency
    phases = (native_verify + ', ' if n == 1 else '') + f'{sources}, {frameworks}, {resources}' + (', '+widget_embed if n==1 else '')
    add(target,'PBXNativeTarget',f'buildConfigurationList = {configs}; buildPhases = ({phases}); buildRules = (); dependencies = ({dep}); fileSystemSynchronizedGroups = ({group}); name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.{kind}";')
    config_keys=[]
    for i, conf in enumerate(['Debug','Release']):
        ck=key(20+i);config_keys.append(ck)
        settings={
            'PRODUCT_BUNDLE_IDENTIFIER':f'com.robii.forma{("."+name) if n!=1 else ""}',
            'PRODUCT_NAME':'"$(TARGET_NAME)"', 'GENERATE_INFOPLIST_FILE':'YES',
            'SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'18.0','TARGETED_DEVICE_FAMILY':'"1,2"',
            'CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':'22','MARKETING_VERSION':'0.9.5',
            'ARCHS':'arm64',
            'SWIFT_EMIT_LOC_STRINGS':'YES', 'SUPPORTED_PLATFORMS':'"iphoneos iphonesimulator"',
            'DEVELOPMENT_TEAM': '"' + os.environ.get('FORMA_DEVELOPMENT_TEAM', '') + '"',
        }
        if n==1:
            settings.update({
                'INFOPLIST_KEY_CFBundleDisplayName':'Forma',
                'INFOPLIST_FILE':'Config/Forma-Info.plist',
                'CODE_SIGN_ENTITLEMENTS':'Config/Forma.entitlements',
                'OTHER_LDFLAGS':'("$(inherited)", "-lc++", "-lz", "-framework", Metal, "-framework", MetalKit, "-framework", MetalPerformanceShaders, "-framework", ImageIO, "-framework", CoreGraphics, "-framework", Accelerate)',
                'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
                'INFOPLIST_KEY_NSCameraUsageDescription':'"Forma utiliza la cámara y el LiDAR para crear tus modelos 3D en este dispositivo."',
                'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES',
                'INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
                'INFOPLIST_KEY_UIFileSharingEnabled':'YES',
                'INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace':'YES',
                'INFOPLIST_KEY_UISupportedInterfaceOrientations':'"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
            })
        elif n==2:
            settings.update({'TEST_HOST':'"$(BUILT_PRODUCTS_DIR)/Forma.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Forma"','BUNDLE_LOADER':'"$(TEST_HOST)"'})
        else: settings['TEST_TARGET_NAME']='Forma'
        add(ck,'XCBuildConfiguration',f'buildSettings = {{ {" ".join(f"{k} = {v};" for k,v in settings.items())} }}; name = {conf};')
    add(configs,'XCConfigurationList',f'buildConfigurations = ({", ".join(config_keys)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

add(widget_group,'PBXFileSystemSynchronizedRootGroup','path = FormaLiveActivity; sourceTree = "<group>";')
add(widget_product,'PBXFileReference','explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = FormaLiveActivity.appex; sourceTree = BUILT_PRODUCTS_DIR;')
add(widget_sources,'PBXSourcesBuildPhase',f'buildActionMask = 2147483647; files = ({activity_widget_build}); runOnlyForDeploymentPostprocessing = 0;')
for phase,typ in [(widget_resources,'PBXResourcesBuildPhase'),(widget_frameworks,'PBXFrameworksBuildPhase')]:
    add(phase,typ,'buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add(widget_target,'PBXNativeTarget',f'buildConfigurationList = {widget_configs}; buildPhases = ({widget_sources}, {widget_frameworks}, {widget_resources}); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = ({widget_group}); name = FormaLiveActivity; productName = FormaLiveActivity; productReference = {widget_product}; productType = "com.apple.product-type.app-extension";')
widget_config_ids=[]
for index,conf in enumerate(['Debug','Release']):
    ck=f'E2{index:022d}';widget_config_ids.append(ck)
    settings={'PRODUCT_BUNDLE_IDENTIFIER':'com.robii.forma.LiveActivity','PRODUCT_NAME':'FormaLiveActivity',
              'GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_FILE':'Config/FormaLiveActivity-Info.plist',
              'SWIFT_VERSION':'5.0','IPHONEOS_DEPLOYMENT_TARGET':'18.0','TARGETED_DEVICE_FAMILY':'"1,2"',
              'CODE_SIGN_STYLE':'Automatic','CURRENT_PROJECT_VERSION':'22','MARKETING_VERSION':'0.9.5',
              'ARCHS':'arm64','SUPPORTED_PLATFORMS':'"iphoneos iphonesimulator"',
              'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES',
              'DEVELOPMENT_TEAM':'"'+os.environ.get('FORMA_DEVELOPMENT_TEAM','')+'"',
              'LD_RUNPATH_SEARCH_PATHS':'"$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"'}
    add(ck,'XCBuildConfiguration',f'buildSettings = {{ {" ".join(f"{k} = {v};" for k,v in settings.items())} }}; name = {conf};')
add(widget_configs,'XCConfigurationList',f'buildConfigurations = ({", ".join(widget_config_ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

mac_target='D10000000000000000000001'
mac_group='D10000000000000000000002'
mac_product='D10000000000000000000003'
mac_sources='D10000000000000000000004'
mac_resources='D10000000000000000000005'
mac_frameworks='D10000000000000000000006'
mac_configs='D10000000000000000000007'
shared_group='D10000000000000000000008'
shared_names=['ScanModels','LiDARQualitySettings','LiDARQualityControls','MeshPlanarDenoiser','SavedScanRefinement','PhotogrammetryQualityOptions','GaussianTrainingPreset','RGBDDataset','COLMAPDatasetExporter','MeshExporter','ScanStore','MeshContinuity',
              'PhotometricHarmonizer','LiDARTextureBaker','TextureAtlasBuilder','TextureChartBuilder','LiDARProcessingPipeline',
              'ProcessingControl','CooperativeFileIO','PendingScanRecovery','HybridTransfer','ImportedMeshBatching','LocalAITextureEnhancer','TextureAssetInventory',
              'LocalAIModelRestoration','USDZTextureRestorationAdapter','StoredUSDZArchive',
              'GaussianMetalRenderer','GaussianAsset','GaussianDepthOrder','ViewerPerformance','GaussianViewpoint']
shared_refs=[]
shared_builds=[]
for index,name in enumerate(shared_names):
    ref=f'D2{index:022d}'
    build=f'D3{index:022d}'
    shared_refs.append(ref);shared_builds.append(build)
    source_path = f'Forma/Presentation/Components/{name}.swift' if name == 'LiDARQualityControls' else f'Forma/Core/{name}.swift'
    add(ref,'PBXFileReference',f'lastKnownFileType = sourcecode.swift; path = {source_path}; sourceTree = SOURCE_ROOT;')
    add(build,'PBXBuildFile',f'fileRef = {ref};')
add(shared_group,'PBXGroup',f'children = ({", ".join(shared_refs)}); name = "Módulos compartidos"; sourceTree = "<group>";')
add(mac_group,'PBXFileSystemSynchronizedRootGroup','path = Mac; sourceTree = "<group>";')
add(mac_product,'PBXFileReference','explicitFileType = wrapper.application; includeInIndex = 0; path = FormaDesktop.app; sourceTree = BUILT_PRODUCTS_DIR;')
mac_render_ref='D60000000000000000000001'
mac_render_build='D60000000000000000000002'
mac_worker_ref='D60000000000000000000003'
mac_worker_build='D60000000000000000000004'
mac_worker_embed='D60000000000000000000005'
mac_worker_shader='D60000000000000000000006'
mac_worker_shader_build='D60000000000000000000007'
mac_worker_licenses='D60000000000000000000008'
mac_worker_licenses_build='D60000000000000000000009'
mac_worker_verify='D60000000000000000000010'
mac_worker_manifest='D60000000000000000000011'
mac_worker_manifest_build='D60000000000000000000012'
add(mac_render_ref,'PBXFileReference','lastKnownFileType = sourcecode.metal; path = Forma/Resources/GaussianSplatShaders.metal; sourceTree = SOURCE_ROOT;')
add(mac_render_build,'PBXBuildFile',f'fileRef = {mac_render_ref};')
add(mac_worker_ref,'PBXFileReference','explicitFileType = "compiled.mach-o.executable"; path = build/GaussianDesktopWorker/FormaGaussianWorker; sourceTree = SOURCE_ROOT;')
add(mac_worker_build,'PBXBuildFile',f'fileRef = {mac_worker_ref}; settings = {{ ATTRIBUTES = (CodeSignOnCopy); }};')
add(mac_worker_embed,'PBXCopyFilesBuildPhase',f'buildActionMask = 2147483647; dstPath = Contents/Helpers; dstSubfolderSpec = 1; files = ({mac_worker_build}); name = "Embed Gaussian worker"; runOnlyForDeploymentPostprocessing = 0;')
add(mac_worker_shader,'PBXFileReference','lastKnownFileType = "archive.metal-library"; path = build/GaussianDesktopWorker/msplat-macos.metallib; sourceTree = SOURCE_ROOT;')
add(mac_worker_shader_build,'PBXBuildFile',f'fileRef = {mac_worker_shader};')
add(mac_worker_licenses,'PBXFileReference','lastKnownFileType = folder; path = build/GaussianDesktopWorker/Licenses; sourceTree = SOURCE_ROOT;')
add(mac_worker_licenses_build,'PBXBuildFile',f'fileRef = {mac_worker_licenses};')
add(mac_worker_manifest,'PBXFileReference','lastKnownFileType = text.json; path = build/GaussianDesktopWorker/worker-artifacts.json; sourceTree = SOURCE_ROOT;')
add(mac_worker_manifest_build,'PBXBuildFile',f'fileRef = {mac_worker_manifest};')
add(mac_worker_verify,'PBXShellScriptBuildPhase','buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); alwaysOutOfDate = 1; name = "Verify Gaussian worker"; shellPath = /bin/sh; shellScript = "python3 \\"$SRCROOT/Tools/verify_gaussian_worker.py\\" --output \\"$SRCROOT/build/GaussianDesktopWorker\\""; runOnlyForDeploymentPostprocessing = 0;')
add(mac_sources,'PBXSourcesBuildPhase',f'buildActionMask = 2147483647; files = ({", ".join(shared_builds)}, {mac_render_build}); runOnlyForDeploymentPostprocessing = 0;')
add(mac_resources,'PBXResourcesBuildPhase',f'buildActionMask = 2147483647; files = ({mac_worker_shader_build}, {mac_worker_licenses_build}, {mac_worker_manifest_build}); runOnlyForDeploymentPostprocessing = 0;')
add(mac_frameworks,'PBXFrameworksBuildPhase','buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add(mac_target,'PBXNativeTarget',f'buildConfigurationList = {mac_configs}; buildPhases = ({mac_worker_verify}, {mac_sources}, {mac_frameworks}, {mac_resources}, {mac_worker_embed}); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = ({mac_group}); name = FormaDesktop; productName = FormaDesktop; productReference = {mac_product}; productType = "com.apple.product-type.application";')
mac_config_ids=[]
for index,conf in enumerate(['Debug','Release']):
    key=f'D4{index:022d}';mac_config_ids.append(key)
    settings={'PRODUCT_BUNDLE_IDENTIFIER':'com.robii.forma.desktop','PRODUCT_NAME':'FormaDesktop',
              'SDKROOT':'macosx','SUPPORTED_PLATFORMS':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0',
              'ARCHS':'"$(ARCHS_STANDARD)"','SWIFT_VERSION':'5.0','GENERATE_INFOPLIST_FILE':'YES',
              'INFOPLIST_FILE':'Config/FormaDesktop-Info.plist','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':'"-"',
              'ENABLE_APP_SANDBOX':'NO','CURRENT_PROJECT_VERSION':'22','MARKETING_VERSION':'0.9.5',
              'INFOPLIST_KEY_CFBundleDisplayName':'"Forma Desktop"','INFOPLIST_KEY_LSApplicationCategoryType':'"public.app-category.graphics-design"',
              'LD_RUNPATH_SEARCH_PATHS':'"$(inherited) @executable_path/../Frameworks"'}
    add(key,'XCBuildConfiguration',f'buildSettings = {{ {" ".join(f"{k} = {v};" for k,v in settings.items())} }}; name = {conf};')
add(mac_configs,'XCConfigurationList',f'buildConfigurations = ({", ".join(mac_config_ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
targets.append(mac_target)
targets.append(widget_target)
add(main,'PBXGroup',f'children = (B10000000000000000000002, B20000000000000000000002, B30000000000000000000002, {mac_group}, {shared_group}, {widget_group}, {activity_group}, {native_group}, {products}); sourceTree = "<group>";')
add(products,'PBXGroup',f'children = (B10000000000000000000003, B20000000000000000000003, B30000000000000000000003, {mac_product}, {widget_product}); name = Products; sourceTree = "<group>";')
add(project,'PBXProject',f'attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 16.0"; developmentRegion = es; hasScannedForEncodings = 0; knownRegions = (es, en, Base); mainGroup = {main}; preferredProjectObjectVersion = 77; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({", ".join(targets)});')
for i, conf in enumerate(['Debug','Release']):
    ck=f'C{i+1:023d}'
    testability = 'YES' if i == 0 else 'NO'
    debug_format = 'dwarf' if i == 0 else '"dwarf-with-dsym"'
    optimization = '"-Onone"' if i == 0 else '"-O"'
    conditions = 'DEBUG' if i == 0 else '""'
    add(ck,'XCBuildConfiguration',f'buildSettings = {{ CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; ENABLE_TESTABILITY = {testability}; DEBUG_INFORMATION_FORMAT = {debug_format}; SWIFT_OPTIMIZATION_LEVEL = {optimization}; SWIFT_ACTIVE_COMPILATION_CONDITIONS = {conditions}; }}; name = {conf};')
add(project_configs,'XCConfigurationList','buildConfigurations = (C00000000000000000000001, C00000000000000000000002); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
(root/'Forma.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; objects = {\n'+ '\n'.join(objects) +f'\n}}; rootObject = {project}; }}\n')

def reference(name, ident):
    ext='xctest' if name.endswith('Tests') else 'app'
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Forma.xcodeproj"/>'

scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference('Forma',targets[0])}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference('FormaTests',targets[1])}</TestableReference><TestableReference skipped="NO">{reference('FormaUITests',targets[2])}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('Forma',targets[0])}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('Forma',targets[0])}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(root/'Forma.xcodeproj/xcshareddata/xcschemes/Forma.xcscheme').write_text(scheme)
mac_scheme=scheme.replace(reference('Forma',targets[0]),reference('FormaDesktop',mac_target))
mac_scheme=mac_scheme.replace(f'<Testables><TestableReference skipped="NO">{reference("FormaTests",targets[1])}</TestableReference><TestableReference skipped="NO">{reference("FormaUITests",targets[2])}</TestableReference></Testables>','<Testables/>')
(root/'Forma.xcodeproj/xcshareddata/xcschemes/FormaDesktop.xcscheme').write_text(mac_scheme)
print('Forma.xcodeproj generated')
