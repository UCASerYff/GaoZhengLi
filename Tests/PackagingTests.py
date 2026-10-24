#!/usr/bin/env python3
"""Isolated packaging/rollback tests: real ditto on fixtures; no GUI, install or LS calls."""
import importlib.util
import contextlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gaozhengli_installer', PROJECT / 'Scripts/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
REAL_RUN = subprocess.run


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gaozhengli-packaging-tests-', suffix='.noindex', dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.target = self.root / 'Applications/搞整理.app'
        self.target.parent.mkdir()
        self.source = self.root / 'release/搞整理.app'
        self.data = self.root / 'Data'
        self.data.mkdir(mode=0o700)
        self.backups = self.root / 'Backups'
        self.prefs = self.root / 'Preferences.plist'
        for name in installer.EXPECTED:
            path = self.data / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('fixture:' + name).encode())
        (self.data / '.app.lock').touch(mode=0o600)
        (self.data / 'metadata.sqlite-wal').write_bytes(b'fixture-uncheckpointed-wal')
        (self.data / 'metadata.sqlite-shm').write_bytes(b'fixture-shm')
        (self.data / 'Attachments').mkdir()
        (self.data / 'Attachments/private.bin').write_bytes(b'fixture-private-attachment')
        (self.data / 'Empty').mkdir()
        self.prefs.write_bytes(plistlib.dumps({'GaoZhengLi.initialized.v1': True, 'fixtureSetting': 'kept'}))
        os.chmod(self.prefs, 0o600)
        self.make_app(self.target, '1.00', '1')
        self.make_app(self.source, '1.01', '2')
        self.commands = []
        self.fail = None
        self.running = False
        self.patchers = [mock.patch.object(installer, name, value) for name, value in
                         [('TARGET', self.target), ('DATA', self.data), ('BACKUPS', self.backups), ('PREFS', self.prefs)]]
        for patcher in self.patchers:
            patcher.start()
        self.patchers.append(mock.patch.object(installer.subprocess, 'run', self.command))
        self.patchers[-1].start()

    def tearDown(self):
        for patcher in reversed(self.patchers):
            patcher.stop()
        self.temp.cleanup()

    def make_app(self, path, version, build):
        (path / 'Contents/MacOS').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': installer.BUNDLE, 'CFBundleExecutable': 'GaoZhengLi',
            'CFBundleShortVersionString': version, 'CFBundleVersion': build}))
        exe = path / 'Contents/MacOS/GaoZhengLi'
        exe.write_bytes(('fixture-version-' + version).encode())
        exe.chmod(0o755)

    def command(self, args, **kwargs):
        args = tuple(map(str, args))
        self.commands.append(args)
        if self.fail:
            result = self.fail(args, kwargs)
            if result is not None:
                return result
        if args[0] == '/usr/bin/ditto':
            # Archive/copy/extraction paths are all synthetic fixtures or private temporary paths.
            return REAL_RUN(args, **kwargs)
        if args[0] == '/usr/bin/pgrep':
            return subprocess.CompletedProcess(args, 0 if self.running else 1)
        if args[0] == '/usr/bin/defaults':
            return subprocess.CompletedProcess(args, 0, '1\n', '')
        if args[0] in ('/usr/bin/codesign', installer.LS):
            return subprocess.CompletedProcess(args, 0, '', '')
        raise AssertionError('Unexpected external command: ' + repr(args))

    def receipt(self):
        paths = list(self.backups.glob('Install-*/install-record.json'))
        self.assertEqual(len(paths), 1)
        return paths[0], json.loads(paths[0].read_text())

    def assert_old_target(self):
        self.assertEqual(installer.plist(self.target)['CFBundleVersion'], '1')
        self.assertFalse(list(self.target.parent.glob('*.noindex')))
        self.assertFalse(list(self.backups.rglob('*.app')))

    def test_expected_files_match_app_initialization_contract(self):
        source = (PROJECT / 'Sources/Configuration.swift').read_text()
        names = re.search(r'let expected = (\[[^\n]+\])', source).group(1)
        self.assertEqual(list(installer.EXPECTED), json.loads(names))

    def test_success_archives_app_and_preserves_all_state(self):
        before = installer.state_snapshot()
        result = installer.install(self.source)
        self.assertEqual(installer.state_snapshot(), before)
        self.assertEqual(installer.plist(self.target)['CFBundleVersion'], '2')
        self.assertFalse(list(self.target.parent.glob('*.noindex')))
        receipt_path, record = self.receipt()
        archive = record['archivedBackups']['app']
        self.assertEqual(archive['sha256'], installer.sha256(Path(archive['path'])))
        self.assertTrue(archive['inventoryVerified'] and archive['signatureVerified'])
        self.assertIn('metadata.sqlite-wal', record['backups']['data'])
        self.assertIn('metadata.sqlite-shm', record['backups']['data'])
        self.assertIn('Attachments/private.bin', record['backups']['data'])
        self.assertIn('Empty', record['backups']['data'])
        self.assertEqual(record['backups']['data'], before['data'])
        restore = json.loads(Path(result['restoreVerification']).read_text())
        self.assertEqual(restore['inventory'], record['backups']['app'])
        self.assertEqual(record['status'], 'installed-verified')
        self.assertTrue(record['temporaryAppsRemoved'])
        self.assertEqual(Path(result['backupRecord']), receipt_path)
        self.assertFalse(list(self.backups.rglob('*.app')))
        registrations = [args for args in self.commands if args[0] == installer.LS]
        self.assertEqual(len(registrations), 4)
        self.assertEqual(registrations[-1], (installer.LS, '-f', str(self.target)))
        self.assertTrue(all(len(args) == 3 and args[1] in ('-u', '-f') for args in registrations))

    def test_release_zip_extracts_only_in_private_noindex(self):
        archive = self.root / 'release.zip'
        REAL_RUN(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(self.source), str(archive)], check=True)
        with installer.candidate(str(archive)) as extracted:
            self.assertEqual(installer.inventory(extracted), installer.inventory(self.source))
            self.assertTrue(extracted.parent.name.endswith('.noindex'))
            extracted_root = extracted.parent
        self.assertFalse(extracted_root.exists())

    def test_running_app_aborts_before_backup_or_program_mutation(self):
        self.running = True
        before = installer.inventory(self.target)
        with self.assertRaisesRegex(RuntimeError, 'Quit'):
            installer.install(self.source)
        self.assertEqual(installer.inventory(self.target), before)
        self.assertFalse(self.backups.exists())

    def test_missing_initialized_file_fails_closed(self):
        (self.data / 'configuration.json').unlink()
        with self.assertRaisesRegex(RuntimeError, 'incomplete'):
            installer.install(self.source)
        self.assert_old_target()
        self.assertFalse(self.backups.exists())

    def test_missing_initialized_data_fails_closed(self):
        import shutil
        shutil.rmtree(self.data)
        with self.assertRaisesRegex(RuntimeError, 'incomplete'):
            installer.install(self.source)
        self.assertFalse(self.data.exists())
        self.assert_old_target()

    def test_unreadable_walk_is_not_an_empty_inventory(self):
        def denied(*args, **kwargs):
            kwargs['onerror'](PermissionError('fixture inaccessible subtree'))
            return iter(())
        with mock.patch.object(installer.os, 'walk', denied):
            with self.assertRaises(PermissionError):
                installer.inventory(self.data)

    def test_failed_installed_signature_restores_old_app(self):
        before = installer.state_snapshot()
        def fail(args, kwargs):
            if args[0] == '/usr/bin/codesign' and args[-1] == str(self.target) and installer.plist(self.target)['CFBundleVersion'] == '2':
                raise subprocess.CalledProcessError(1, args)
        self.fail = fail
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(installer.state_snapshot(), before)
        _, record = self.receipt()
        self.assertTrue(record['rollbackProgramVerified'])
        self.assertFalse(record['installedVerified'])

    def test_registration_failure_cannot_block_program_rollback(self):
        before = installer.state_snapshot()
        def fail(args, kwargs):
            if args[:2] == (installer.LS, '-f'):
                raise subprocess.CalledProcessError(1, args)
            if args[:3] == (installer.LS, '-u', str(self.target)):
                return subprocess.CompletedProcess(args, 1, '', 'fixture registry inaccessible')
        self.fail = fail
        with self.assertRaisesRegex(RuntimeError, 'rollback requires attention'):
            installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(installer.state_snapshot(), before)
        _, record = self.receipt()
        self.assertTrue(record['rollbackProgramVerified'])
        self.assertTrue(record['rollbackErrors'])

    def test_failed_source_unregister_restores_old_app(self):
        def fail(args, kwargs):
            if args[:3] == (installer.LS, '-u', str(self.source)):
                return subprocess.CompletedProcess(args, 1, '', 'fixture unregister failed')
        self.fail = fail
        with self.assertRaises(RuntimeError):
            installer.install(self.source)
        self.assert_old_target()
        self.assertTrue(self.receipt()[1]['rollbackProgramVerified'])

    def test_external_data_change_is_detected_and_preserved_for_recovery(self):
        before = installer.state_snapshot()
        changed = self.data / 'configuration.json'
        def fail(args, kwargs):
            if args[:2] == (installer.LS, '-f') and installer.plist(self.target)['CFBundleVersion'] == '2':
                changed.write_bytes(b'external fixture change')
        self.fail = fail
        with self.assertRaisesRegex(RuntimeError, 'changed during installation'):
            installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(changed.read_bytes(), b'external fixture change')
        _, record = self.receipt()
        self.assertEqual(record['backups']['data'], before['data'])
        self.assertEqual((Path(self.receipt()[0]).parent / 'Data/configuration.json').read_bytes(), b'fixture:configuration.json')

    def test_corrupt_restore_archive_aborts_before_replacement(self):
        with mock.patch.object(installer, 'verify_archive', side_effect=RuntimeError('fixture restore mismatch')):
            with self.assertRaisesRegex(RuntimeError, 'restore mismatch'):
                installer.install(self.source)
        self.assert_old_target()

    def macl_fixture_inventory(self, other_attribute=False):
        # Simulate the protected attribute in inventory only; never write com.apple.macl.
        original = installer.inventory
        original_inode = self.target.stat().st_ino
        def read(path):
            result = original(path)
            if path.stat().st_ino == original_inode:
                result['.']['xattrs']['com.apple.macl'] = 'fixture-protected-macl-sha256'
                if other_attribute:
                    result['.']['xattrs']['fixture.non-macl'] = 'fixture-other-sha256'
            return result
        return read

    def audit_original_rename(self, path, destination, real_rename):
        destination = Path(destination)
        if path.parent.name == 'Program.noindex' or destination.parent.name == 'Program.noindex':
            _, record = self.receipt()
            retained = record['retainedOriginalProgram']
            self.assertEqual(retained['authoritativePath'], str(path))
            self.assertEqual(retained['moves'][-1],
                             {'from': str(path), 'to': str(destination), 'state': 'planned'})
            self.assertIn('com.apple.macl', record['backups']['app']['.']['xattrs'])
            restore = json.loads((self.receipt()[0].parent / 'restore-verification.json').read_text())
            self.assertEqual(restore['authoritativeOriginalProgram'], retained)
        return real_rename(path, destination)

    def test_root_macl_only_fallback_retains_exact_original_object(self):
        identity = installer.object_identity(self.target)
        real_inventory = installer.inventory(self.target)
        before = installer.state_snapshot()
        with mock.patch.object(installer, 'inventory', self.macl_fixture_inventory()):
            expected = installer.inventory(self.target)
            real_rename = Path.rename
            with mock.patch.object(Path, 'rename', lambda path, destination: self.audit_original_rename(path, destination, real_rename)):
                result = installer.install(self.source)
            retained = result['retainedOriginalProgram']
            original = Path(retained['authoritativePath'])
            self.assertEqual(original, Path(retained['path']))
            self.assertEqual(original.name, self.target.name)
            self.assertEqual(original.parent.name, 'Program.noindex')
            self.assertEqual(stat.S_IMODE(original.parent.stat().st_mode), 0o700)
            self.assertEqual(installer.object_identity(original), identity)
            self.assertEqual(installer.inventory(original), expected)
            self.assertTrue(retained['fullInventoryVerified'] and retained['sameObjectVerified'])
            self.assertEqual(retained['moves'], [{'from': str(self.target), 'to': str(original), 'state': 'verified'}])
            self.assertFalse(result['previousAppArchive']['inventoryVerified'])
            self.assertTrue(result['previousAppArchive']['supplementalOnly'])
            self.assertEqual(result['previousAppArchive']['missingMetadata'],
                             {'.': {'com.apple.macl': 'fixture-protected-macl-sha256'}})
            _, record = self.receipt()
            self.assertEqual(record['backups']['app'], expected)
            restore = json.loads(Path(result['restoreVerification']).read_text())
            self.assertEqual(restore['authoritativeOriginalProgram'], retained)
            self.assertFalse(restore['archive']['inventoryVerified'])
            self.assertEqual(installer.state_snapshot(), before)
            self.assertEqual(installer.plist(self.target)['CFBundleVersion'], '2')
        self.assertEqual(installer.inventory(original), real_inventory)
        self.assertEqual(list(self.backups.rglob('*.app')), [original])
        self.assertIn((installer.LS, '-u', str(original)), self.commands)
        self.assertFalse(list(self.target.parent.glob('*.noindex')))

    def test_root_macl_fallback_rollback_restores_same_object_and_metadata(self):
        identity = installer.object_identity(self.target)
        before = installer.state_snapshot()
        def fail(args, kwargs):
            if args[0] == '/usr/bin/codesign' and args[-1] == str(self.target) and installer.plist(self.target)['CFBundleVersion'] == '2':
                raise subprocess.CalledProcessError(1, args)
        self.fail = fail
        with mock.patch.object(installer, 'inventory', self.macl_fixture_inventory()):
            expected = installer.inventory(self.target)
            real_rename = Path.rename
            with mock.patch.object(Path, 'rename', lambda path, destination: self.audit_original_rename(path, destination, real_rename)):
                with self.assertRaises(subprocess.CalledProcessError):
                    installer.install(self.source)
            self.assertEqual(installer.inventory(self.target), expected)
            self.assertEqual(installer.object_identity(self.target), identity)
            _, record = self.receipt()
            retained = record['retainedOriginalProgram']
            self.assertEqual(retained['authoritativePath'], str(self.target))
            self.assertTrue(retained['fullInventoryVerified'] and retained['sameObjectVerified'])
            self.assertTrue(record['rollbackProgramVerified'])
            self.assertEqual(len(retained['moves']), 2)
            self.assertEqual(retained['moves'][1], {'from': retained['path'], 'to': str(self.target), 'state': 'verified'})
        self.assert_old_target()
        self.assertEqual(installer.state_snapshot(), before)

    def test_non_macl_archive_difference_refuses_original_retention(self):
        identity = installer.object_identity(self.target)
        with mock.patch.object(installer, 'inventory', self.macl_fixture_inventory(other_attribute=True)):
            with self.assertRaisesRegex(RuntimeError, 'Archive restore verification failed'):
                installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(installer.object_identity(self.target), identity)
        _, record = self.receipt()
        self.assertEqual(record['status'], 'failed-before-replacement')
        self.assertTrue(record['oldProgramUnchanged'])
        self.assertNotIn('retainedOriginalProgram', record)
        self.assertFalse(any(args[0] == installer.LS for args in self.commands))

    def test_persistent_receipt_failure_after_original_move_restores_original(self):
        import copy
        import errno
        identity = installer.object_identity(self.target)
        before = installer.state_snapshot()
        real_write = installer.write_record
        failed_writes = []
        fault = False
        def receipt_unavailable(path, record):
            nonlocal fault
            if not self.target.exists() and list(self.backups.glob('Install-*/Program.noindex/搞整理.app')):
                fault = True
            if fault:
                failed_writes.append(copy.deepcopy(record))
                raise OSError(errno.ENOSPC, 'fixture persistent receipt volume full')
            return real_write(path, record)
        with mock.patch.object(installer, 'inventory', self.macl_fixture_inventory()):
            expected = installer.inventory(self.target)
            with mock.patch.object(installer, 'write_record', receipt_unavailable):
                with self.assertRaisesRegex(RuntimeError, 'rollback requires attention'):
                    installer.install(self.source)
            self.assertEqual(installer.inventory(self.target), expected)
            self.assertEqual(installer.object_identity(self.target), identity)
        self.assertTrue(fault)
        self.assertGreaterEqual(len(failed_writes), 4)
        final_attempt = failed_writes[-1]
        self.assertEqual(final_attempt['status'], 'failed')
        self.assertTrue(final_attempt['rollbackProgramVerified'])
        self.assertFalse(final_attempt['installedVerified'])
        self.assertEqual(final_attempt['retainedOriginalProgram']['authoritativePath'], str(self.target))
        self.assertEqual(final_attempt['retainedOriginalProgram']['moves'][-1]['state'], 'verified')
        _, durable = self.receipt()
        self.assertEqual(durable['retainedOriginalProgram']['authoritativePath'], str(self.target))
        self.assertEqual(durable['retainedOriginalProgram']['moves'][-1]['state'], 'planned')
        self.assertEqual(installer.state_snapshot(), before)
        self.assert_old_target()
        self.assertIn((installer.LS, '-f', str(self.target)), self.commands)

    def test_root_macl_fallback_refuses_cross_device_original_move(self):
        identity_function = installer.object_identity
        def different_device(path):
            result = identity_function(path)
            return dict(result, device=result['device'] + 1)
        with mock.patch.object(installer, 'inventory', self.macl_fixture_inventory()):
            with mock.patch.object(installer, 'object_identity', different_device):
                with self.assertRaisesRegex(RuntimeError, 'same filesystem'):
                    installer.install(self.source)
        self.assert_old_target()
        _, record = self.receipt()
        self.assertEqual(record['status'], 'failed-before-replacement')
        self.assertTrue(record['oldProgramUnchanged'])


    def preference_metadata_fixture(self, variant='addition'):
        native = installer.preferences_entry
        original_attrs = {'fixture.original': 'a' * 64}
        if variant == 'existing-provenance-changed':
            original_attrs['com.apple.provenance'] = 'b' * 64
        def read(path):
            value = native(path)
            value['xattrs'] = dict(original_attrs)
            if path != self.prefs:
                if variant == 'changed':
                    value['xattrs']['fixture.original'] = 'c' * 64
                elif variant == 'missing':
                    value['xattrs'].pop('fixture.original')
                elif variant == 'other-extra':
                    value['xattrs']['fixture.other'] = 'd' * 64
                elif variant == 'owner-changed':
                    value['uid'] += 1
                elif variant == 'existing-provenance-changed':
                    value['xattrs']['com.apple.provenance'] = 'e' * 64
                else:
                    value['xattrs']['com.apple.provenance'] = 'f' * 64
                    if variant == 'restore-changed' and path.parent.name.startswith('gaozhengli-preferences-restore-'):
                        value['xattrs']['com.apple.provenance'] = '0' * 64
            return value
        return read

    def preference_metadata_context(self, variant='addition'):
        native_entry = installer.entry
        read = self.preference_metadata_fixture(variant)
        source_attrs = read(self.prefs)['xattrs']
        def source_entry(path):
            value = native_entry(path)
            if path == self.prefs:
                value['xattrs'] = dict(source_attrs)
            return value
        stack = contextlib.ExitStack()
        stack.enter_context(mock.patch.object(installer, 'entry', source_entry))
        stack.enter_context(mock.patch.object(installer, 'preferences_entry', read))
        return stack

    def test_preferences_only_provenance_addition_records_both_receipts(self):
        before = installer.state_snapshot()
        identity = installer.object_identity(self.prefs)
        with self.preference_metadata_context():
            with mock.patch.object(installer, 'xattr_length', return_value=17):
                result = installer.install(self.source)
        _, record = self.receipt()
        proof = record['preferencesBackupVerification']
        self.assertEqual(proof['type'], 'preferences-added-provenance')
        self.assertFalse(proof['inventoryEqual'])
        self.assertEqual(proof['sourceIdentity'], identity)
        self.assertTrue(proof['sourceIdentityAndEntryUnchanged'])
        self.assertEqual(proof['originalEntry']['uid'], self.prefs.stat().st_uid)
        self.assertEqual(proof['originalEntry']['gid'], self.prefs.stat().st_gid)
        self.assertEqual(proof['addedAttrProof'], {'com.apple.provenance': {'length': 17, 'sha256': 'f' * 64}})
        self.assertTrue(proof['restoreRehearsal']['backupEntryEqual'])
        self.assertTrue(proof['restoreRehearsal']['allOriginalAttributesPreserved'])
        self.assertFalse(proof['restoreRehearsal']['originalInventoryEqual'])
        self.assertEqual(proof['restoreRehearsal']['restoredEntry'], proof['backupEntry'])
        self.assertEqual(record['backups']['preferences'], {k: v for k, v in proof['originalEntry'].items() if k not in ('uid', 'gid')})
        restore = json.loads(Path(result['restoreVerification']).read_text())
        self.assertEqual(restore['preferencesBackupVerification'], proof)
        self.assertEqual(installer.state_snapshot(), before)
        self.assertEqual(installer.object_identity(self.prefs), identity)
        self.assertEqual(installer.plist(self.target)['CFBundleVersion'], '2')

    def assert_preferences_metadata_refused(self, variant):
        before = installer.state_snapshot()
        with self.preference_metadata_context(variant):
            with mock.patch.object(installer, 'xattr_length', return_value=17):
                with self.assertRaises(RuntimeError):
                    installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(installer.state_snapshot(), before)
        _, record = self.receipt()
        self.assertEqual(record['status'], 'failed-before-replacement')
        self.assertTrue(record['oldProgramUnchanged'])
        self.assertNotIn('preferencesBackupVerification', record)
        self.assertFalse(any(args[0] == installer.LS for args in self.commands))

    def test_preferences_original_metadata_changed_is_rejected(self):
        self.assert_preferences_metadata_refused('changed')

    def test_preferences_original_metadata_missing_is_rejected(self):
        self.assert_preferences_metadata_refused('missing')

    def test_preferences_other_added_metadata_is_rejected(self):
        self.assert_preferences_metadata_refused('other-extra')

    def test_preferences_existing_provenance_changed_is_rejected(self):
        self.assert_preferences_metadata_refused('existing-provenance-changed')

    def test_preferences_owner_change_is_rejected(self):
        self.assert_preferences_metadata_refused('owner-changed')

    def test_preferences_restore_metadata_change_is_rejected(self):
        self.assert_preferences_metadata_refused('restore-changed')

    def test_preferences_copy_failure_aborts_before_program_replacement(self):
        before = installer.state_snapshot()
        def fail(args, kwargs):
            if args[0] == '/usr/bin/ditto' and args[-2] == str(self.prefs):
                raise subprocess.CalledProcessError(1, args)
        self.fail = fail
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(installer.state_snapshot(), before)
        _, record = self.receipt()
        self.assertEqual(record['status'], 'failed-before-replacement')
        self.assertTrue(record['oldProgramUnchanged'])
        self.assertFalse(any(args[0] == installer.LS for args in self.commands))

    def test_preferences_restore_copy_failure_aborts_before_program_replacement(self):
        before = installer.state_snapshot()
        def fail(args, kwargs):
            if args[0] == '/usr/bin/ditto' and 'gaozhengli-preferences-restore-' in args[-1]:
                raise subprocess.CalledProcessError(1, args)
        self.fail = fail
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(installer.state_snapshot(), before)
        _, record = self.receipt()
        self.assertEqual(record['status'], 'failed-before-replacement')
        self.assertTrue(record['oldProgramUnchanged'])
        self.assertFalse(any(args[0] == installer.LS for args in self.commands))

    def test_preferences_source_identity_change_aborts_before_program_replacement(self):
        native_identity = installer.object_identity
        copied = False
        def observe_copy(args, kwargs):
            nonlocal copied
            if args[0] == '/usr/bin/ditto' and args[-2] == str(self.prefs):
                copied = True
        def changed_identity(path):
            value = native_identity(path)
            return dict(value, inode=value['inode'] + 1) if path == self.prefs and copied else value
        self.fail = observe_copy
        before = installer.state_snapshot()
        with mock.patch.object(installer, 'object_identity', changed_identity):
            with self.assertRaisesRegex(RuntimeError, 'Original preferences identity'):
                installer.install(self.source)
        self.assert_old_target()
        self.assertEqual(installer.state_snapshot(), before)
        self.assertTrue(self.receipt()[1]['oldProgramUnchanged'])


    def test_source_requires_private_nonlinked_noindex(self):
        installer.private_staging_source(self.source)
        public = self.root / 'Public.noindex'
        public.mkdir(mode=0o755)
        with self.assertRaisesRegex(RuntimeError, 'private'):
            installer.private_staging_source(public / 'fixture.app')
        with self.assertRaisesRegex(RuntimeError, 'noindex'):
            installer.private_staging_source(Path('/private/tmp/fixture.app'))
        linked = self.root / 'linked.app'
        linked.symlink_to(self.source)
        with self.assertRaisesRegex(RuntimeError, 'non-linked'):
            installer.private_staging_source(linked)

    def test_archive_rejects_path_escape_and_links(self):
        for name, mode in [('搞整理.app/../../outside', 0), ('搞整理.app/Contents/link', stat.S_IFLNK | 0o777), ('other.app/file', 0)]:
            archive = self.root / 'unsafe.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                info = zipfile.ZipInfo(name)
                info.external_attr = mode << 16
                zipped.writestr(info, b'../../outside')
            with self.assertRaises(RuntimeError):
                installer.safe_zip(archive, '搞整理.app')


if __name__ == '__main__':
    unittest.main(verbosity=2)
