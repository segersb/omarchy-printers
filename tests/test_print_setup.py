import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import print_setup as setup


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = Path(self.tmp.name)
        home = patch.object(setup.Path, 'home', return_value=p / 'home')
        home.start()
        self.addCleanup(home.stop)
        env = {'XDG_CONFIG_HOME': str(p/'config'), 'XDG_DATA_HOME': str(p/'data'), 'XDG_STATE_HOME': str(p/'state')}
        self.patch = patch.dict(os.environ, env)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        for name, value in [('dependencies', []), ('reload_portal', True), ('reload_bus', True), ('restart_files_quietly', None)]:
            mock = patch.object(setup, name, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)

    def test_enable_restore_keeps_other_interfaces_and_comments(self):
        config, _, state = setup.paths()
        config.parent.mkdir(parents=True)
        original = '# user configuration\n[preferred]\ndefault=hyprland;gtk\n' + setup.KEY + '=gtk\norg.freedesktop.impl.portal.FileChooser=gtk\n'
        config.write_text(original)
        self.assertTrue(setup.enable()['enabled'])
        self.assertEqual(setup.preference(config.read_text()), setup.PROVIDER)
        setup.restore()
        self.assertEqual(setup.preference(config.read_text()), 'gtk')
        self.assertIn('# user configuration', config.read_text())
        self.assertIn('FileChooser=gtk', config.read_text())
        self.assertFalse(state.exists())

    def test_restore_removes_new_config_and_repeat_enable_is_safe(self):
        config, data, _ = setup.paths()
        setup.enable()
        setup.enable()
        setup.restore()
        self.assertFalse(config.exists())
        for path in setup.integration_files(data):
            self.assertFalse(path.exists())

    def test_restore_preserves_later_unrelated_preferences(self):
        config, _, _ = setup.paths()
        setup.enable()
        config.write_text(config.read_text() + 'org.freedesktop.impl.portal.ScreenCast=hyprland\n')
        setup.restore()
        self.assertIn('ScreenCast=hyprland', config.read_text())
        self.assertIsNone(setup.preference(config.read_text()))

    def test_external_print_change_is_preserved(self):
        config, _, _ = setup.paths()
        setup.enable()
        config.write_text(setup.set_preference(config.read_text(), 'another-provider'))
        setup.restore()
        self.assertEqual(setup.preference(config.read_text()), 'another-provider')

    def test_missing_dependencies_do_not_mutate(self):
        config, _, state = setup.paths()
        with patch.object(setup, 'dependencies', return_value=['cairo']), self.assertRaises(ValueError):
            setup.enable()
        self.assertFalse(config.exists())
        self.assertFalse(state.exists())

    def test_existing_integration_is_not_overwritten(self):
        _, data, _ = setup.paths()
        file = next(iter(setup.integration_files(data)))
        file.parent.mkdir(parents=True)
        file.write_text('external')
        with self.assertRaises(ValueError):
            setup.enable()
        self.assertEqual(file.read_text(), 'external')

    def test_new_config_inherits_generic_preferences(self):
        config, _, _ = setup.paths()
        config.parent.mkdir(parents=True)
        config.with_name('portals.conf').write_text('[preferred]\ndefault=gtk\norg.freedesktop.impl.portal.FileChooser=custom\n')
        setup.enable()
        self.assertIn('FileChooser=custom', config.read_text())

    def test_only_preferred_section_key_is_changed(self):
        text = '[preferred]\ndefault=gtk\n[other]\n' + setup.KEY + '=leave-me\n'
        updated = setup.set_preference(text, 'ours')
        self.assertIn('[other]\n' + setup.KEY + '=leave-me', updated)
        self.assertEqual(setup.preference(updated), 'ours')

    def test_files_can_be_enabled_without_changing_print_provider(self):
        config, data, _ = setup.paths()
        setup.update('files', True)
        self.assertFalse(config.exists())
        self.assertTrue(setup.status()['integrations']['files']['enabled'])
        self.assertFalse(setup.status()['integrations']['portal']['enabled'])
        self.assertTrue((data / f'dbus-1/services/{setup.NAME}.service').exists())
        setup.update('files', False)
        self.assertFalse((data / f'dbus-1/services/{setup.NAME}.service').exists())

    def test_shared_bus_service_survives_either_independent_restore(self):
        for first, remaining in [('portal', 'files'), ('files', 'portal')]:
            setup.enable()
            setup.update(first, False)
            self.assertTrue(setup.status()['integrations'][remaining]['enabled'])
            _, data, _ = setup.paths()
            self.assertTrue((data / f'dbus-1/services/{setup.NAME}.service').exists())
            setup.restore()

    def test_settings_launcher_is_executable_and_restorable(self):
        setup.update('settings', True)
        launcher = next(iter(setup.settings_files()))
        self.assertTrue(os.access(launcher, os.X_OK))
        self.assertTrue(setup.status()['integrations']['settings']['managed'])
        self.assertEqual(setup.status()['integrations']['settings']['label'], 'Log in again')
        setup.update('settings', False)
        self.assertFalse(launcher.exists())
        self.assertFalse(setup.paths()[0].exists())

    def test_existing_launcher_conflict_and_external_edit_are_preserved(self):
        launcher = next(iter(setup.settings_files()))
        launcher.parent.mkdir(parents=True)
        launcher.write_text('my launcher')
        with self.assertRaises(ValueError):
            setup.update('settings', True)
        self.assertEqual(launcher.read_text(), 'my launcher')
        launcher.unlink()
        setup.update('settings', True)
        launcher.write_text('edited launcher')
        with self.assertRaises(ValueError):
            setup.update('settings', False)
        self.assertEqual(launcher.read_text(), 'edited launcher')
        self.assertEqual(setup.status()['integrations']['settings']['label'], 'Needs attention')

    def test_status_recognizes_legacy_override_without_mutation(self):
        launcher = next(iter(setup.settings_files()))
        launcher.parent.mkdir(parents=True)
        launcher.write_text(setup.OVERRIDE)
        self.assertEqual(setup.status()['integrations']['settings']['label'], 'Log in again')
        launcher.chmod(0o755)
        with patch.object(setup.shutil, 'which', return_value=str(launcher)):
            self.assertEqual(setup.status()['integrations']['settings']['label'], 'Enabled')
        self.assertFalse(setup.paths()[2].exists())
        setup.update('settings', False)
        self.assertFalse(launcher.exists())

    def test_legacy_combined_registration_splits_without_losing_restore(self):
        setup.enable()
        config, _, state = setup.paths()
        saved = json.loads(state.read_text())
        del saved['version']
        del saved['parts']
        state.write_text(json.dumps(saved))
        setup.update('files', False)
        self.assertTrue(setup.status()['integrations']['portal']['enabled'])
        setup.update('portal', False)
        self.assertFalse(config.exists())
        self.assertFalse(state.exists())

    def test_symlink_destination_is_not_overwritten(self):
        launcher = next(iter(setup.settings_files()))
        launcher.parent.mkdir(parents=True)
        target = launcher.with_name('other')
        target.write_text(setup.OVERRIDE)
        launcher.symlink_to(target)
        with self.assertRaises(ValueError):
            setup.update('settings', True)
        self.assertTrue(launcher.is_symlink())
        self.assertEqual(target.read_text(), setup.OVERRIDE)

    def test_loaded_files_extension_stops_after_removal(self):
        import types
        from unittest.mock import Mock
        _, data, _ = setup.paths()
        extension = data / 'nautilus-python/extensions/omarchy_print.py'
        source = setup.integration_files(data)[extension]
        extension.parent.mkdir(parents=True)
        extension.write_text(source)
        menu = Mock()
        nautilus = types.SimpleNamespace(MenuProvider=type('MenuProvider', (), {}),
                                        MenuItem=Mock(return_value=menu))
        repository = types.ModuleType('gi.repository')
        repository.Nautilus = nautilus
        repository.GObject = types.SimpleNamespace(GObject=type('GObject', (), {}))
        namespace = {'__file__': str(extension)}
        with patch.dict(sys.modules, {'gi.repository': repository}):
            exec(compile(source, str(extension), 'exec'), namespace)
        provider = namespace['OmarchyPrintMenu']()
        file = Mock()
        file.get_mime_type.return_value = 'image/png'
        file.get_location.return_value.get_path.return_value = '/tmp/picture.png'
        self.assertEqual(provider.get_file_items([file]), [menu])
        activate = menu.connect.call_args.args[1]
        extension.unlink()
        self.assertEqual(provider.get_file_items([file]), [])
        with patch('subprocess.Popen') as launch:
            activate()
            launch.assert_not_called()

    def test_restart_reopens_folders_when_quit_returns_255(self):
        import dbus
        from unittest.mock import Mock
        bus = Mock()
        bus.name_has_owner.side_effect = [True, True, False, True]
        interface = Mock()
        interface.Get.return_value = ['file:///tmp/a folder', 'file:///tmp/another']
        with patch.object(dbus, 'SessionBus', return_value=bus), patch.object(dbus, 'Interface', return_value=interface), \
             patch.object(setup.subprocess, 'run', return_value=Mock(returncode=255)), \
             patch.object(setup.subprocess, 'Popen') as launch:
            setup.restart_files()
        self.assertEqual(launch.call_args.args[0], ['nautilus', '--', 'file:///tmp/a folder', 'file:///tmp/another'])

    def test_restart_does_not_force_quit_running_files(self):
        import dbus
        from unittest.mock import Mock
        bus = Mock()
        bus.name_has_owner.return_value = True
        interface = Mock()
        interface.Get.return_value = []
        with patch.object(dbus, 'SessionBus', return_value=bus), patch.object(dbus, 'Interface', return_value=interface), \
             patch.object(setup.subprocess, 'run'), patch.object(setup.time, 'sleep'), \
             patch.object(setup.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                setup.restart_files()
            launch.assert_not_called()

    def test_files_changes_restart_but_other_integrations_do_not(self):
        with patch.object(setup, 'restart_files_quietly') as restart:
            setup.update('files', True)
            self.assertEqual(restart.call_count, 1)
            setup.update('portal', True)
            self.assertEqual(restart.call_count, 1)
            setup.update('files', False)
            self.assertEqual(restart.call_count, 2)

    def test_restart_does_not_open_files_when_not_running(self):
        import dbus
        from unittest.mock import Mock
        bus = Mock()
        bus.name_has_owner.return_value = False
        with patch.object(dbus, 'SessionBus', return_value=bus), patch.object(setup.subprocess, 'Popen') as launch:
            setup.restart_files()
            launch.assert_not_called()

    def test_enable_all_enables_missing_and_restarts_files_once(self):
        with patch.object(setup, 'restart_files_quietly') as restart, patch.object(setup, 'reload_portal') as portal:
            setup.update('all', True)
            self.assertTrue(all(x['managed'] for x in setup.status()['integrations'].values()))
            restart.assert_called_once()
            portal.assert_called_once()
            setup.update('all', True)
            restart.assert_called_once()
            portal.assert_called_once()

    def test_enable_all_leaves_enabled_files_and_portal_running(self):
        setup.enable()
        with patch.object(setup, 'restart_files_quietly') as restart, patch.object(setup, 'reload_portal') as portal:
            setup.update('all', True)
            restart.assert_not_called()
            portal.assert_not_called()
        self.assertTrue(setup.status()['integrations']['settings']['managed'])

    def interrupted_upgrade(self):
        setup.update('files', True)
        original = setup.integration_files
        def upgraded(data):
            files = original(data)
            for path in files:
                files[path] += '# Updated plugin version\n'
            return files
        version = patch.object(setup, 'integration_files', upgraded)
        version.start()
        self.addCleanup(version.stop)
        original_atomic = setup.atomic
        def fail(path, content):
            # The shared service is already updated, but the desktop file isn't.
            if path.suffix == '.desktop':
                raise OSError('simulated disk failure')
            return original_atomic(path, content)
        with patch.object(setup, 'atomic', fail), self.assertRaises(OSError):
            setup.update('files', True)
        return setup.paths()[1]

    def test_interrupted_upgrade_can_retry_both_file_versions(self):
        self.interrupted_upgrade()
        setup.update('all', True)
        self.assertTrue(setup.status()['integrations']['files']['enabled'])
        saved = setup.load_state()
        self.assertNotIn('pending_files', saved)
        for name, content in saved['files'].items():
            self.assertTrue(setup.matches(Path(name), content))

    def test_interrupted_upgrade_can_restore_both_file_versions(self):
        data = self.interrupted_upgrade()
        setup.restore()
        for path in setup.integration_files(data):
            self.assertFalse(path.exists())
        self.assertFalse(setup.paths()[2].exists())

    def test_interrupted_upgrade_still_rejects_external_edits(self):
        data = self.interrupted_upgrade()
        path = data / 'applications/omarchy-print-image.desktop'
        path.write_text('user-owned edit')
        with self.assertRaises(ValueError):
            setup.restore()
        self.assertEqual(path.read_text(), 'user-owned edit')

    def test_interrupted_portal_restore_retries_preference_change(self):
        config, _, state = setup.paths()
        config.parent.mkdir(parents=True)
        original = '[preferred]\ndefault=gtk\n' + setup.KEY + '=gtk\n'
        config.write_text(original)
        setup.update('portal', True)
        atomic = setup.atomic
        def fail(path, content):
            if path == config:
                raise OSError('simulated disk failure')
            return atomic(path, content)
        with patch.object(setup, 'atomic', fail), self.assertRaises(OSError):
            setup.restore()
        self.assertTrue(setup.status()['managed'])
        setup.restore()
        self.assertEqual(config.read_text(), original)
        self.assertFalse(state.exists())

    def test_pending_journal_cannot_claim_arbitrary_paths(self):
        setup.update('files', True)
        _, _, state = setup.paths()
        saved = json.loads(state.read_text())
        saved['pending_files'] = {str(Path(self.tmp.name) / 'unrelated'): 'data'}
        state.write_text(json.dumps(saved))
        with self.assertRaises(ValueError):
            setup.restore()
