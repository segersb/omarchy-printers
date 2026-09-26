#!/usr/bin/env python3
"""User-session print portal and bounded JSON bridge for the QML dialog."""
import concurrent.futures
import json
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib, GLibUnix

from print_cups import capabilities, connection, job_options, portal_settings, validate_settings
from print_document import MAX_BYTES
from printers import validate_payload

NAME = 'org.freedesktop.impl.portal.desktop.omarchy-printers'
IFACE = 'org.freedesktop.impl.portal.Print'
OBJECT = '/org/freedesktop/portal/desktop'
ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid()))) / 'omarchy-print'
MAX_REQUESTS = 8
TTL = 15 * 60


def worker(request):
    proc = subprocess.run([sys.executable, str(ROOT / 'backend/print_document.py')],
                          input=json.dumps(request), text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=130)
    try:
        result = json.loads(proc.stdout)
    except ValueError:
        raise ValueError('Document processing failed or exceeded its resource limit.') from None
    if not result.get('ok'):
        raise ValueError(result.get('error', 'Could not process document.'))
    return result['data']


def receive_file(fd, path, cancelled):
    """Read regular files and pipe-backed portal documents without blocking GLib."""
    total = 0
    deadline = time.monotonic() + 120
    try:
        os.set_blocking(fd, False)
        with open(path, 'xb') as out:
            while not cancelled.is_set():
                if time.monotonic() > deadline:
                    raise ValueError('The application did not finish sending the document.')
                readable, _, _ = select.select([fd], [], [], .25)
                if not readable:
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    return
                total += len(chunk)
                if total > MAX_BYTES:
                    raise ValueError('Document exceeds 128 MiB.')
                out.write(chunk)
        raise ValueError('Request cancelled.')
    finally:
        os.close(fd)


class Request(dbus.service.Object):
    def __init__(self, backend, handle, callback, session):
        super().__init__(backend.bus, handle)
        self.backend, self.callback, self.session = backend, callback, session
        self.done = False

    @dbus.service.method('org.freedesktop.impl.portal.Request', in_signature='', out_signature='', sender_keyword='sender')
    def Close(self, sender=None):
        self.backend.authorize(sender)
        self.backend.finish(self.session, 1, "The application cancelled this print request.",
                            reason="application-cancelled")

    def reply(self, response, results=None):
        if self.done:
            return
        self.done = True
        self.remove_from_connection()
        self.callback(dbus.UInt32(response), dbus.Dictionary(results or {}, signature='sv'))


class Session:
    def __init__(self, app, title):
        self.id = secrets.token_hex(24)
        self.app = str(app)
        self.title = str(title)[:256]
        self.directory = Path(tempfile.mkdtemp(prefix='job-', dir=RUNTIME))
        self.request = None
        self.socket = None
        self.cancelled = threading.Event()
        self.stage = 'loading'
        self.settings = {}
        self.source_scale = None
        self.caps = None
        self.source = self.directory / 'source.pdf'
        self.output = None
        self.metadata = None
        self.generation = 0
        self.rendering = False
        self.pending = None
        self.deadline = time.monotonic() + TTL
        self.token = None
        self.direct = False
        self.closed = False
        self.workers = 0
        self.last = {'stage': 'loading', 'title': self.title}


