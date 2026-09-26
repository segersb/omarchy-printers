"""Bounded PDF worker using Omarchy's Poppler and Cairo; no pip dependencies."""
import json
import math
import os
from pathlib import Path
import re
import resource
import sys

MAX_BYTES = 128 * 1024 * 1024
MAX_PAGES = 500
PT_PER_MM = 72 / 25.4


def libraries():
    import gi
    import cairo
    gi.require_version('Poppler', '0.18')
    gi.require_foreign('cairo')
    from gi.repository import Poppler
    return cairo, Poppler


def open_pdf(path):
    _, Poppler = libraries()
    path = Path(path).resolve()
    if path.stat().st_size > MAX_BYTES:
        raise ValueError('Document exceeds 128 MiB.')
    with path.open('rb') as f:
        if not f.read(1024).lstrip().startswith(b'%PDF-'):
            raise ValueError('This dialog currently accepts PDF documents only.')
    doc = Poppler.Document.new_from_file(path.as_uri(), None)
    if not 0 < doc.get_n_pages() <= MAX_PAGES:
        raise ValueError('Documents must contain 1–500 pages.')
    if not doc.get_permissions() & Poppler.Permissions.OK_TO_PRINT:
        raise ValueError('This PDF does not allow printing.')
    return doc


def page_size(page):
    w, h = page.get_size()
    if not all(math.isfinite(x) and 0 < x <= 14400 for x in (w, h)):
        raise ValueError('Unsupported page dimensions.')
    return w, h


def selected_pages(text, count):
    if not text.strip():
        return list(range(count))
    if len(text) > 4096 or not re.fullmatch(r'[0-9,\s-]+', text):
        raise ValueError('Use page numbers such as 1–3, 5 (with a hyphen).')
    result = set()
    for part in text.split(','):
        bits = part.strip().split('-')
        if len(bits) > 2 or any(not b.strip().isdigit() for b in bits):
            raise ValueError('Use page numbers such as 1-3, 5.')
        first, last = int(bits[0]), int(bits[-1])
        if not 1 <= first <= last <= count:
            raise ValueError('Page range is outside the document.')
        result.update(range(first - 1, last))
    return sorted(result)


def adjustment(value):
    if not isinstance(value, dict):
        raise ValueError('Invalid page adjustment.')
    zoom = float(value.get('zoom', 100))
    x, y = float(value.get('x', 0)), float(value.get('y', 0))
    if not all(math.isfinite(n) for n in (zoom, x, y)) or not 10 <= zoom <= 400:
        raise ValueError('Zoom must be between 10% and 400%.')
    if abs(x) > 14400 or abs(y) > 14400:
        raise ValueError('Page position is outside the supported range.')
    return {'zoom': zoom, 'x': x, 'y': y}


def placement(w, h, paper, edit):
    edit = adjustment(edit)
    pw, ph = paper['width'], paper['height']
    left, top, right, bottom = paper['margins']
    scale = edit['zoom'] / 100
    x = (pw - w * scale) / 2 + edit['x']
    y = (ph - h * scale) / 2 + edit['y']
    return {'scale': scale, 'x': x, 'y': y,
            'clip': [left, top, pw - left - right, ph - top - bottom],
            'cropped': x < left - .01 or y < top - .01 or
                       x + w * scale > pw - right + .01 or y + h * scale > ph - bottom + .01}


def transform(source, destination, settings):
    cairo, _ = libraries()
    doc = open_pdf(source)
    indices = selected_pages(settings.get('pages', ''), doc.get_n_pages())
    paper = settings['paper']
    surface = cairo.PDFSurface(str(destination), paper['width'], paper['height'])
    pages = []
    try:
        for index in indices:
            page = doc.get_page(index)
            w, h = page_size(page)
            edit = settings.get('adjustments', {}).get(str(index + 1), settings.get('defaultAdjustment', {}))
            layout = placement(w, h, paper, edit)
            ctx = cairo.Context(surface)
            ctx.rectangle(*layout['clip'])
            ctx.clip()
            ctx.translate(layout['x'], layout['y'])
            ctx.scale(layout['scale'], layout['scale'])
            page.render_for_printing(ctx)
            ctx.show_page()
            pages.append({'source': index + 1, 'width': w, 'height': h,
                          'scale': layout['scale'], 'cropped': layout['cropped']})
    finally:
        surface.finish()
    return {'pages': pages, 'count': doc.get_n_pages(), 'paper': paper}


