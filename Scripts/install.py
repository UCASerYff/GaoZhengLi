#!/usr/bin/env python3
"""Install this bundle without launching it; retain a verified, compressed rollback app."""
import contextlib
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
import zipfile

P = pathlib.Path
BUNDLE = 'com.gaoseries.GaoZhengLi'
TARGET = P('/Applications/搞整理.app')
DATA = P.home() / 'Library/Application Support/GaoSeries/GaoZhengLi'
BACKUPS = DATA.parent / 'GaoZhengLi-Backups'
PREFS = P.home() / 'Library/Preferences' / f'{BUNDLE}.plist'
LS = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
EXPECTED = ('configuration.json', 'configuration.initialized', 'metadata.sqlite', 'index-initialized.json',
            'associations_history.json', 'associations_history.initialized', 'exchange-initialized.json',
            'Exchange/Journal/ledger.json', 'MovePlans/initialized.json', 'MovePlans/ledger.json', 'MovePlans.initialized')


def run(*args):
    return subprocess.run(args, check=True)


def present(path):
    return os.path.lexists(path)


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def xattrs(path):
    if hasattr(os, 'listxattr'):
        return {name: hashlib.sha256(os.getxattr(path, name, follow_symlinks=False)).hexdigest()
                for name in sorted(os.listxattr(path, follow_symlinks=False))}
    # macOS Python does not expose os.listxattr/getxattr. Read Darwin's native API,
    # retaining no-follow semantics and treating any unreadable attribute as fatal.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    def read(function, prefix):
        size = function(*prefix, None, 0, *([0, 1] if function is libc.getxattr else [1]))
        if size < 0:
            raise OSError(ctypes.get_errno(), 'Cannot read extended attributes', str(path))
        buffer = ctypes.create_string_buffer(size)
        actual = function(*prefix, buffer, size, *([0, 1] if function is libc.getxattr else [1]))
        if actual < 0 or actual != size:
            raise OSError(ctypes.get_errno(), 'Extended attributes changed or are unreadable', str(path))
        return buffer.raw[:actual]
    encoded = os.fsencode(path)
    names = read(libc.listxattr, [encoded]).split(b'\0')
    return {os.fsdecode(name): hashlib.sha256(read(libc.getxattr, [encoded, name])).hexdigest()
            for name in sorted(names) if name}


def entry(path):
    info = path.lstat()
    result = {'mode': stat.S_IMODE(info.st_mode)}
    if stat.S_ISLNK(info.st_mode):
        result['link'] = os.readlink(path)
    elif stat.S_ISREG(info.st_mode):
        result.update(size=info.st_size, sha256=sha256(path))
    elif stat.S_ISDIR(info.st_mode):
        result['directory'] = True
    else:
        raise RuntimeError('Unsupported object: ' + str(path))
    result['xattrs'] = xattrs(path)
    return result


def inventory(root):
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError('Inventory root is missing, linked or not a directory: ' + str(root))
    result = {'.': entry(root)}
    def inaccessible(error):
        raise error
    for folder, directories, files in os.walk(root, followlinks=False, onerror=inaccessible):
        for name in sorted(directories + files):
            path = P(folder) / name
            result[str(path.relative_to(root))] = entry(path)
    return result


def plist(app):
    with (app / 'Contents/Info.plist').open('rb') as f:
        return plistlib.load(f)


def verify_app(app):
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError('App is missing or linked: ' + str(app))
    info = plist(app)
    if info.get('CFBundleIdentifier') != BUNDLE or info.get('CFBundleExecutable') != 'GaoZhengLi':
        raise RuntimeError('Wrong application identity: ' + str(app))
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        if not isinstance(info.get(key), str) or not info[key]:
            raise RuntimeError('App version is missing')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    return info


def verified_copy(source, target):
    before = inventory(source)
    run('/usr/bin/ditto', '--rsrc', '--extattr', str(source), str(target))
    if inventory(source) != before or inventory(target) != before:
        raise RuntimeError('Copy/source changed or incomplete')
    return before


