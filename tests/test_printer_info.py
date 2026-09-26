import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'backend'))

spec = importlib.util.spec_from_file_location('printer_info', Path(__file__).parents[1] / 'backend/printer_info.py')
info = importlib.util.module_from_spec(spec)
spec.loader.exec_module(info)


class PrinterInfoTests(unittest.TestCase):
    def test_offline_printer_keeps_local_details(self):
        connection = Mock()
        connection.getPrinterAttributes.return_value = {'printer-make-and-model': 'Office printer'}
        connection.getPrinters.return_value = {'Office': {'device-uri': 'ipps://office.local/ipp/print'}}
        with patch.dict('sys.modules', {'cups': Mock(Connection=Mock(return_value=connection))}), patch.object(info.subprocess, 'run', side_effect=subprocess.TimeoutExpired('query', 6)):
            result = info.collect('Office')
        self.assertEqual(result['printer-make-and-model'], 'Office printer')
        self.assertEqual(result['connection'], 'Secure IPP')
        self.assertEqual(result['address'], 'office.local')
        self.assertNotIn('marker-levels', result)

    def test_live_supplies_and_resolved_address(self):
        connection = Mock()
        connection.getPrinterAttributes.return_value = {}
        connection.getPrinters.return_value = {'Office': {'device-uri': 'ipps://Office._ipps._tcp.local/'}}
        output = {'marker-names': ['BK'], 'marker-levels': [73], 'address': 'printer.local'}
        with patch.dict('sys.modules', {'cups': Mock(Connection=Mock(return_value=connection))}), patch.object(info.subprocess, 'run', return_value=Mock(stdout=json.dumps(output))) as run:
            result = info.collect('Office')
        self.assertEqual(result['marker-levels'], [73])
        self.assertEqual(result['address'], 'printer.local')
        self.assertEqual(run.call_args.kwargs['timeout'], 6)

    def test_non_ipp_devices_are_not_contacted(self):
        with patch.dict('sys.modules', {'cups': Mock()}) as modules:
            self.assertEqual(info.device_attributes('usb://Brother/device'), {})
            modules['cups'].Connection.assert_not_called()

    def test_oversized_and_deep_attributes_are_rejected(self):
        from printers import BackendError, MAX_TEXT_LENGTH, MAX_COLLECTION_ITEMS
        for attrs in ({'printer-info': 'x' * (MAX_TEXT_LENGTH + 1)},
                      {'marker-levels': [100] * (MAX_COLLECTION_ITEMS + 1)},
                      {'printer-info': [[[[[[[[[[[[[['nested']]]]]]]]]]]]]]}):
            with self.subTest(attrs_type=next(iter(attrs))), self.assertRaises(BackendError):
                info.validated_attributes(attrs)

    def test_malformed_optional_fields_cannot_break_qml(self):
        result = info.validated_attributes({
            'printer-info': '<b>Literal printer name</b>',
            'printer-uuid': 123,
            'printer-resolution-supported': 'not an array',
            'color-supported': 'false',
            'printer-alert-description': 'Sleep',
            'marker-names': ['Black', {'bad': 'name'}, 'Cyan'],
            'marker-levels': [40, None, 101, True],
        })
        self.assertEqual(result['printer-info'], '<b>Literal printer name</b>')
        for key in ('printer-uuid', 'printer-resolution-supported', 'color-supported'):
            self.assertNotIn(key, result)
        self.assertEqual(result['printer-alert-description'], ['Sleep'])
        self.assertEqual(result['marker-names'], ['Black', '', 'Cyan'])
        self.assertEqual(result['marker-levels'], [40, -2, -2, -2])

    def test_resolution_shape_and_units_are_validated(self):
        value = [[600, 600, 3], None, [300, 'bad', 3], [0, 0, 3], [600, 600, 9]]
        self.assertEqual(info.validated_attributes({'printer-resolution-supported': value}),
                         {'printer-resolution-supported': [[600, 600, 3]]})
        self.assertEqual(info.validated_attributes({'printer-resolution-supported': (600, 600, 3)}),
                         {'printer-resolution-supported': [[600, 600, 3]]})

    def test_oversized_remote_response_keeps_valid_local_details(self):
        from printers import MAX_TEXT_LENGTH
        connection = Mock()
        connection.getPrinterAttributes.return_value = {'printer-info': 'Office'}
        connection.getPrinters.return_value = {'Office': {'device-uri': 'ipps://printer.local/ipp/print'}}
        response = json.dumps({'printer-info': 'x' * (MAX_TEXT_LENGTH + 1)})
        with patch.dict('sys.modules', {'cups': Mock(Connection=Mock(return_value=connection))}), patch.object(info.subprocess, 'run', return_value=Mock(stdout=response)):
            self.assertEqual(info.collect('Office')['printer-info'], 'Office')
