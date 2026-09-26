#!/usr/bin/env python3
"""Reversible per-user integration. Never installs packages or changes defaults."""
import fcntl
import configparser
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
NAME = 'org.freedesktop.impl.portal.desktop.omarchy-printers'
PROVIDER = 'omarchy-printers'
KEY = 'org.freedesktop.impl.portal.Print'


def paths():
    home = Path.home()
    config = Path(os.environ.get('XDG_CONFIG_HOME', home / '.config'))
    data = Path(os.environ.get('XDG_DATA_HOME', home / '.local/share'))
    state = Path(os.environ.get('XDG_STATE_HOME', home / '.local/state')) / 'omarchy-printers/print-setup.json'
    return config / 'xdg-desktop-portal/hyprland-portals.conf', data, state


def dependencies():
    missing = []
    for module in ('cups', 'dbus', 'gi', 'cairo'):
        if importlib.util.find_spec(module) is None:
            missing.append(module)
    try:
        from print_document import libraries
        libraries()
        import gi
        gi.require_version('GdkPixbuf', '2.0')
        gi.require_version('Gdk', '3.0')
        from gi.repository import GdkPixbuf, Gdk  # noqa: F401
    except (ImportError, ValueError):
        missing.append('Poppler/Cairo/GdkPixbuf bindings')
    for executable in ('omarchy-shell', 'python3', 'systemctl'):
        if not shutil.which(executable):
            missing.append(executable)
    return missing


def preference(text):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(text)
    return parser.get('preferred', KEY, fallback=None)


def set_preference(text, value):
    # Change only this key; retain comments and every unrelated preference.
    lines = text.splitlines(keepends=True)
    inside, found, end = False, False, len(lines)
    indices = []
    for i, line in enumerate(lines):
        if re.match(r'\s*\[', line):
            if inside:
                end = i
            inside = line.strip() == '[preferred]'
            found |= inside
        elif inside and re.match(r'\s*' + re.escape(KEY) + r'\s*=', line):
            indices.append(i)
    for i in reversed(indices):
        del lines[i]
        if i < end:
            end -= 1
    if value is not None:
        addition = KEY + '=' + value + '\n'
        if found:
            if end and not lines[end - 1].endswith('\n'):
                lines[end - 1] += '\n'
            lines.insert(end, addition)
        else:
            if lines and not lines[-1].endswith('\n'):
                lines[-1] += '\n'
            lines.extend(['[preferred]\n', addition])
    return ''.join(lines)


def atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix=path.name + '.', delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(text)
            stream.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def integration_files(data):
    # Desktop Exec quoting is not shell quoting. Escape reserved characters.
    script = str(ROOT / 'backend/print_portal.py')
    quoted = '"' + script.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$') + '"'
    desktop_script = quoted.replace('%', '%%')
    extension = '''# Installed by the Omarchy Printers plugin; remove through its setup action.
from gi.repository import Nautilus, GObject
from pathlib import Path
import subprocess

class OmarchyPrintMenu(GObject.GObject, Nautilus.MenuProvider):
    def get_file_items(self, files):
        # Nautilus can stay alive after its last window closes.
        if not Path(__file__).is_file():
            return []
        if len(files) != 1 or files[0].get_mime_type() not in ('image/png', 'image/jpeg'):
            return []
        location = files[0].get_location().get_path()
        if not location:
            return []
        item = Nautilus.MenuItem(name='OmarchyPrinters::Print', label='Print', tip='Preview, zoom and position the image')
        item.connect('activate', lambda *_: Path(__file__).is_file() and subprocess.Popen(['python3', SCRIPT, 'image', location]))
        return [item]
'''.replace('SCRIPT', repr(script))
    return {
        data / f'dbus-1/services/{NAME}.service': f'[D-BUS Service]\nName={NAME}\nExec=/usr/bin/python3 {quoted}\n',
        data / f'xdg-desktop-portal/portals/{PROVIDER}.portal': f'[portal]\nDBusName={NAME}\nInterfaces={KEY};\n',
        data / 'applications/omarchy-print-image.desktop': '[Desktop Entry]\nType=Application\nName=Print image\nComment=Preview, zoom and position an image for printing\n' + f'Exec=/usr/bin/python3 {desktop_script} image %f\n' + 'Icon=document-print\nTerminal=false\nNoDisplay=true\nMimeType=image/png;image/jpeg;\n',
        data / 'nautilus-python/extensions/omarchy_print.py': extension,
    }