def safe_zip(archive, root_name):
    """Reject paths or links which could escape the private extraction directory."""
    with zipfile.ZipFile(archive) as zipped:
        found = False
        for item in zipped.infolist():
            # ditto writes UTF-8 names without setting ZIP's UTF-8 flag.
            name = item.filename if item.flag_bits & 0x800 else item.filename.encode('cp437').decode('utf-8')
            path = pathlib.PurePosixPath(name)
            if not path.parts or path.is_absolute() or '..' in path.parts or '\\' in name:
                raise RuntimeError('Unsafe archive path')
            if path.parts[0] not in (root_name, '__MACOSX'):
                raise RuntimeError('Unexpected archive root')
            if stat.S_ISLNK(item.external_attr >> 16):
                raise RuntimeError('Archive symlinks are not supported')
            found |= path.parts[0] == root_name
        if not found or zipped.testzip() is not None:
            raise RuntimeError('Archive is incomplete or damaged')


class ArchiveRootMaclMismatch(RuntimeError):
    """A ZIP restored everything except the original root's system-managed macl."""
    def __init__(self, proof):
        super().__init__('Archive cannot preserve the original app root com.apple.macl')
        self.proof = proof


def root_macl_missing_only(expected, restored):
    if expected.keys() != restored.keys() or expected.get('.') is None:
        return False
    expected_root, restored_root = expected['.'], restored['.']
    if expected_root.keys() != restored_root.keys():
        return False
    source_attrs, restored_attrs = expected_root['xattrs'], restored_root['xattrs']
    if source_attrs.keys() - restored_attrs.keys() != {'com.apple.macl'} or restored_attrs.keys() - source_attrs.keys():
        return False
    return (all(expected[name] == restored[name] for name in expected if name != '.')
            and all(expected_root[name] == restored_root[name] for name in expected_root if name != 'xattrs')
            and all(source_attrs[name] == value for name, value in restored_attrs.items()))


def verify_archive(archive, root_name, expected, expected_info):
    safe_zip(archive, root_name)
    proof = {'path': str(archive), 'size': archive.stat().st_size, 'sha256': sha256(archive),
             'root': root_name, 'inventoryVerified': True, 'signatureVerified': True,
             'infoPlistVerified': True, 'verificationScope': 'all-files-directories-modes-xattrs-and-links'}
    with tempfile.TemporaryDirectory(prefix='gaozhengli-restore-', suffix='.noindex', dir='/private/tmp') as folder:
        run('/usr/bin/ditto', '-x', '-k', str(archive), folder)
        restored = P(folder) / root_name
        restored_inventory = inventory(restored)
        if verify_app(restored) != expected_info:
            raise RuntimeError('Archive restore verification failed')
        if restored_inventory != expected:
            if root_macl_missing_only(expected, restored_inventory):
                proof.update(inventoryVerified=False, supplementalOnly=True,
                             verificationScope='all-inventory-entries-except-missing-root-com.apple.macl',
                             missingMetadata={'.': {'com.apple.macl': expected['.']['xattrs']['com.apple.macl']}})
                raise ArchiveRootMaclMismatch(proof)
            raise RuntimeError('Archive restore verification failed')
    return proof


def private_staging_source(source):
    if not source.is_absolute() or source.suffix != '.app' or source.resolve() != source:
        raise RuntimeError('Candidate requires an absolute, non-linked .app path')
    containers = [p for p in source.parents if p.name.endswith('.noindex')]
    if not containers:
        raise RuntimeError('Candidate .app must be inside a private .noindex container; alternatively pass the release ZIP')
    owner = containers[0].stat()
    if not containers[0].is_dir() or owner.st_uid != os.getuid() or stat.S_IMODE(owner.st_mode) & 0o077:
        raise RuntimeError('Candidate .noindex container must be owned by this user and private (0700)')


@contextlib.contextmanager
def candidate(path):
    source = P(path)
    if not source.is_absolute() or source.is_symlink():
        raise RuntimeError('Candidate path must be absolute and not linked')
    if source.suffix.lower() == '.zip':
        safe_zip(source, TARGET.name)
        with tempfile.TemporaryDirectory(prefix='gaozhengli-release-', suffix='.noindex', dir='/private/tmp') as folder:
            run('/usr/bin/ditto', '-x', '-k', str(source), folder)
            yield P(folder) / TARGET.name
    else:
        private_staging_source(source)
        yield source


