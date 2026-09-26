from pathlib import Path
import sys
import unittest
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import print_cups
from print_cups import validate_settings, portal_settings, job_options

CAPS = {'queues': [{'value':'test','media':[{'value':'a4','width':600,'height':800,'margins':[10,20,30,40]}],
                    'colors':['color','monochrome'],'sides':['one-sided','two-sided-long-edge']}]}
SETTINGS = {'queue':'test','media':'a4','orientation':'portrait','copies':3,'color':'color','sides':'two-sided-long-edge'}

class CupsTests(unittest.TestCase):
    def test_ipp_fallback_uses_ipp_default_not_ppd_name(self):
        import cups
        with tempfile.TemporaryDirectory() as tmp:
            ppd_path = Path(tmp) / 'printer.ppd'
            ppd_path.write_text('test')
            attrs = {'media-default': 'iso_a4_210x297mm', 'media-supported': ['om_16k_195x270mm', 'iso_a4_210x297mm']}
            attrs.update({'media-' + side + '-margin-supported': [423] for side in ('left','top','right','bottom')})
            conn = SimpleNamespace(getPrinters=lambda: {'Test': {}}, getPrinterAttributes=lambda _: attrs,
                                   getPPD=lambda _: str(ppd_path), getDefault=lambda: 'Test')
            ppd = SimpleNamespace(findOption=lambda _: SimpleNamespace(defchoice='A4', choices=[]))
            with patch.object(print_cups, 'connection', return_value=conn), patch.object(cups, 'PPD', return_value=ppd):
                result = print_cups.capabilities()['queues'][0]
            self.assertEqual(result['defaultMedia'], 'iso_a4_210x297mm')
            self.assertIn(result['defaultMedia'], [m['value'] for m in result['media']])

    def test_landscape_rotates_hardware_margins(self):
        s=validate_settings(dict(SETTINGS,orientation='landscape'),CAPS)
        self.assertEqual(s['paper'],{'width':800,'height':600,'margins':[40,10,20,30]})
        values, page=portal_settings(s)
        self.assertEqual(values['n-copies'],'1')
        self.assertEqual(values['number-up'],'1')
        self.assertNotIn('scale',values)
        self.assertAlmostEqual(page['Width'],600*25.4/72)
        self.assertAlmostEqual(page['MarginLeft'],10*25.4/72)

    def test_application_scale_is_preserved_only_for_source_rendering(self):
        settings = validate_settings(SETTINGS, CAPS)
        for scale in ('50', '100', '125.5'):
            values, _ = portal_settings(settings, scale)
            self.assertEqual(values['scale'], scale)
        self.assertNotIn('scale', job_options(settings))
        for invalid in (None, 'bad', 'nan', 'inf', 0, -50, 10001):
            self.assertNotIn('scale', portal_settings(settings, invalid)[0])

    def test_cups_applies_copies_once_and_no_scaling(self):
        s=validate_settings(SETTINGS,CAPS)
        opts=job_options(s)
        self.assertEqual(opts['copies'],'3')
        self.assertEqual(opts['print-scaling'],'none')
        self.assertNotIn('page-ranges',opts)

    def test_color_choice_reaches_cups(self):
        for color in ('monochrome', 'color'):
            settings = validate_settings(dict(SETTINGS, color=color), CAPS)
            self.assertEqual(job_options(settings)['print-color-mode'], color)

    def test_unknown_printer_media_and_options_are_rejected(self):
        for key,value in [('queue','other'),('media','letter'),('copies',0),('color','invalid'),('sides','invalid')]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                validate_settings(dict(SETTINGS,**{key:value}),CAPS)
