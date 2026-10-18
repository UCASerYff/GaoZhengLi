#!/usr/bin/env python3
"""Install only this bundle; never launches it. Existing state is backed up and hash-verified."""
import datetime, hashlib, json, os, pathlib, plistlib, shutil, subprocess, sys, uuid
P = pathlib.Path
BUNDLE = 'com.gaoseries.GaoZhengLi'
TARGET = P('/Applications/搞整理.app')
DATA = P.home()/'Library/Application Support/GaoSeries/GaoZhengLi'
BACKUPS = DATA.parent/'GaoZhengLi-Backups'
PREFS = P.home()/'Library/Preferences'/f'{BUNDLE}.plist'

def run(*args): subprocess.run(args, check=True)
def inventory(root):
    result = {}
    for folder, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            p = P(folder)/name
            if p.is_symlink():
                result[str(p.relative_to(root))] = {'link': os.readlink(p)}
            elif p.is_file():
                h = hashlib.sha256()
                with p.open('rb') as f:
                    for block in iter(lambda: f.read(1024*1024), b''): h.update(block)
                result[str(p.relative_to(root))] = {'size':p.stat().st_size, 'sha256':h.hexdigest()}
            elif not p.is_dir(): raise RuntimeError('Unsupported object: '+str(p))
    return result

def plist(app):
    with (app/'Contents/Info.plist').open('rb') as f: return plistlib.load(f)

def verified_copy(source, target):
    before = inventory(source)
    run('/usr/bin/ditto','--rsrc','--extattr',str(source),str(target))
    if inventory(source) != before or inventory(target) != before: raise RuntimeError('Copy/source changed or incomplete')
    return before

source = P(sys.argv[1]).absolute()
if source.is_symlink() or not source.is_dir(): raise RuntimeError('Candidate app missing/linked')
p = plist(source)
if p.get('CFBundleIdentifier') != BUNDLE: raise RuntimeError('Wrong bundle')
run('/usr/bin/codesign','--verify','--deep','--strict',str(source))
if subprocess.run(['/usr/bin/pgrep','-x','GaoZhengLi'],stdout=subprocess.DEVNULL).returncode == 0: raise RuntimeError('Quit GaoZhengLi before installing')
if TARGET.exists() and (TARGET.is_symlink() or plist(TARGET).get('CFBundleIdentifier') != BUNDLE): raise RuntimeError('Existing target identity is not this application')
# The persistent defaults marker is checked independently from app data.
initialized = subprocess.run(['/usr/bin/defaults','read',BUNDLE,'GaoZhengLi.initialized.v1'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True).stdout.strip() == '1'
if initialized and not DATA.is_dir(): raise RuntimeError('Initialized data missing; restore it before installing')
if DATA.is_symlink(): raise RuntimeError("Data directory is a symbolic link")
if DATA.exists() and not DATA.is_dir(): raise RuntimeError('Data directory is not readable directory')
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+str(uuid.uuid4())
backup = BACKUPS/('Install-'+stamp)
backup.mkdir(parents=True,mode=0o700)
os.chmod(BACKUPS,0o700)
record = {'schemaVersion':1,'version':p['CFBundleShortVersionString'],'build':p['CFBundleVersion'],'firstInstall':not TARGET.exists() and not DATA.exists() and not PREFS.exists() and not initialized,'gui_verified':False,'verification_scope':'static-and-targeted','backups':{}}
if TARGET.exists(): record['backups']['app'] = verified_copy(TARGET,backup/'Previous.app')
if DATA.exists(): record['backups']['data'] = verified_copy(DATA,backup/'Data')
if PREFS.exists():
    shutil.copy2(PREFS,backup/'Preferences.plist')
    if PREFS.read_bytes() != (backup/'Preferences.plist').read_bytes(): raise RuntimeError('Preferences backup mismatch')
    record['backups']['preferences'] = hashlib.sha256(PREFS.read_bytes()).hexdigest()
(backup/'install-record.json').write_text(json.dumps(record,ensure_ascii=False,indent=2))
stage = TARGET.parent/('.GaoZhengLi-install-'+str(uuid.uuid4())+'.app')
old = TARGET.parent/('.GaoZhengLi-previous-'+str(uuid.uuid4())+'.app')
installed_candidate = False
try:
    candidate_inventory = verified_copy(source,stage)
    run('/usr/bin/codesign','--verify','--deep','--strict',str(stage))
    if TARGET.exists(): TARGET.rename(old)
    stage.rename(TARGET)
    installed_candidate = True
    run('/usr/bin/codesign','--verify','--deep','--strict',str(TARGET))
    if plist(TARGET) != p or inventory(TARGET) != candidate_inventory: raise RuntimeError('Installed candidate mismatch')
    if DATA.exists() and inventory(DATA) != record['backups'].get('data'): raise RuntimeError('User data changed during install')
    if PREFS.exists() and hashlib.sha256(PREFS.read_bytes()).hexdigest() != record['backups'].get('preferences'): raise RuntimeError('Preferences changed during install')
    record['installedVerified'] = True
    (backup/'install-record.json').write_text(json.dumps(record,ensure_ascii=False,indent=2))
    if old.exists(): shutil.rmtree(old)  # verified backup of old bundle is retained above
except BaseException:
    if old.exists():
        if TARGET.exists(): shutil.rmtree(TARGET)
        old.rename(TARGET)
    elif installed_candidate and TARGET.exists():
        shutil.rmtree(TARGET)
    raise
finally:
    if stage.exists(): shutil.rmtree(stage)
ls = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
# Only this exact source/installed bundle; no database reset or unrelated unregister.
registration = subprocess.run([ls,'-u',str(source)],capture_output=True,text=True)
if registration.returncode != 0 and '-10814' not in registration.stdout + registration.stderr:
    raise RuntimeError('Source registration could not be inspected: '+registration.stderr)
run(ls,'-f',str(TARGET))
record['registration'] = {'installedRegistered': True, 'source': 'unregistered' if registration.returncode == 0 else 'notRegistered'}
(backup/'install-record.json').write_text(json.dumps(record,ensure_ascii=False,indent=2))
print(json.dumps({'installed':str(TARGET),'version':p['CFBundleShortVersionString'],'build':p['CFBundleVersion'],'backupRecord':str(backup/'install-record.json'),'gui_verified':False,'firstInstall':record['firstInstall']},ensure_ascii=False))