def ensure_stopped():
    status = subprocess.run(['/usr/bin/pgrep', '-x', 'GaoZhengLi'], stdout=subprocess.DEVNULL).returncode
    if status == 0:
        raise RuntimeError('Quit GaoZhengLi before installing')
    if status != 1:
        raise RuntimeError('Could not verify that GaoZhengLi is stopped')


@contextlib.contextmanager
def data_lease():
    ensure_stopped()
    fd = None
    try:
        if present(DATA):
            info = DATA.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                raise RuntimeError('Data directory identity or type is invalid')
            # Never create or repair user files during an installation.
            fd = os.open(DATA / '.app.lock', os.O_RDWR | os.O_NOFOLLOW)
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise RuntimeError('Data lock is not a regular file')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        ensure_stopped()
        yield
    finally:
        if fd is not None:
            os.close(fd)


def initialized_state():
    marker = False
    if present(PREFS):
        if PREFS.is_symlink() or not PREFS.is_file():
            raise RuntimeError('Preferences are linked or unreadable')
        with PREFS.open('rb') as f:
            values = plistlib.load(f)
        marker = bool(values.get('GaoZhengLi.initialized.v1', False))
    response = subprocess.run(['/usr/bin/defaults', 'read', BUNDLE, 'GaoZhengLi.initialized.v1'],
                              capture_output=True, text=True)
    if response.returncode == 0:
        value = response.stdout.strip().lower()
        if value not in ('0', '1', 'true', 'false'):
            raise RuntimeError('Unknown persistent initialization marker')
        marker |= value in ('1', 'true')
    elif response.returncode != 1 or 'does not exist' not in response.stderr.lower():
        raise RuntimeError('Could not read persistent initialization marker')
    # Any durable initialization file also rules out treating a partial store as empty.
    initialized = marker or any(present(DATA / name) for name in EXPECTED)
    if initialized:
        missing = [name for name in EXPECTED if not (DATA / name).is_file() or (DATA / name).is_symlink()]
        if missing:
            raise RuntimeError('Initialized data is incomplete: ' + ', '.join(missing))
    return initialized


def state_snapshot():
    return {'data': inventory(DATA) if present(DATA) else None,
            'preferences': entry(PREFS) if present(PREFS) else None}


def verify_state(before):
    if state_snapshot() != before:
        raise RuntimeError('User data or preferences changed during installation; verified backup retained')


