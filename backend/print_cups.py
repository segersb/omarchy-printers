"""Print-job capabilities and options (never changes printer defaults)."""
import os
import math
import re
from print_document import PT_PER_MM, adjustment


def connection():
    import cups
    cups.setPasswordCB(lambda _: '')
    return cups.Connection()


def capabilities():
    import cups
    from printers import validate_payload
    c = connection()
    queues = c.getPrinters()
    if len(queues) > 256:
        raise ValueError('Too many installed printers.')
    result = []
    for name in queues:
        a = c.getPrinterAttributes(name)
        media = []
        # PPD imageable areas are per-size and usable even when pycups cannot
        # decode IPP collections. No guessed borderless capability.
        path = None
        try:
            path = c.getPPD(name)
            ppd = cups.PPD(path)
            option = ppd.findOption('PageSize')
            for choice in (option.choices if option else []):
                dimensions = ppd.findAttr('PaperDimension', choice['choice'])
                imageable = ppd.findAttr('ImageableArea', choice['choice'])
                if not dimensions or not imageable:
                    continue
                w, h = map(float, dimensions.value.split())
                left, bottom, right, top = map(float, imageable.value.split())
                media.append({'value': choice['choice'], 'label': choice['text'],
                              'width': float(w), 'height': float(h),
                              'margins': [float(left), float(h-top), float(w-right), float(bottom)]})
            default = option.defchoice if option else ''
        except (RuntimeError, AttributeError, TypeError, ValueError, cups.IPPError):
            media = []
            default = a.get('media-default', '')
        finally:
            if path:
                os.unlink(path)
        if not media:
            default = a.get('media-default', '')
            margins = []
            for side in ('left', 'top', 'right', 'bottom'):
                values = a.get('media-' + side + '-margin-supported', [])
                if isinstance(values, int):
                    values = [values]
                # Conservative max: zero in a list doesn't establish that this
                # particular paper supports borderless printing.
                margins.append(max(values) / 100 * PT_PER_MM if values else None)
            if None not in margins:
                for key in a.get('media-supported', []):
                    match = re.search(r'_(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)(mm|in)$', key)
                    if match and not key.startswith(('custom_min_', 'custom_max_')):
                        factor = PT_PER_MM if match[3] == 'mm' else 72
                        media.append({'value': key, 'label': key.split('_')[1].upper(),
                                      'width': float(match[1])*factor, 'height': float(match[2])*factor,
                                      'margins': margins})
        media = [m for m in media if min(m['width'], m['height']) > 0
                 and min(m['margins']) >= -.1]
        for m in media:
            m['margins'] = [max(0, x) for x in m['margins']]
            if not any(m['margins']):
                m['label'] += ' · Borderless'
        colors = [x for x in a.get('print-color-mode-supported', ['monochrome'])
                  if x in ('color', 'monochrome', 'auto')]
        sides = [x for x in a.get('sides-supported', ['one-sided'])
                 if x in ('one-sided', 'two-sided-long-edge', 'two-sided-short-edge')]
        result.append({'value': name, 'label': name, 'media': media,
                       'defaultMedia': default, 'colors': colors or ['monochrome'],
                       'defaultColor': a.get('print-color-mode-default', 'monochrome'),
                       'sides': sides or ['one-sided'], 'defaultSides': a.get('sides-default', 'one-sided')})
    payload = {'queues': result, 'default': c.getDefault() or ''}
    validate_payload(payload)
    return payload


def validate_settings(settings, caps):
    queue = next((q for q in caps['queues'] if q['value'] == settings.get('queue')), None)
    if queue is None:
        raise ValueError('Select an installed printer.')
    media = next((m for m in queue['media'] if m['value'] == settings.get('media')), None)
    if media is None:
        raise ValueError('Select a supported paper size.')
    copies = int(settings.get('copies', 1))
    if not 1 <= copies <= 999:
        raise ValueError('Copies must be between 1 and 999.')
    color, sides = settings.get('color'), settings.get('sides')
    if color not in queue['colors'] or sides not in queue['sides']:
        raise ValueError('Unsupported color or two-sided setting.')
    orientation = settings.get('orientation', 'portrait')
    if orientation not in ('portrait', 'landscape'):
        raise ValueError('Invalid orientation.')
    paper = {k: media[k] for k in ('width', 'height', 'margins')}
    if orientation == 'landscape':
        paper['width'], paper['height'] = paper['height'], paper['width']
        l, t, r, b = paper['margins']
        paper['margins'] = [b, l, t, r]
    edits = settings.get('adjustments', {})
    if not isinstance(edits, dict) or len(edits) > 500:
        raise ValueError('Invalid page adjustments.')
    checked = {}
    for key, value in edits.items():
        if not isinstance(key, str) or not key.isdigit() or not 1 <= int(key) <= 500:
            raise ValueError('Invalid page number.')
        checked[str(int(key))] = adjustment(value)
    return {'queue': queue['value'], 'media': media['value'], 'copies': copies,
            'color': color, 'sides': sides, 'orientation': orientation, 'paper': paper,
            'adjustments': checked, 'defaultAdjustment': adjustment(settings.get('defaultAdjustment', {})),
            'pages': str(settings.get('pages', ''))[:4097]}


def portal_settings(settings, source_scale=None):
    # Preserve application layout scaling. The backend owns copies and page
    # selection; subsequent zoom and positioning operate on the rendered document.
    p = settings['paper']
    w, h = p['width'], p['height']
    margins = p['margins']
    if settings['orientation'] == 'landscape':
        w, h = h, w
        b, l, t, r = margins
        margins = [l, t, r, b]
    values = {'printer': settings['queue'], 'orientation': settings['orientation'],
              'n-copies': '1', 'print-pages': 'all', 'page-ranges': '',
              'number-up': '1', 'reverse': 'false', 'page-set': 'all',
              'use-color': 'true', 'duplex': 'simplex', 'resolution': '300',
              'paper-width': str(w / PT_PER_MM), 'paper-height': str(h / PT_PER_MM)}
    # An omitted hint must not overwrite the application's current scale either.
    try:
        scale = float(source_scale)
    except (TypeError, ValueError):
        scale = float('nan')
    if math.isfinite(scale) and 0 < scale <= 10000:
        values['scale'] = format(scale, 'g')
    setup = {'Width': w / PT_PER_MM, 'Height': h / PT_PER_MM,
             'Orientation': settings['orientation'], 'PPDName': settings['media'],
             'Name': settings['media'], 'DisplayName': settings['media']}
    setup.update({key: value / PT_PER_MM for key, value in zip(
        ('MarginLeft', 'MarginTop', 'MarginRight', 'MarginBottom'), margins)})
    return values, setup


def job_options(settings):
    return {'media': settings['media'], 'copies': str(settings['copies']),
            'print-color-mode': settings['color'], 'sides': settings['sides'],
            'print-scaling': 'none', 'fit-to-page': 'false', 'number-up': '1',
            'orientation-requested': '4' if settings['orientation'] == 'landscape' else '3'}
