"""Isolated real D-Bus + socket lifecycle test; CUPS submission is a test double."""
import concurrent.futures
import copy
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

import cairo
import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import print_portal as portal

DBusGMainLoop(set_as_default=True)
tmp = tempfile.TemporaryDirectory()
portal.RUNTIME = Path(tmp.name) / 'omarchy-print'
opened = queue.Queue()
submitted = []
caps = {'default': 'Test', 'queues': [{'value': 'Test', 'label': 'Test', 'media': [
    {'value': 'a4', 'label': 'A4', 'width': 595, 'height': 842, 'margins': [12]*4}],
    'defaultMedia': 'a4', 'colors': ['color'], 'defaultColor': 'color',
    'sides': ['one-sided'], 'defaultSides': 'one-sided'}]}
other = copy.deepcopy(caps['queues'][0])
other.update(value='Other', label='Other', defaultMedia='a5')
other['media'] = [{'value': 'a5', 'label': 'A5', 'width': 420, 'height': 595, 'margins': [8]*4}]
caps['queues'].append(other)
portal.capabilities = lambda: caps
portal.connection = lambda: SimpleNamespace(printFile=lambda *args: submitted.append(args) or 42)
portal.Backend.launch = lambda self, session: opened.put(session.id)
backend = portal.Backend(dbus.SessionBus())
loop = GLib.MainLoop()
errors = []
E = dbus.Dictionary({}, signature='sv')
source = Path(tmp.name) / 'source.pdf'
surface = cairo.PDFSurface(str(source), 300, 400)
ctx = cairo.Context(surface)
ctx.rectangle(100, 100, 100, 200)
ctx.fill()
surface.finish()