class Backend(dbus.service.Object):
    def __init__(self, bus):
        self.bus = bus
        self.name = dbus.service.BusName(NAME, bus=bus, do_not_queue=True)
        super().__init__(bus, OBJECT)
        self.sessions = {}
        self.tokens = {}
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=4)
        RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
        if RUNTIME.stat().st_uid != os.getuid() or RUNTIME.is_symlink():
            raise RuntimeError('Unsafe runtime directory')
        RUNTIME.chmod(0o700)
        # Acquiring the bus name above guarantees no other live backend owns these.
        for stale in RUNTIME.glob('job-*'):
            if stale.is_dir() and not stale.is_symlink() and stale.stat().st_uid == os.getuid():
                shutil.rmtree(stale, ignore_errors=True)
        self.listener = socket.socket(socket.AF_UNIX)
        self.socket_path = RUNTIME / 'control.sock'
        self.socket_path.unlink(missing_ok=True)
        self.listener.bind(str(self.socket_path))
        self.listener.listen(8)
        threading.Thread(target=self.accept, daemon=True).start()
        GLib.timeout_add_seconds(30, self.expire)

    def authorize(self, sender):
        if sender != str(self.bus.get_name_owner('org.freedesktop.portal.Desktop')):
            raise dbus.exceptions.DBusException('Only the desktop portal may call this interface.')

    def new(self, app, title):
        if len(self.sessions) >= MAX_REQUESTS:
            raise ValueError('Too many print dialogs are open.')
        s = Session(app, title)
        self.sessions[s.id] = s
        self.launch(s)
        return s

    def launch(self, s):
        def run():
            result = subprocess.run(['omarchy-shell', 'shell', 'summon', 'segersb.omarchy-printers',
                                     json.dumps({'printRequest': s.id})], capture_output=True, timeout=10)
            if result.returncode:
                raise ValueError('Could not open the Omarchy print dialog.')
        self.work(s, run, lambda _: None)
        GLib.timeout_add_seconds(20, self.check_ui, s)

    def check_ui(self, s):
        if not s.closed and s.socket is None:
            self.finish(s, 2, "Could not connect to the print dialog.", reason="ui-connect-timeout")
        return False

    def work(self, s, function, success):
        s.workers += 1
        future = self.pool.submit(function)
        def done(f):
            GLib.idle_add(deliver, f)
        def deliver(f):
            s.workers -= 1
            if s.closed:
                if not s.workers:
                    shutil.rmtree(s.directory, ignore_errors=True)
                return False
            try:
                value = f.result()
            except Exception as error:
                message = str(error)[:256] if isinstance(error, ValueError) else 'The print operation failed.'
                s.rendering = False
                if s.pending and s.stage == 'preview':
                    self.render_next(s)
                    return False
                self.emit(s, error=message, busy=False)
                # A submission failure is ambiguous: never offer an automatic retry.
                if s.stage == 'submitting':
                    self.finish(s, 2, 'Could not confirm submission. Check printer jobs before printing again.')
                elif s.stage in ('loading', 'receiving'):
                    self.finish(s, 2, message)
                return False
            try:
                success(value)
            except Exception:
                self.finish(s, 2, 'Could not prepare this print request.')
            return False
        future.add_done_callback(done)

    def emit(self, s, **values):
        if s.closed:
            return
        s.last.update(values)
        s.last['stage'] = s.stage
        s.last['title'] = s.title
        validate_payload(s.last)
        if s.socket:
            try:
                s.socket.sendall(json.dumps(s.last).encode() + b'\n')
            except OSError:
                s.socket = None
                self.finish(s, 1, reason="ui-write-failed")

    def initialize(self, s, hints=None, page_setup=None):
        def loaded(caps):
            s.caps = caps
            hints_ = hints or {}
            s.source_scale = hints_.get("scale")
            queue = next((q for q in caps['queues'] if q['value'] == hints_.get('printer')), None)
            queue = queue or next((q for q in caps['queues'] if q['value'] == caps['default']), None)
            queue = queue or (caps['queues'][0] if caps['queues'] else None)
            if queue:
                page = page_setup or {}
                media = next((m for m in queue['media'] if m['value'] in (hints_.get('paper-format'), page.get('PPDName'))), None)
                if media is None and page.get('Width') and page.get('Height'):
                    media = next((m for m in queue['media'] if abs(m['width'] * 25.4 / 72 - float(page['Width'])) < 1
                                  and abs(m['height'] * 25.4 / 72 - float(page['Height'])) < 1), None)
                media = media or next((m for m in queue['media'] if m['value'] == queue['defaultMedia']), None)
                media = media or (queue['media'][0] if queue['media'] else None)
                s.settings = {'queue': queue['value'], 'media': media['value'] if media else '',
                              'orientation': 'landscape' if hints_.get('orientation', page.get('Orientation')) in ('landscape', 'reverse_landscape', 'reverse-landscape') else 'portrait',
                              'copies': min(999, max(1, int(hints_.get('n-copies', 1)))),
                              'color': queue['defaultColor'] if queue['defaultColor'] in queue['colors'] else queue['colors'][0],
                              'sides': queue['defaultSides'] if queue['defaultSides'] in queue['sides'] else queue['sides'][0],
                              'adjustments': {}, 'defaultAdjustment': {'zoom': 100, 'x': 0, 'y': 0}, 'pages': ''}
                color = {'true': 'color', 'false': 'monochrome'}.get(str(hints_.get('use-color', '')))
                sides = {'simplex': 'one-sided', 'vertical': 'two-sided-long-edge',
                         'horizontal': 'two-sided-short-edge'}.get(str(hints_.get('duplex', '')))
                if color in queue['colors']:
                    s.settings['color'] = color
                if sides in queue['sides']:
                    s.settings['sides'] = sides
            if not queue or not queue['media']:
                self.finish(s, 2, 'No supported paper sizes are available. Check your printer setup.')
                return
            self.emit(s, caps=caps, settings=s.settings, direct=s.direct)
            if s.direct:
                self.render(s, s.settings)
            else:
                self.prepare(s)
        self.work(s, capabilities, loaded)

    def prepare(self, s):
        # Resolve the application's page setup automatically. The user confirms
        # only after the rendered document arrives, in the editable preview.
        s.settings = validate_settings(s.settings, s.caps)
        values, setup = portal_settings(s.settings, s.source_scale)
        token = secrets.randbelow(2**32 - 1) + 1
        while token in self.tokens:
            token = secrets.randbelow(2**32 - 1) + 1
        self.tokens[token] = s
        s.token = token
        s.stage = 'waiting'
        self.emit(s, settings=s.settings, busy=True, error='')
        request, s.request = s.request, None
        request.reply(0, {'settings': dbus.Dictionary(values, signature='sv'),
                          'page-setup': dbus.Dictionary(setup, signature='sv'),
                          'token': dbus.UInt32(token)})

    @dbus.service.method(IFACE, in_signature='osssa{sv}a{sv}a{sv}', out_signature='ua{sv}',
                         async_callbacks=('reply', 'error'), sender_keyword='sender')
    def PreparePrint(self, handle, app_id, parent_window, title, settings, page_setup, options,
                     reply, error, sender=None):
        self.authorize(sender)
        try:
            s = self.new(app_id, title)
            s.request = Request(self, handle, reply, s)
            self.initialize(s, settings, page_setup)
        except ValueError:
            reply(2, dbus.Dictionary({}, signature='sv'))

    @dbus.service.method(IFACE, in_signature='osssha{sv}', out_signature='ua{sv}',
                         async_callbacks=('reply', 'error'), sender_keyword='sender')
    def Print(self, handle, app_id, parent_window, title, fd, options, reply, error, sender=None):
        self.authorize(sender)
        token = int(options.get('token', 0))
        if token:
            s = self.tokens.get(token)
            if not s or s.app != str(app_id) or s.closed or time.monotonic() > s.deadline:
                reply(2, dbus.Dictionary({}, signature='sv'))
                return
            self.tokens.pop(token)
            s.token = None
        else:
            try:
                s = self.new(app_id, title)
            except ValueError:
                reply(2, dbus.Dictionary({}, signature='sv'))
                return
            s.direct = True  # no PreparePrint: document is available immediately
        s.request = Request(self, handle, reply, s)
        s.stage = 'receiving'
        self.emit(s, busy=True, error='')
        owned_fd = fd.take()
        def received(_):
            if not s.direct and s.request:
                # Token-bearing calls deliver an already prepared document.
                # Acknowledge the completed handoff rather than retaining the
                # application's request throughout our local editing dialog.
                # This does not submit to CUPS: only the UI's Print action does.
                request, s.request = s.request, None
                request.reply(0)
            if s.caps:
                self.render(s, s.settings)
            else:
                self.initialize(s)
        self.work(s, lambda: receive_file(owned_fd, s.source, s.cancelled), received)

    @dbus.service.method('org.omarchy.Printers', in_signature='s', out_signature='s', sender_keyword='sender')
    def OpenImage(self, filename, sender=None):
        if int(self.bus.get_unix_user(sender)) != os.getuid():
            raise dbus.exceptions.DBusException('Access denied')
        path = Path(str(filename)).resolve(strict=True)
        if not path.is_file() or path.stat().st_size > MAX_BYTES:
            raise dbus.exceptions.DBusException('Image is too large or not a regular file.')
        s = self.new('local-image', path.name)
        s.direct = True
        self.work(s, lambda: worker({'action': 'image', 'source': str(path), 'output': str(s.source)}),
                  lambda _: self.initialize(s))
        return s.id

    def accept(self):
        while True:
            try:
                peer, _ = self.listener.accept()
            except OSError:
                return
            uid = struct.unpack('3i', peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
            if uid != os.getuid():
                peer.close()
                continue
            peer.settimeout(2)
            threading.Thread(target=self.read_peer, args=(peer,), daemon=True).start()

    def read_peer(self, peer):
        sid = None
        try:
            stream = peer.makefile('rb')
            line = stream.readline(65537)
            hello = json.loads(line)
            sid = hello['request']
            if not re.fullmatch('[0-9a-f]{48}', sid):
                return
            peer.settimeout(None)
            peer.setsockopt(socket.SOL_SOCKET, socket.SO_SNDTIMEO, struct.pack('ll', 1, 0))
            GLib.idle_add(self.attach, sid, peer)
            for line in iter(lambda: stream.readline(65537), b''):
                if len(line) > 65536:
                    break
                message = json.loads(line)
                GLib.idle_add(self.command, sid, message)
        except (OSError, ValueError, KeyError, TypeError):
            pass
        finally:
            GLib.idle_add(self.disconnected, sid, peer)

    def attach(self, sid, peer):
        s = self.sessions.get(sid)
        if not s or s.socket:
            peer.close()
            return False
        s.socket = peer
        self.emit(s)
        return False

    def disconnected(self, sid, peer):
        s = self.sessions.get(sid)
        if s and s.socket is peer:
            self.finish(s, 1, reason="ui-disconnected")
        peer.close()
        return False

    def command(self, sid, message):
        s = self.sessions.get(sid)
        if not s or s.closed or not isinstance(message, dict):
            return False
        action = message.get('action')
        if action == 'cancel' and s.stage != 'submitting':
            self.finish(s, 1, reason='user-cancelled')
            return False
        try:
            if action == 'render' and s.stage == 'preview' and s.source.exists():
                self.render(s, message['settings'], int(message.get('revision', 0)), int(message.get('viewSource', 1)))
            elif action == 'page' and s.stage == 'preview' and not s.rendering and not s.pending and s.output:
                index = int(message['page'])
                if not 0 <= index < len(s.metadata['pages']):
                    raise ValueError('Invalid page.')
                generation = s.generation
                image = s.directory / f'preview-{generation}-{index}.png'
                source_image = s.directory / f'original-{generation}-{index}.png'
                output = str(s.output)
                source_page = s.metadata['pages'][index]['source'] - 1
                self.emit(s, busy=True)
                def shown(_):
                    if generation == s.generation:
                        self.emit(s, image=image.as_uri(), sourceImage=source_image.as_uri(), page=index, busy=False)
                self.work(s, lambda: worker({'action': 'page', 'source': output, 'image': str(image), 'page': index,
                                            'original': str(s.source), 'sourceImage': str(source_image), 'sourcePage': source_page}), shown)
            elif action == 'print' and s.stage == 'preview' and s.output and not s.rendering and not s.pending:
                # The UI supplies the displayed generation; stale output cannot print.
                if int(message.get('generation', -1)) != s.generation:
                    raise ValueError('Wait for the current preview before printing.')
                s.stage = 'submitting'
                self.emit(s, busy=True, error='')
                self.work(s, lambda: connection().printFile(s.settings['queue'], str(s.output),
                          s.title, job_options(s.settings)),
                          lambda job: self.finish(s, 0, f'Sent to printer · Job {job}'))
        except (ValueError, KeyError, TypeError):
            self.emit(s, error='Check the printer, paper, copies and page selection.', busy=False)
        return False

    def render(self, s, proposed, revision=0, view_source=1):
        settings = validate_settings(proposed, s.caps)
        s.generation += 1
        s.pending = (s.generation, settings, revision, view_source)
        s.output = None
        s.stage = 'preview'
        self.emit(s, busy=True, error='', settings=settings, revision=revision)
        if not s.rendering:
            self.render_next(s)

    def render_next(self, s):
        generation, settings, revision, view_source = s.pending
        s.pending = None
        s.rendering = True
        output = s.directory / f'output-{generation}.pdf'
        image = s.directory / f'preview-{generation}-render.png'
        source_image = s.directory / f'original-{generation}-render.png'
        def rendered(metadata):
            s.rendering = False
            if s.pending:
                output.unlink(missing_ok=True)
                image.unlink(missing_ok=True)
                source_image.unlink(missing_ok=True)
                self.render_next(s)
                return
            s.settings, s.output, s.metadata = settings, output, metadata
            # Keep only the current output/preview set; source is retained.
            for pattern in ('output-*.pdf', 'preview-*.png', 'original-*.png'):
                for old in s.directory.glob(pattern):
                    if old not in (output, image, source_image):
                        old.unlink(missing_ok=True)
            self.emit(s, metadata=metadata, image=image.as_uri(), sourceImage=source_image.as_uri(), page=metadata['viewPage'],
                      generation=generation, revision=revision, settings=settings, busy=False, error='')
        self.work(s, lambda: worker({'action': 'render', 'source': str(s.source), 'output': str(output),
                                     'image': str(image), 'sourceImage': str(source_image), 'viewSource': view_source, 'settings': settings}), rendered)

    def finish(self, s, response, message='', reason='completed'):
        if s.closed:
            return
        print(f'print request {s.id[:8]}: {s.stage} -> done ({reason}, response={response})', file=sys.stderr, flush=True)
        s.stage = 'done'
        self.emit(s, message=message, response=response, busy=False)
        s.closed = True
        s.cancelled.set()
        if s.request:
            s.request.reply(response)
        if s.token:
            self.tokens.pop(s.token, None)
        self.sessions.pop(s.id, None)
        if s.socket:
            try:
                s.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.socket.close()
        if not s.workers:
            shutil.rmtree(s.directory, ignore_errors=True)

    def expire(self):
        for s in list(self.sessions.values()):
            if time.monotonic() > s.deadline and s.stage != 'submitting':
                self.finish(s, 1, 'Print request expired.', reason='expired')
        return True

    def shutdown(self):
        for s in list(self.sessions.values()):
            self.finish(s, 1, "The print service stopped.", reason="shutdown")
        self.listener.close()
        self.socket_path.unlink(missing_ok=True)
        self.pool.shutdown(wait=False, cancel_futures=True)


def bridge(sid):
    # One event loop owns both streams. A daemon thread reading buffered stdin
    # can abort Python during interpreter shutdown when the peer disconnects.
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(str(RUNTIME / 'control.sock'))
        sock.sendall(json.dumps({'request': sid}).encode() + b'\n')
        pending = b''
        while True:
            readable, _, _ = select.select([sock, sys.stdin.fileno()], [], [])
            if sock in readable:
                data = sock.recv(65536)
                if not data:
                    return
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if sys.stdin.fileno() in readable:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    return
                pending += data
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if len(line) > 65536:
                        return
                    sock.sendall(line + b'\n')
                if len(pending) > 65536:
                    return


def main():
    os.umask(0o077)
    if len(sys.argv) > 1 and sys.argv[1] == 'bridge':
        bridge(sys.argv[2])
        return
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    if len(sys.argv) > 1 and sys.argv[1] == 'image':
        if len(sys.argv) != 3:
            raise SystemExit('Choose one PNG or JPEG image to print.')
        proxy = bus.get_object(NAME, OBJECT)
        dbus.Interface(proxy, 'org.omarchy.Printers').OpenImage(str(Path(sys.argv[2]).resolve()), timeout=10)
        return
    backend = Backend(bus)
    loop = GLib.MainLoop()
    def stop(*_):
        backend.shutdown()
        loop.quit()
        return False
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, stop)
    try:
        loop.run()
    finally:
        backend.shutdown()


if __name__ == '__main__':
    main()
