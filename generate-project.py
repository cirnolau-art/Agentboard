#!/usr/bin/env python3
"""Generate a dependency-free Xcode project. No package manager is required."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent
VERSION = json.loads((ROOT/'Config/Version.json').read_text())
objects = {}
def ident(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def obj(key, value):
    result = ident(key); objects[result] = value; return result
def quote(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
def arr(values): return '(' + ', '.join(values) + ')'
def fields(**kwargs): return '{ ' + ' '.join(f'{key} = {value};' for key, value in kwargs.items()) + ' }'

files = sorted(str(p.relative_to(ROOT)) for folder in ['Shared', 'App', 'Widget'] for p in (ROOT/folder).glob('*.swift'))
refs = {p: obj('ref:'+p, fields(isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path=quote(p),sourceTree=quote('<group>'))) for p in files}
app_product = obj('app-product', fields(isa='PBXFileReference',explicitFileType='wrapper.application',path='AgentBoard.app',sourceTree='BUILT_PRODUCTS_DIR'))
widget_product = obj('widget-product', fields(isa='PBXFileReference',explicitFileType=quote('wrapper.app-extension'),path='AgentBoardWidget.appex',sourceTree='BUILT_PRODUCTS_DIR'))
products = obj('products', fields(isa='PBXGroup',children=arr([app_product,widget_product]),name='Products',sourceTree=quote('<group>')))
main_group = obj('main-group', fields(isa='PBXGroup',children=arr(list(refs.values())+[products]),sourceTree=quote('<group>')))

def configurations(name, extra):
    ids = []
    for mode in ['Debug','Release']:
        values = dict(MACOSX_DEPLOYMENT_TARGET=quote('14.0'),SDKROOT='macosx',SWIFT_VERSION=quote('5.0'),CLANG_ENABLE_MODULES='YES',SWIFT_OPTIMIZATION_LEVEL=quote('-Onone' if mode=='Debug' else '-O'),DEBUG_INFORMATION_FORMAT=quote('dwarf'),CODE_SIGN_IDENTITY=quote('-'),CODE_SIGN_STYLE='Manual',CODE_SIGNING_ALLOWED='YES',ENABLE_HARDENED_RUNTIME='NO',ARCHS=quote('arm64'),ONLY_ACTIVE_ARCH='YES',GENERATE_INFOPLIST_FILE='NO')
        values.update(extra)
        values.update(MARKETING_VERSION=quote(VERSION['version']), CURRENT_PROJECT_VERSION=quote(VERSION['build']), AGENTBOARD_AUTHOR=quote(VERSION['author']), AGENTBOARD_COPYRIGHT=quote(VERSION['copyright']))
        ids.append(obj(name+mode,fields(isa='XCBuildConfiguration',buildSettings=fields(**values),name=mode)))
    return obj(name+'configs', fields(isa='XCConfigurationList',buildConfigurations=arr(ids),defaultConfigurationIsVisible='0',defaultConfigurationName='Release'))

widget_id=ident('widget-target'); app_id=ident('app-target')
proxy=obj('widget-proxy',fields(isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType='1',remoteGlobalIDString=widget_id,remoteInfo='AgentBoardWidget'))
dependency=obj('widget-dependency',fields(isa='PBXTargetDependency',target=widget_id,targetProxy=proxy))
embedfile=obj('widget-embed-file',fields(isa='PBXBuildFile',fileRef=widget_product,settings=fields(ATTRIBUTES=arr(['RemoveHeadersOnCopy']))))
embed=obj('embed-phase',fields(isa='PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath=quote(''),dstSubfolderSpec='13',files=arr([embedfile]),name=quote('Embed App Extensions'),runOnlyForDeploymentPostprocessing='0'))

for name,product,tid,extension in [('AgentBoard',app_product,app_id,False),('AgentBoardWidget',widget_product,widget_id,True)]:
    targetfiles=[p for p in files if not extension or not p.startswith('App/')]
    builds=[obj(name+':'+p,fields(isa='PBXBuildFile',fileRef=refs[p])) for p in targetfiles]
    sources=obj(name+'sources',fields(isa='PBXSourcesBuildPhase',buildActionMask='2147483647',files=arr(builds),runOnlyForDeploymentPostprocessing='0'))
    frameworks=obj(name+'frameworks',fields(isa='PBXFrameworksBuildPhase',buildActionMask='2147483647',files='()',runOnlyForDeploymentPostprocessing='0'))
    extras=dict(PRODUCT_NAME=name,PRODUCT_BUNDLE_IDENTIFIER=quote('local.agentboard.widget' if extension else 'local.agentboard'),INFOPLIST_FILE=quote('Config/Widget-Info.plist' if extension else 'Config/App-Info.plist'),CODE_SIGN_ENTITLEMENTS=quote('Config/Widget.entitlements' if extension else 'Config/App.entitlements'),LD_RUNPATH_SEARCH_PATHS=quote('$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks'),SKIP_INSTALL='YES' if extension else 'NO')
    if extension: extras.update(APPLICATION_EXTENSION_API_ONLY='YES',SWIFT_ACTIVE_COMPILATION_CONDITIONS=quote('WIDGET_EXTENSION'))
    else: extras.update(OTHER_LDFLAGS=quote('$(inherited) -lsqlite3'))
    config=configurations(name,extras)
    obj('widget-target' if extension else 'app-target',fields(isa='PBXNativeTarget',buildConfigurationList=config,buildPhases=arr([sources,frameworks]+([] if extension else [embed])),buildRules='()',dependencies=arr([] if extension else [dependency]),name=name,productName=name,productReference=product,productType=quote('com.apple.product-type.app-extension' if extension else 'com.apple.product-type.application')))

config=configurations('project',{})
project=obj('project',fields(isa='PBXProject',attributes=fields(BuildIndependentTargetsInParallel='YES',LastUpgradeCheck='2720'),buildConfigurationList=config,compatibilityVersion=quote('Xcode 14.0'),developmentRegion='zh_CN',hasScannedForEncodings='0',knownRegions=arr(['en','zh_CN','Base']),mainGroup=main_group,productRefGroup=products,projectDirPath=quote(''),projectRoot=quote(''),targets=arr([app_id,widget_id])))
folder=ROOT/'AgentBoard.xcodeproj';folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{key} = {value};' for key,value in objects.items())+'\n}; rootObject = '+project+'; }\n')
scheme_dir=folder/'xcshareddata/xcschemes';scheme_dir.mkdir(parents=True,exist_ok=True)
(scheme_dir/'AgentBoard.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="AgentBoard.app" BlueprintName="AgentBoard" ReferencedContainer="container:AgentBoard.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="AgentBoard.app" BlueprintName="AgentBoard" ReferencedContainer="container:AgentBoard.xcodeproj"/></BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(folder)