def reload_portal():
    # Only reload the portal after an explicit setup action, never on import.
    subprocess.run(['dbus-send', '--session', '--type=method_call', '--dest=org.freedesktop.DBus',
                    '/org/freedesktop/DBus', 'org.freedesktop.DBus.ReloadConfig'], check=False, timeout=10)
    result = subprocess.run(['systemctl', '--user', 'restart', 'xdg-desktop-portal.service'],
                            capture_output=True, timeout=20)
    return result.returncode == 0



OVERRIDE = "#!/bin/sh\nexec omarchy-shell shell summon segersb.omarchy-printers '{}'\n"
PATH_ENV = ('# Installed by Omarchy Printers; restore through System integration.\n'
            'case "$PATH" in\n'
            '  "$HOME/.local/bin"|"$HOME/.local/bin:"*) ;;\n'
            '  *) export PATH="$HOME/.local/bin:$PATH" ;;\n'
            'esac\n')
PARTS = ('settings', 'portal', 'files')


def settings_files():
    config, _, _ = paths()
    return {Path.home() / '.local/bin/system-config-printer': OVERRIDE,
            config.parent.parent / 'uwsm/env.d/90-omarchy-printers': PATH_ENV}


def required_files(parts):
    _, data, _ = paths()
    files = integration_files(data)
    result = {}
    if parts.get('portal') or parts.get('files'):
        key = data / f'dbus-1/services/{NAME}.service'
        result[key] = files[key]
    if parts.get('portal'):
        key = data / f'xdg-desktop-portal/portals/{PROVIDER}.portal'
        result[key] = files[key]
    if parts.get('files'):
        result.update({p: v for p, v in files.items() if p.suffix in ('.desktop', '.py')})
    if parts.get('settings'):
        result.update(settings_files())
    return result


def load_state():
    _, _, state = paths()
    if not state.exists():
        return {'version': 2, 'parts': {}, 'files': {}}
    saved = json.loads(state.read_text())
    if saved.get('version') != 2:
        # Earlier versions enabled the portal and Files together.
        saved.update(version=2, parts={'portal': True, 'files': True})
    allowed = {str(p) for p in required_files(dict.fromkeys(PARTS, True))}
    pending = saved.get('pending_files', {})
    if any(name not in allowed for name in set(saved['files']) | set(pending)):
        raise ValueError('Saved integration paths changed. Restore using the original location.')
    # Reconcile an interrupted write in memory. Only either exact journaled
    # version is owned; an external edit still fails the mutation preflight.
    for name, content in pending.items():
        path = Path(name)
        if matches(path, content) or name not in saved['files']:
            saved['files'][name] = content
    for part, enabled in saved.get('pending_parts', {}).items():
        if enabled:
            saved['parts'][part] = True
    return saved


def matches(path, content):
    return path.is_file() and not path.is_symlink() and path.read_text() == content


