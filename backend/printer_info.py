#!/usr/bin/env python3
"""Read optional printer details without blocking queue/settings operations."""
import json
import resource
import subprocess
import sys
from urllib.parse import unquote, urlsplit, urlunsplit

from printers import BackendError, MAX_RESPONSE_BYTES, validate_payload

ATTRIBUTES = [
    'printer-make-and-model', 'printer-info', 'printer-location',
    'printer-uuid', 'printer-state-message', 'printer-state-reasons',
    'marker-names', 'marker-types', 'marker-levels', 'marker-colors',
    'printer-alert-description', 'color-supported', 'sides-supported',
    'printer-resolution-supported', 'document-format-supported',
]


TEXT_FIELDS = {'printer-make-and-model', 'printer-info', 'printer-location',
               'printer-uuid', 'printer-state-message', 'address', 'connection'}
LIST_FIELDS = {'printer-state-reasons', 'marker-names', 'marker-types', 'marker-colors',
               'printer-alert-description', 'sides-supported', 'document-format-supported'}


def validated_attributes(attrs):
    """Bound external data first, then normalize only fields understood by QML."""
    validate_payload(attrs)
    if not isinstance(attrs, dict):
        raise ValueError('Invalid printer attributes.')
    result = {}
    for key, value in attrs.items():
        if key in TEXT_FIELDS:
            if isinstance(value, str) and not value.startswith('(unknown IPP value tag'):
                result[key] = value
        elif key in LIST_FIELDS:
            values = [value] if isinstance(value, str) else value
            if isinstance(values, (list, tuple)):
                # Preserve indexes so a missing supply name cannot shift levels/colors.
                result[key] = [item if isinstance(item, str) and not item.startswith(
                    '(unknown IPP value tag') else '' for item in values]
        elif key == 'marker-levels':
            values = [value] if type(value) is int else value
            if isinstance(values, (list, tuple)):
                result[key] = [item if type(item) is int and -3 <= item <= 100 else -2
                               for item in values]
        elif key == 'color-supported' and type(value) is bool:
            result[key] = value
        elif key == 'printer-resolution-supported' and isinstance(value, (list, tuple)):
            values = [value] if len(value) == 3 and all(type(n) is int for n in value) else value
            result[key] = [list(item) for item in values
                           if isinstance(item, (list, tuple)) and len(item) == 3
                           and all(type(n) is int for n in item)
                           and 0 < item[0] <= 100000 and 0 < item[1] <= 100000
                           and item[2] in (3, 4)]
    validate_payload(result)
    return result


def device_attributes(uri):
    import cups
    validate_payload(uri)
    parsed = urlsplit(uri)
    if parsed.scheme not in ('ipp', 'ipps') or parsed.username or parsed.password:
        return {}
    host = unquote(parsed.hostname or '')
    port = parsed.port or 631
    path = parsed.path or '/ipp/print'
    for service_type in ('_ipps._tcp', '_ipp._tcp'):
        marker = '.' + service_type + '.'
        if marker in host:
            import dbus
            name, domain = host.split(marker, 1)
            bus = dbus.SystemBus()
            avahi = dbus.Interface(bus.get_object('org.freedesktop.Avahi', '/'),
                                   'org.freedesktop.Avahi.Server')
            resolved = avahi.ResolveService(-1, -1, name, service_type, domain, -1, 0, timeout=3)
            host, port = str(resolved[5]), int(resolved[8])
            for item in resolved[9]:
                text = bytes(item).decode('utf-8', errors='replace')
                if text.startswith('rp='):
                    path = '/' + text[3:].lstrip('/')
            break
    authority = ('[' + host + ']' if ':' in host else host) + ':' + str(port)
    uri = urlunsplit((parsed.scheme, authority, path, '', ''))
    connection = cups.Connection(host=host, port=port, encryption=(
        cups.HTTP_ENCRYPT_ALWAYS if parsed.scheme == 'ipps' else cups.HTTP_ENCRYPT_IF_REQUESTED))
    attrs = connection.getPrinterAttributes(uri=uri, requested_attributes=ATTRIBUTES)
    attrs = validated_attributes(attrs)
    attrs["address"] = host
    return validated_attributes(attrs)


def collect(queue):
    import cups
    connection = cups.Connection()
    attrs = connection.getPrinterAttributes(queue)
    uri = connection.getPrinters().get(queue, {}).get('device-uri', '')
    details = validated_attributes(attrs)
    validate_payload(uri)
    # Network reads run in a bounded subprocess; offline devices still show local details.
    try:
        result = subprocess.run([sys.executable, __file__, '--device', uri],
                                capture_output=True, timeout=6, check=True)
        if len(result.stdout) > MAX_RESPONSE_BYTES:
            raise ValueError("Printer response is too large.")
        details.update(validated_attributes(json.loads(result.stdout)))
    except (subprocess.SubprocessError, ValueError, BackendError):
        pass
    parsed = urlsplit(uri)
    host = unquote(parsed.hostname or '')
    details['connection'] = {'ipps': 'Secure IPP', 'ipp': 'IPP', 'usb': 'USB',
                             'socket': 'AppSocket', 'lpd': 'LPD', 'dnssd': 'DNS-SD'}.get(parsed.scheme, parsed.scheme)
    details.setdefault('address', host)
    return validated_attributes(details)


if __name__ == '__main__':
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024**2, 512 * 1024**2))
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
    try:
        data = device_attributes(sys.argv[2]) if sys.argv[1] == '--device' else collect(sys.argv[1])
        validate_payload(data)
        print(json.dumps(data))
    except Exception:
        print('{}')
        sys.exit(1)