def write_record(path, record):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w', encoding='utf-8') as f:
        json.dump(record, f, ensure_ascii=False, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def unregister(path):
    if present(path) and plist(path).get('CFBundleIdentifier') != BUNDLE:
        raise RuntimeError('Refusing to unregister an unrelated application')
    result = subprocess.run([LS, '-u', str(path)], capture_output=True, text=True)
    if result.returncode != 0 and '-10814' not in result.stdout + result.stderr:
        raise RuntimeError('Exact application unregister failed: ' + str(path))
    return 'unregistered' if result.returncode == 0 else 'notRegistered'


def preferences_entry(path):
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError('Preferences must be a regular, non-linked file')
    value = entry(path)
    after = path.lstat()
    if (before.st_dev, before.st_ino, before.st_uid, before.st_gid) != (after.st_dev, after.st_ino, after.st_uid, after.st_gid):
        raise RuntimeError('Preferences identity changed while reading')
    return dict(value, uid=after.st_uid, gid=after.st_gid)


def xattr_length(path, name):
    if hasattr(os, 'getxattr'):
        return len(os.getxattr(path, name, follow_symlinks=False))
    libc = ctypes.CDLL(None, use_errno=True)
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    size = libc.getxattr(os.fsencode(path), os.fsencode(name), None, 0, 0, 1)
    if size < 0:
        raise OSError(ctypes.get_errno(), 'Cannot read preferences attribute length', str(path))
    return size


def preferences_preservation(original, copied):
    """Preferences only: retain every original value; identify one added OS label."""
    if {k: v for k, v in original.items() if k != 'xattrs'} != {k: v for k, v in copied.items() if k != 'xattrs'}:
        raise RuntimeError('Preferences bytes, mode or owner backup mismatch')
    old_attrs, new_attrs = original['xattrs'], copied['xattrs']
    if any(name not in new_attrs or new_attrs[name] != value for name, value in old_attrs.items()):
        raise RuntimeError('Original preferences metadata changed or is missing from backup')
    added = new_attrs.keys() - old_attrs.keys()
    if added and added != {'com.apple.provenance'}:
        raise RuntimeError('Unexpected extra preferences backup metadata')
    return added


def backup_preferences(source, target, expected, identity):
    if present(target):
        raise RuntimeError('Preferences backup target already exists')
    def verify_source():
        if object_identity(source) != identity or preferences_entry(source) != expected or object_identity(source) != identity:
            raise RuntimeError('Original preferences identity or complete entry changed')
    verify_source()
    run('/usr/bin/ditto', '--rsrc', '--extattr', str(source), str(target))
    copied = preferences_entry(target)
    added = preferences_preservation(expected, copied)
    added_proof = {name: {'length': xattr_length(target, name), 'sha256': copied['xattrs'][name]}
                   for name in added}
    if preferences_entry(target) != copied:
        raise RuntimeError('Preferences backup changed while recording its metadata')
    verify_source()
    with tempfile.TemporaryDirectory(prefix='gaozhengli-preferences-restore-', suffix='.noindex', dir='/private/tmp') as folder:
        # Darwin copies inherit the destination directory's group. Adjust only this
        # newly created private rehearsal directory; never alter either preferences file.
        if P(folder).stat().st_gid != copied['gid']:
            os.chown(folder, -1, copied['gid'])
            if P(folder).stat().st_gid != copied['gid']:
                raise RuntimeError('Preferences restore directory group could not be preserved')
        restored = P(folder) / 'Preferences.plist'
        run('/usr/bin/ditto', '--rsrc', '--extattr', str(target), str(restored))
        restored_entry = preferences_entry(restored)
        if restored_entry != copied or preferences_entry(target) != copied:
            raise RuntimeError('Preferences restore rehearsal differs from the recorded backup entry')
        preferences_preservation(expected, restored_entry)
    verify_source()
    return {'schemaVersion': 1, 'type': 'preferences-added-provenance' if added else 'preferences-exact-copy',
            'originalEntry': expected, 'backupEntry': copied, 'sourceIdentity': identity,
            'sourceIdentityAndEntryUnchanged': True, 'inventoryEqual': expected == copied,
            'addedAttrProof': added_proof,
            'restoreRehearsal': {'backupEntryEqual': True, 'allOriginalAttributesPreserved': True,
                                 'originalInventoryEqual': expected == restored_entry, 'restoredEntry': restored_entry}}


def object_identity(path):
    value = path.lstat()
    return {'device': value.st_dev, 'inode': value.st_ino}


def verify_original(path, info, manifest, identity):
    if object_identity(path) != identity or verify_app(path) != info or inventory(path) != manifest:
        raise RuntimeError('Original program identity, signature or full metadata changed')


def write_receipts(backup, record, original_info, original_manifest):
    write_record(backup / 'install-record.json', record)
    if 'app' in record['backups'] or 'preferencesBackupVerification' in record:
        write_record(backup / 'restore-verification.json', {
            'schemaVersion': 2, 'originalApp': str(TARGET), 'originalInfoPlist': original_info,
            'archive': record['archivedBackups'].get('app'), 'inventory': original_manifest,
            'authoritativeOriginalProgram': record.get('retainedOriginalProgram'),
            'preferencesBackupVerification': record.get('preferencesBackupVerification'),
            'installationStatus': record['status']})


def install(source):
    info = verify_app(source)
    with data_lease():
        initialized = initialized_state()
        original_info = verify_app(TARGET) if present(TARGET) else None
        original_manifest = inventory(TARGET) if original_info else None
        original_identity = object_identity(TARGET) if original_info else None
        before = state_snapshot()
        prefs_identity = object_identity(PREFS) if before['preferences'] is not None else None
        prefs_before = preferences_entry(PREFS) if before['preferences'] is not None else None
        if prefs_before is not None and (object_identity(PREFS) != prefs_identity or {k: v for k, v in prefs_before.items() if k not in ('uid', 'gid')} != before['preferences']):
            raise RuntimeError('Original preferences changed before backup preparation')
        if present(BACKUPS) and (BACKUPS.is_symlink() or not BACKUPS.is_dir() or BACKUPS.stat().st_uid != os.getuid()):
            raise RuntimeError('Backup directory identity is invalid')
        BACKUPS.mkdir(parents=True, mode=0o700, exist_ok=True)
        os.chmod(BACKUPS, 0o700)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + str(uuid.uuid4())
        backup = BACKUPS / ('Install-' + stamp)
        backup.mkdir(mode=0o700)
        receipt = backup / 'install-record.json'
        record = {'schemaVersion': 2, 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                  'initialized': initialized, 'firstInstall': original_info is None and before['data'] is None and before['preferences'] is None and not initialized,
                  'gui_verified': False, 'verification_scope': 'static-and-targeted', 'status': 'backing-up',
                  'backups': {}, 'archivedBackups': {}}
        def persist():
            write_receipts(backup, record, original_info, original_manifest)
        persist()
        retained = None
        try:
            if original_info:
                archive_path = backup / 'Previous.app.zip'
                run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(TARGET), str(archive_path))
                try:
                    archive = verify_archive(archive_path, TARGET.name, original_manifest, original_info)
                except ArchiveRootMaclMismatch as mismatch:
                    # ZIP is supplementary only. Preserve the actual original object, including macl;
                    # never recreate, remove or write the system-managed attribute.
                    archive = mismatch.proof
                    program_container = backup / 'Program.noindex'
                    program_container.mkdir(mode=0o700)
                    if program_container.stat().st_dev != original_identity['device']:
                        raise RuntimeError('Original program retention requires the same filesystem')
                    retained = {'path': str(program_container / TARGET.name), 'authoritativePath': str(TARGET),
                                'originalSource': str(TARGET), 'identity': original_identity,
                                'reason': 'ZIP restore lacks original root com.apple.macl; original bundle is authoritative',
                                'fullInventoryVerified': False, 'sameObjectVerified': False, 'moves': []}
                    record['retainedOriginalProgram'] = retained
                verify_original(TARGET, original_info, original_manifest, original_identity)
                record['backups']['app'] = original_manifest
                record['archivedBackups']['app'] = archive
                persist()
            if before['data'] is not None:
                record['backups']['data'] = verified_copy(DATA, backup / 'Data')
                if record['backups']['data'] != before['data']:
                    raise RuntimeError('Data changed before backup finished')
            if before['preferences'] is not None:
                record['preferencesBackupVerification'] = backup_preferences(PREFS, backup / 'Preferences.plist', prefs_before, prefs_identity)
                record['backups']['preferences'] = before['preferences']
            verify_state(before)
            record['status'] = 'backup-verified-pending-original-retention' if retained else 'backup-verified'
            persist()
        except BaseException as error:
            unchanged = not present(TARGET) if original_info is None else False
            if original_info:
                try:
                    verify_original(TARGET, original_info, original_manifest, original_identity)
                    unchanged = True
                except BaseException:
                    pass
            record.update(status='failed-before-replacement', installedVerified=False,
                          error=str(error), oldProgramUnchanged=unchanged)
            persist()
            raise
        # Candidate staging is on the target filesystem. The original, when needed for macl,
        # moves atomically under its unchanged filename into the long-term private container.
        staging = P(tempfile.mkdtemp(prefix='.GaoZhengLi-install-', suffix='.noindex', dir=TARGET.parent))
        stage = staging / TARGET.name
        old = P(retained['path']) if retained else staging / 'Previous.app'
        swapped = False
        try:
            manifest = verified_copy(source, stage)
            if verify_app(stage) != info:
                raise RuntimeError('Staged app Info.plist mismatch')
            ensure_stopped()
            verify_state(before)
            if original_info:
                verify_original(TARGET, original_info, original_manifest, original_identity)
                if retained:
                    record['status'] = 'retaining-original-program'
                    retained['moves'].append({'from': str(TARGET), 'to': str(old), 'state': 'planned'})
                    persist()  # Durable recovery pointer before changing either program path.
                TARGET.rename(old)
                if retained:
                    verify_original(old, original_info, original_manifest, original_identity)
                    retained.update(authoritativePath=str(old), fullInventoryVerified=True, sameObjectVerified=True)
                    retained['moves'][-1]['state'] = 'verified'
                    record['status'] = 'backup-verified'
                    persist()
            stage.rename(TARGET)
            swapped = True
            if verify_app(TARGET) != info or inventory(TARGET) != manifest:
                raise RuntimeError('Installed candidate mismatch')
            verify_state(before)
            registration = {str(path): unregister(path) for path in (source, stage, old)}
            run(LS, '-f', str(TARGET))
            verify_state(before)
            if retained:
                verify_original(old, original_info, original_manifest, original_identity)
            record.update(status='installed-verified', installedVerified=True,
                          registration={'installedRegistered': True, 'exactPaths': registration})
            persist()
        except BaseException as error:
            rollback_errors = []
            program_restored = False
            def persist_rollback():
                try:
                    persist()
                except BaseException as receipt_error:
                    rollback_errors.append('Rollback receipt write failed: ' + str(receipt_error))
            # A registration failure must never prevent the filesystem rollback.
            if swapped:
                try:
                    unregister(TARGET)
                except BaseException as rollback_error:
                    rollback_errors.append(str(rollback_error))
            try:
                if swapped:
                    TARGET.rename(stage)
                if present(old):
                    if retained:
                        retained['moves'].append({'from': str(old), 'to': str(TARGET), 'state': 'planned'})
                        persist_rollback()
                    old.rename(TARGET)
                if original_info:
                    verify_original(TARGET, original_info, original_manifest, original_identity)
                    program_restored = True
                    if retained:
                        retained.update(authoritativePath=str(TARGET), fullInventoryVerified=True, sameObjectVerified=True)
                        if retained['moves']:
                            retained['moves'][-1]['state'] = 'verified'
                        persist_rollback()
                else:
                    program_restored = not present(TARGET)
            except BaseException as rollback_error:
                rollback_errors.append(str(rollback_error))
            for path in (source, stage, old):
                try:
                    unregister(path)
                except BaseException as cleanup_error:
                    rollback_errors.append(str(cleanup_error))
            if original_info and program_restored:
                try:
                    run(LS, '-f', str(TARGET))
                except BaseException as rollback_error:
                    rollback_errors.append(str(rollback_error))
            if program_restored:
                try:
                    shutil.rmtree(staging)
                    record['temporaryAppsRemoved'] = True
                except BaseException as cleanup_error:
                    rollback_errors.append(str(cleanup_error))
            record.update(status='failed', installedVerified=False, error=str(error), rollbackErrors=rollback_errors,
                          rollbackProgramVerified=program_restored)
            persist_rollback()
            if rollback_errors:
                raise RuntimeError('Install failed; rollback requires attention; receipt: ' + str(receipt)) from error
            raise
        shutil.rmtree(staging)
        record['temporaryAppsRemoved'] = True
        persist()
        return {'installed': str(TARGET), 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                'backupRecord': str(receipt), 'restoreVerification': str(backup / 'restore-verification.json') if original_info or 'preferencesBackupVerification' in record else None,
                'previousAppArchive': record['archivedBackups'].get('app'),
                'retainedOriginalProgram': retained, 'gui_verified': False, 'firstInstall': record['firstInstall']}


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: install.py /absolute/release.zip OR /private/path.noindex/搞整理.app')
    with candidate(sys.argv[1]) as source:
        result = install(source)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
