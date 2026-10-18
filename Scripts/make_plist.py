import plistlib,sys
path,version,build=sys.argv[1:]
p={
 'CFBundleName':'搞整理','CFBundleDisplayName':'搞整理','CFBundleIdentifier':'com.gaoseries.GaoZhengLi',
 'CFBundleExecutable':'GaoZhengLi','CFBundlePackageType':'APPL','CFBundleShortVersionString':version,
 'CFBundleVersion':build,'CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':'14.0',
 'CFBundleDevelopmentRegion':'zh_CN','CFBundleLocalizations':['zh-Hans'],'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','LSApplicationCategoryType':'public.app-category.productivity',
 'CFBundleDocumentTypes':[{'CFBundleTypeName':'GaoAction V1','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['com.gaoseries.action-package']}],
 'UTImportedTypeDeclarations':[{'UTTypeIdentifier':'com.gaoseries.action-package','UTTypeConformsTo':['com.apple.package'],'UTTypeDescription':'GaoAction V1','UTTypeTagSpecification':{'public.filename-extension':['gaoaction']}}],
 'NSHumanReadableCopyright':'Copyright © 2026 GaoSeries. MIT License.'
}
with open(path,'wb') as f: plistlib.dump(p,f)