class Bridge:
    def __init__(self, sid):
        env = dict(os.environ, XDG_RUNTIME_DIR=tmp.name)
        self.proc = subprocess.Popen([sys.executable, portal.__file__, 'bridge', sid],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
    def sendall(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()
    def close(self):
        self.proc.stdin.close()
        assert self.proc.wait(timeout=5) == 0, 'UI bridge must exit cleanly'


def connect(sid):
    bridge = Bridge(sid)
    return bridge, bridge.proc.stdout


def send(sock, **message):
    sock.sendall(json.dumps(message).encode() + b'\n')


def until(stream, predicate):
    for _ in range(100):
        line = stream.readline()
        if not line:
            raise AssertionError('Unexpected disconnect')
        state = json.loads(line)
        if state.get('error'):
            raise AssertionError(state['error'])
        if predicate(state):
            return state
    raise AssertionError('Expected state not received')


def begin(method, *args, **kwargs):
    future = concurrent.futures.Future()
    method(*args, reply_handler=lambda *result: future.set_result(result),
           error_handler=future.set_exception, **kwargs)
    return future


def scenario():
    try:
        bus = dbus.SessionBus(private=True)
        name = dbus.service.BusName('org.freedesktop.portal.Desktop', bus)
        api = dbus.Interface(bus.get_object(portal.NAME, portal.OBJECT), portal.IFACE)
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            pending = begin(api.PreparePrint, '/org/test/prepare', 'test.app', '', 'Test drawing', dbus.Dictionary({'n-copies': '3', 'scale': '50'}, signature='sv'), E, E, timeout=30)
            sock, stream = connect(opened.get(timeout=10))
            first = until(stream, lambda s: s['stage'] == 'waiting')
            settings = dict(first['settings'])
            response, result = pending.result(timeout=20)
            assert response == 0 and result['settings']['n-copies'] == '1'
            assert result['settings']['scale'] == '50', 'preserve the application scale during automatic preparation'
            fd = os.open(source, os.O_RDONLY)
            pending = begin(api.Print, '/org/test/print', 'test.app', '', 'Test drawing',
                                  dbus.types.UnixFd(fd), {'token': result['token']}, timeout=30)
            os.close(fd)
            assert pending.result(timeout=20)[0] == 0, 'document handoff must finish before local confirmation'
            assert not submitted, 'accepting document bytes must never print'
            try:
                old_request = dbus.Interface(bus.get_object(portal.NAME, '/org/test/print', introspect=False),
                                             'org.freedesktop.impl.portal.Request')
                old_request.Close(timeout=5)
                raise AssertionError('Completed handoff request must be removed')
            except dbus.exceptions.DBusException as error:
                assert error.get_dbus_name() in ('org.freedesktop.DBus.Error.UnknownMethod',
                                                'org.freedesktop.DBus.Error.UnknownObject')
            state = until(stream, lambda s: s['stage'] == 'preview' and not s['busy'])
            assert state['metadata']['pages'][0]['scale'] == 1
            send(sock, action='render', settings=dict(settings, adjustments={'1': {'zoom': 250, 'x': 15, 'y': -20}}), revision=1)
            state = until(stream, lambda s: s.get('revision') == 1 and not s['busy'])
            assert state['metadata']['pages'][0]['cropped']
            assert state['metadata']['pages'][0]['scale'] == 2.5
            # Exercise the actual QML bridge while superseding in-flight zoom/pan renders.
            for revision in range(2, 32):
                send(sock, action='render', settings=dict(settings, adjustments={'1': {'zoom': 50 if revision % 2 == 0 else 200, 'x': revision, 'y': -revision}}), revision=revision)
            state = until(stream, lambda s: s.get('revision') == 31 and not s['busy'])
            assert state['stage'] == 'preview'
            for revision in range(32, 38):
                send(sock, action='render', settings=dict(settings, adjustments={'1': {'zoom': 50 if revision % 2 == 0 else 200, 'x': revision, 'y': -revision}}), revision=revision)
                state = until(stream, lambda s: s.get('revision') == revision and not s['busy'])
                assert state['stage'] == 'preview'
            # Printer, paper and orientation remain editable after app rendering.
            changed = dict(settings, queue='Other', media='a5', orientation='landscape')
            send(sock, action='render', settings=changed, revision=38)
            state = until(stream, lambda s: s.get('revision') == 38 and not s['busy'])
            assert state['metadata']['paper']['width'] == 595
            assert state['metadata']['paper']['height'] == 420
            send(sock, action='print', generation=state['generation'])
            send(sock, action='print', generation=state['generation'])
            until(stream, lambda s: s['stage'] == 'done')
            assert len(submitted) == 1
            assert submitted[0][0] == 'Other'
            assert submitted[0][3]['media'] == 'a5'
            assert submitted[0][3]['orientation-requested'] == '4'
            assert submitted[0][3]['copies'] == '3'
            assert submitted[0][3]['print-scaling'] == 'none'
            stream.close(); sock.close()
            # Single-use token cannot be replayed.
            with source.open('rb') as file:
                assert api.Print('/org/test/replay', 'test.app', '', '', dbus.types.UnixFd(file.fileno()),
                                 {'token': result['token']}, timeout=10)[0] == 2
            # No-token flow accepts a pipe and waits for final confirmation.
            readfd, writefd = os.pipe()
            pending = begin(api.Print, '/org/test/pipe', 'test.app', '', 'Pipe document',
                                  dbus.types.UnixFd(readfd), E, timeout=30)
            os.close(readfd)
            os.write(writefd, source.read_bytes()); os.close(writefd)
            sock, stream = connect(opened.get(timeout=10))
            until(stream, lambda s: s['stage'] == 'preview' and not s['busy'])
            send(sock, action='cancel')
            assert pending.result(timeout=10)[0] == 1
            stream.close(); sock.close()
            assert len(submitted) == 1
            # Independent no-token requests can still be cancelled via D-Bus.
            with source.open('rb') as file:
                a = begin(api.Print, '/org/test/a', 'test.app', '', 'A', dbus.types.UnixFd(file.fileno()), E, timeout=30)
            sid_a = opened.get(timeout=10)
            with source.open('rb') as file:
                b = begin(api.Print, '/org/test/b', 'test.app', '', 'B', dbus.types.UnixFd(file.fileno()), E, timeout=30)
            sid_b = opened.get(timeout=10)
            sa, fa = connect(sid_a); sb, fb = connect(sid_b)
            until(fa, lambda s: s['stage'] == 'preview' and not s['busy'])
            until(fb, lambda s: s['stage'] == 'preview' and not s['busy'])
            dbus.Interface(bus.get_object(portal.NAME, '/org/test/a'), 'org.freedesktop.impl.portal.Request').Close(timeout=10)
            assert a.result(timeout=10)[0] == 1
            assert not b.done()
            send(sb, action='cancel')
            assert b.result(timeout=10)[0] == 1
            fa.close(); sa.close(); fb.close(); sb.close()
        print('Portal lifecycle tests passed (one mocked submission, no physical jobs).')
    except BaseException as error:
        errors.append(error)
        import traceback
        traceback.print_exc()
    finally:
        GLib.idle_add(loop.quit)


thread = threading.Thread(target=scenario, daemon=True)
thread.start()
GLib.timeout_add_seconds(90, loop.quit)
loop.run()
backend.shutdown()
thread.join(timeout=2)
tmp.cleanup()
if errors or thread.is_alive():
    raise SystemExit(1)
