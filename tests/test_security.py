import io
import json
import re
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend import printers


class ResponseLimitTests(unittest.TestCase):
    def dispatch_data(self, command, data):
        backend = SimpleNamespace(**{printers.COMMANDS[command]: lambda _: data})
        return printers.dispatch(command, {}, backend)

    def assert_rejected(self, command, data):
        with self.assertRaises(printers.BackendError) as caught:
            self.dispatch_data(command, data)
        self.assertEqual(caught.exception.code, 'response-too-large')

    def test_markup_is_preserved_as_literal_data(self):
        label = '<img src="https://example.invalid/image"><b>Printer</b>'
        response = self.dispatch_data('queues', {'queues': [{'name': label}]})
        self.assertEqual(response['data']['queues'][0]['name'], label)

    def test_oversized_external_strings_and_identifiers_are_rejected(self):
        huge = 'x' * (printers.MAX_TEXT_LENGTH + 1)
        for command, data in [
            ('queues', {'queues': [{'name': huge}]}),
            ('snapshot', {'available': [{'uri': huge}]}),
            ('jobs', {'jobs': [{'name': huge}]}),
            ('models', {'models': [{'makeAndModel': huge}]}),
            ('options', {'options': [{'choices': [{'label': huge}]}]}),
            ('options', {'defaults': {huge: 'value'}}),
            ('manage', {'optionsError': {'message': huge}}),
        ]:
            with self.subTest(command=command, data_type=list(data)):
                self.assert_rejected(command, data)

    def test_every_collection_limit(self):
        for field, limit in printers.COLLECTION_LIMITS.items():
            with self.subTest(field=field):
                self.dispatch_data('queues', {field: [None] * limit})
                self.assert_rejected('queues', {field: [None] * (limit + 1)})
        self.assert_rejected('queues', {'unknown': [None] * (printers.MAX_COLLECTION_ITEMS + 1)})
        self.assert_rejected('queues', {str(i): None for i in range(printers.MAX_COLLECTION_ITEMS + 1)})

    def test_nested_choices_are_bounded(self):
        self.assert_rejected('options', {'options': [{
            'choices': [None] * (printers.COLLECTION_LIMITS['choices'] + 1)
        }]})

    def test_depth_and_total_nodes_are_bounded(self):
        data = None
        for _ in range(printers.MAX_PAYLOAD_DEPTH + 1):
            data = [data]
        self.assert_rejected('queues', data)
        with patch.object(printers, 'MAX_PAYLOAD_NODES', 10):
            self.assert_rejected('queues', [[None] * 5, [None] * 5])

    def test_encoded_size_includes_unicode_escaping(self):
        with patch.object(printers, 'MAX_RESPONSE_BYTES', 100):
            self.dispatch_data('queues', {'name': 'x' * 20})
            self.assert_rejected('queues', {'name': '\U0001f600' * 20})

    def test_oversized_settings_do_not_hide_jobs(self):
        cups = SimpleNamespace(
            options=lambda _: {'options': [{'label': 'x' * (printers.MAX_TEXT_LENGTH + 1)}]},
            jobs=lambda _: [{'id': 4}],
        )
        result = printers.PrinterBackend(cups, None).manage({'queue': 'Office'})
        self.assertEqual(result['jobs'], [{'id': 4}])
        self.assertEqual(result['optionsError']['code'], 'response-too-large')
        self.assertEqual(result['options'], [])

    def test_oversized_jobs_do_not_hide_settings(self):
        cups = SimpleNamespace(
            options=lambda _: {'options': [{'name': 'Duplex'}]},
            jobs=lambda _: [None] * (printers.COLLECTION_LIMITS['jobs'] + 1),
        )
        result = printers.PrinterBackend(cups, None).manage({'queue': 'Office'})
        self.assertEqual(result['options'], [{'name': 'Duplex'}])
        self.assertEqual(result['jobsError']['code'], 'response-too-large')
        self.assertEqual(result['jobs'], [])

    def test_cli_emits_only_bounded_error_for_oversized_response(self):
        out = io.StringIO()
        with patch.object(printers, 'dispatch', return_value={
            'data': {'name': 'x' * (printers.MAX_TEXT_LENGTH + 1)}
        }), redirect_stdout(out):
            status = printers.main(['queues', '--json', '{}'])
        response = json.loads(out.getvalue())
        self.assertEqual(status, 1)
        self.assertFalse(response['ok'])
        self.assertEqual(response['error']['code'], 'response-too-large')
        self.assertNotIn('data', response)

    def test_cli_error_strings_and_diagnostics_are_bounded(self):
        huge = 'x' * (printers.MAX_TEXT_LENGTH * 2)
        out, err = io.StringIO(), io.StringIO()
        with patch.object(printers, 'dispatch', side_effect=printers.BackendError(
            huge, huge, diagnostic=huge
        )), redirect_stdout(out), redirect_stderr(err):
            printers.main(['queues', '--json', '{}'])
        error = json.loads(out.getvalue())['error']
        self.assertEqual(len(error['code']), printers.MAX_TEXT_LENGTH)
        self.assertEqual(len(error['message']), printers.MAX_TEXT_LENGTH)
        self.assertLess(len(err.getvalue()), printers.MAX_TEXT_LENGTH + 100)


class PlainTextTests(unittest.TestCase):
    def test_all_plugin_text_elements_explicitly_use_plain_text(self):
        # Covers reusable row/status components as well as inline Text elements.
        for path in ROOT.glob('*.qml'):
            source = path.read_text()
            starts = list(re.finditer(r'\bText\s*\{', source))
            if path.name != "PrinterService.qml":
                self.assertTrue(starts, path.name)
            for match in starts:
                line = source[:match.start()].count('\n') + 1
                with self.subTest(file=path.name, line=line):
                    self.assertRegex(source[match.end():], r'^\s*textFormat:\s*Text\.PlainText\b')


if __name__ == '__main__':
    unittest.main()