def status():
    config, _, _ = paths()
    saved = load_state()
    missing = dependencies()
    entries = {}
    for part in PARTS:
        expected = required_files({part: True})
        # Recorded contents may be from the previous plugin version.
        intact = all(matches(p, saved['files'].get(str(p), text)) for p, text in expected.items())
        enabled = intact
        if part == 'portal':
            enabled = enabled and config.exists() and preference(config.read_text()) == PROVIDER
        legacy = part == 'settings' and matches(next(iter(settings_files())), OVERRIDE)
        managed = bool(saved['parts'].get(part))
        label = ('Enabled' if enabled else 'Needs attention') if managed else ('Needs attention' if legacy else 'Not enabled')
        if part == 'settings' and (intact or legacy):
            launcher = next(iter(settings_files()))
            enabled = os.access(launcher, os.X_OK) and shutil.which('system-config-printer') == str(launcher)
            label = 'Enabled' if enabled else 'Log in again'
        entries[part] = {'enabled': bool(enabled), 'managed': managed or legacy, 'label': label}
    return {'integrations': entries, 'enabled': entries['portal']['enabled'],
            'managed': any(v['managed'] for v in entries.values()), 'missing': missing,
            'message': ''}


def update(part, enabling):
    # Multiple settings windows must not race their ownership records.
    _, _, state = paths()
    state.parent.mkdir(parents=True, exist_ok=True)
    with (state.parent / 'print-setup.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _update(part, enabling)


def _update(part, enabling):
    if part not in (*PARTS, 'all'):
        raise ValueError('Unknown integration.')
    config, _, state = paths()
    saved = load_state()
    targets = PARTS if part == 'all' else (part,)
    if part == 'all' and enabling and 'pending_parts' not in saved:
        current_status = status()
        targets = tuple(p for p in PARTS if not (current_status['integrations'][p]['managed']
                                                 or current_status['integrations'][p]['enabled']))
        if not targets:
            return current_status
    if enabling and any(p != 'settings' for p in targets):
        missing = dependencies()
        if missing:
            raise ValueError('Missing standard Omarchy components: ' + ', '.join(missing))
    # Adopt only the exact launcher previously created for this plugin.
    launcher = next(iter(settings_files()))
    if 'settings' in targets and matches(launcher, OVERRIDE) and not saved['parts'].get('settings'):
        saved['parts']['settings'] = True
        saved['files'][str(launcher)] = OVERRIDE
    old_parts = dict(saved['parts'])
    new_parts = dict(old_parts)
    for target in targets:
        new_parts[target] = enabling
    desired = required_files(new_parts)
    portal_changed = (bool(old_parts.get('portal')) != bool(new_parts.get('portal'))
                      or saved.get('pending_portal', False))
    if config.is_symlink() and (portal_changed or (enabling and 'portal' in targets)):
        raise ValueError('Portal configuration is a symlink; manage that file directly.')
    # Preflight every file before making any changes. Never replace unowned files.
    for path in set(desired) | {Path(name) for name in saved['files']}:
        recorded = saved['files'].get(str(path))
        if path.exists() or path.is_symlink():
            if recorded is None or not matches(path, recorded):
                raise ValueError('Integration file was created or edited elsewhere: ' + str(path))
    current = config.read_text() if config.exists() else None
    if new_parts.get('portal') and (portal_changed or (enabling and 'portal' in targets)):
        if old_parts.get('portal'):
            if current is not None and preference(current) not in (PROVIDER, saved.get('previous')):
                raise ValueError('The Print provider changed elsewhere. Restore before enabling again.')
        else:
            generic = config.with_name('portals.conf')
            system = Path('/usr/share/xdg-desktop-portal/hyprland-portals.conf')
            inherited = current if current is not None else (generic.read_text() if generic.exists() else system.read_text())
            saved.update(original=current, baseline=inherited, previous=preference(inherited))
    # Journal intended ownership before writes so interrupted setup remains restorable.
    saved.pop('restartFiles', None)
    old_files = dict(saved['files'])
    saved['pending_parts'] = new_parts
    saved['pending_files'] = {str(p): v for p, v in desired.items()}
    saved['pending_portal'] = portal_changed
    atomic(state, json.dumps(saved))
    for path, content in desired.items():
        if not matches(path, content):
            atomic(path, content)
        if path == launcher:
            path.chmod(0o755)
    if new_parts.get('portal') and (portal_changed or (enabling and 'portal' in targets)):
        atomic(config, set_preference(current if current is not None else saved['baseline'], PROVIDER))
    elif portal_changed and current is not None and preference(current) == PROVIDER:
        if saved.get('original') is None and current == set_preference(saved['baseline'], PROVIDER):
            config.unlink()
        else:
            atomic(config, set_preference(current, saved['previous']))
    for name in old_files:
        if Path(name) not in desired:
            Path(name).unlink(missing_ok=True)
            saved['files'].pop(name, None)
    saved['parts'] = new_parts
    saved['files'] = {str(p): v for p, v in desired.items()}
    for key in ('pending_files', 'pending_parts', 'pending_portal'):
        saved.pop(key, None)
    if any(new_parts.values()):
        atomic(state, json.dumps(saved))
    else:
        state.unlink(missing_ok=True)
    # Files and portal share D-Bus activation; Files alone never selects a Print provider.
    applied = True
    if any(t in ('portal', 'files') for t in targets):
        applied = reload_portal() if 'portal' in targets else reload_bus()
    messages = ['Integration enabled.' if enabling else 'Previous behavior restored.']
    if 'settings' in targets:
        messages.append('Log out and back in to apply the printer settings change.')
    if 'files' in targets and (enabling or old_parts.get('files')):
        restart_files_quietly()
    if not applied:
        messages.append('Log out and back in to activate the change.')
    return {**status(), 'message': ' '.join(messages),
            'notice': '' if applied else 'Log out and back in to activate this change.'}


def restart_files_quietly():
    # Integration is already saved. A failed restart must not undo it or interrupt the user.
    try:
        restart_files()
    except Exception:
        pass


def restart_files():
    import dbus
    bus = dbus.SessionBus()
    locations = []
    if not bus.name_has_owner('org.gnome.Nautilus'):
        return
    if bus.name_has_owner('org.gnome.Nautilus'):
        try:
            obj = bus.get_object('org.freedesktop.FileManager1', '/org/freedesktop/FileManager1')
            locations = list(dict.fromkeys(str(x) for x in dbus.Interface(
                obj, 'org.freedesktop.DBus.Properties').Get('org.freedesktop.FileManager1', 'OpenLocations', timeout=5)))
        except dbus.DBusException:
            raise ValueError('Could not read open folders. Files was left running; try again.')
        # A successful quit can return 255. Check the service, not the exit status.
        subprocess.run(['nautilus', '--quit'], capture_output=True, timeout=10, check=False)
        for _ in range(50):
            if not bus.name_has_owner('org.gnome.Nautilus'):
                break
            time.sleep(.1)
        else:
            raise ValueError('Files is still running. Finish any file operations and try again.')
    command = ['nautilus', '--', *locations] if locations else ['nautilus', '--gapplication-service']
    subprocess.Popen(command, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(50):
        if bus.name_has_owner('org.gnome.Nautilus'):
            return {**status(), 'message': ''}
        time.sleep(.1)
    raise ValueError('Files did not reopen. Open Files manually or try again.')


def reload_bus():
    result = subprocess.run(['dbus-send', '--session', '--type=method_call', '--dest=org.freedesktop.DBus',
                             '/org/freedesktop/DBus', 'org.freedesktop.DBus.ReloadConfig'],
                            capture_output=True, timeout=10)
    return result.returncode == 0


def enable():
    # Compatibility with the original combined setup command.
    update('portal', True)
    return update('files', True)


def restore():
    return update('all', False)


if __name__ == '__main__':
    try:
        action = sys.argv[1] if len(sys.argv) > 1 else 'status'
        if action in ('enable', 'restore') and len(sys.argv) > 2:
            result = update(sys.argv[2], action == 'enable')
        else:
            result = {'status': status, 'enable': enable, 'restore': restore}[action]()
        print(json.dumps({'ok': True, 'data': result}))
    except Exception as error:
        message = str(error)[:256] if isinstance(error, ValueError) else 'Could not update print integration.'
        print(json.dumps({'ok': False, 'error': message}))
        sys.exit(1)