def preview(source, destination, index=0):
    cairo, _ = libraries()
    doc = open_pdf(source)
    if not 0 <= index < doc.get_n_pages():
        raise ValueError('Page is outside the document.')
    page = doc.get_page(index)
    w, h = page_size(page)
    scale = min(2, 1400 / max(w, h))
    surface = cairo.ImageSurface(cairo.FORMAT_RGB24, math.ceil(w * scale), math.ceil(h * scale))
    ctx = cairo.Context(surface)
    ctx.set_source_rgb(1, 1, 1)
    ctx.paint()
    ctx.scale(scale, scale)
    page.render_for_printing(ctx)
    surface.write_to_png(str(destination))


def image_pdf(source, output):
    import gi
    gi.require_version('GdkPixbuf', '2.0')
    gi.require_version('Gdk', '3.0')
    from gi.repository import GdkPixbuf, Gdk
    cairo, _ = libraries()
    info = GdkPixbuf.Pixbuf.get_file_info(str(source))
    if not info or not info[0] or info[0].get_name() not in ('png', 'jpeg'):
        raise ValueError('Choose a PNG or JPEG image.')
    if info[1] * info[2] > 40_000_000 or max(info[1], info[2]) > 20000:
        raise ValueError('Image exceeds 40 megapixels or 20,000 pixels per side.')
    if Path(source).stat().st_size > MAX_BYTES:
        raise ValueError('Image exceeds 128 MiB.')
    pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(source)).apply_embedded_orientation()
    try:
        dpi = float(pixbuf.get_option('x-dpi') or 96)
    except ValueError:
        dpi = 96
    if not math.isfinite(dpi) or not 36 <= dpi <= 2400:
        dpi = 96
    scale = 72 / dpi
    surface = cairo.PDFSurface(str(output), pixbuf.get_width() * scale, pixbuf.get_height() * scale)
    ctx = cairo.Context(surface)
    ctx.scale(scale, scale)
    Gdk.cairo_set_source_pixbuf(ctx, pixbuf, 0, 0)
    ctx.paint()
    surface.finish()
    return {'dpi': dpi}


def main():
    # Worker resource limits also cover malformed PDFs; parent enforces wall time.
    resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024**2, 1536 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024**2, 256 * 1024**2))
    os.umask(0o077)
    try:
        request = json.loads(sys.stdin.buffer.read(65537))
        if request['action'] == 'image':
            result = image_pdf(request['source'], request['output'])
        elif request['action'] == 'render':
            result = transform(request['source'], request['output'], request['settings'])
            view = next((i for i, page in enumerate(result['pages'])
                         if page['source'] == request.get('viewSource')), 0)
            result['viewPage'] = view
            preview(request['output'], request['image'], view)
            if request.get('sourceImage'):
                preview(request['source'], request['sourceImage'], result['pages'][view]['source'] - 1)
        elif request['action'] == 'page':
            preview(request['source'], request['image'], int(request['page']))
            if request.get('sourceImage'):
                preview(request['original'], request['sourceImage'], int(request['sourcePage']))
            result = {}
        else:
            raise ValueError('Unknown document operation.')
        print(json.dumps({'ok': True, 'data': result}))
    except Exception as error:
        message = str(error) if isinstance(error, ValueError) else 'Could not process this PDF.'
        print(json.dumps({'ok': False, 'error': message[:256]}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
