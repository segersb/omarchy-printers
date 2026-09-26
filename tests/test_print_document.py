import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import print_document as doc


class GeometryTests(unittest.TestCase):
    paper = {'width': 600, 'height': 800, 'margins': [10, 20, 30, 40]}

    def test_zoom_and_pan_use_physical_page_coordinates(self):
        g = doc.placement(200, 100, self.paper, {'zoom': 150, 'x': 12, 'y': -8})
        self.assertEqual(g['scale'], 1.5)
        self.assertEqual((g['x'], g['y']), (162, 317))
        self.assertEqual(g['clip'], [10, 20, 560, 740])

    def test_reset_preserves_original_size_and_centers(self):
        g = doc.placement(600, 800, self.paper, {})
        self.assertEqual((g['scale'], g['x'], g['y']), (1, 0, 0))
        self.assertTrue(g['cropped'])

    def test_invalid_adjustments(self):
        for edit in ({'zoom': 0}, {'zoom': 401}, {'x': float('nan')}, {'y': 15000}):
            with self.assertRaises(ValueError):
                doc.adjustment(edit)

    def test_ranges_filter_once_and_deduplicate(self):
        self.assertEqual(doc.selected_pages('1-3, 2, 5', 5), [0, 1, 2, 4])
        for text in ('0', '2-1', '6', '1,,2', '1-2-3', 'bad'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                doc.selected_pages(text, 5)


class DocumentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.cairo, _ = doc.libraries()

    def make_pdf(self):
        file = self.path / 'source.pdf'
        surface = self.cairo.PDFSurface(str(file), 300, 400)
        ctx = self.cairo.Context(surface)
        ctx.rectangle(100, 100, 100, 200)
        ctx.fill()
        ctx.show_page()
        surface.set_size(400, 300)
        ctx.show_page()  # blank second page
        surface.finish()
        return file

    def test_page_edits_and_all_pages_default(self):
        meta = doc.transform(self.make_pdf(), self.path / 'out.pdf', {
            'paper': GeometryTests.paper, 'defaultAdjustment': {'zoom': 50},
            'adjustments': {'1': {'zoom': 200, 'x': 20, 'y': -10}}})
        self.assertEqual([p['scale'] for p in meta['pages']], [2, .5])
        self.assertEqual([p['source'] for p in meta['pages']], [1, 2])
        # Output content uses the same placement as the live preview.
        page = doc.open_pdf(self.path / 'out.pdf').get_page(0)
        surface = self.cairo.ImageSurface(self.cairo.FORMAT_RGB24, 600, 800)
        ctx = self.cairo.Context(surface)
        ctx.set_source_rgb(1, 1, 1); ctx.paint(); page.render_for_printing(ctx)
        surface.flush(); pixels = surface.get_data(); stride = surface.get_stride()
        channel = 0 if sys.byteorder == 'little' else 1
        self.assertEqual(pixels[200 * stride + 225 * 4 + channel], 0)
        self.assertEqual(pixels[200 * stride + 210 * 4 + channel], 255)

    def test_transform_and_preview_same_document(self):
        source = self.make_pdf()
        output = self.path / 'output.pdf'
        meta = doc.transform(source, output, {'paper': GeometryTests.paper, 'defaultAdjustment': {'zoom': 250}, 'pages': '1'})
        self.assertEqual(meta['count'], 2)
        self.assertEqual(len(meta['pages']), 1)
        self.assertTrue(meta['pages'][0]['cropped'])
        self.assertEqual(tuple(doc.open_pdf(output).get_page(0).get_size()), (600, 800))
        doc.preview(output, self.path / 'page.png')
        surface = self.cairo.ImageSurface.create_from_png(str(self.path / 'page.png'))
        self.assertGreater(surface.get_width(), 500)
        # Printed output remains vector content, not a screenshot of the preview.
        result = subprocess.run(['pdfimages', '-list', str(output)], capture_output=True, text=True, check=True)
        self.assertEqual(len(result.stdout.strip().splitlines()), 2)

    def test_rotated_offset_cropbox_is_normalized(self):
        # Independent raw fixture: nonzero media/crop origins and /Rotate 90.
        stream = b"0 0 0 rg 100 100 50 100 re f"
        objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
                   b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                   b"<< /Type /Page /Parent 2 0 R /MediaBox [20 30 320 430] /CropBox [70 80 270 380] /Rotate 90 /Resources << >> /Contents 4 0 R >>",
                   b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"]
        data = bytearray(b"%PDF-1.4\n")
        offsets = [0]
        for i, obj in enumerate(objects, 1):
            offsets.append(len(data))
            data.extend(str(i).encode() + b" 0 obj\n" + obj + b"\nendobj\n")
        start = len(data)
        data.extend(b"xref\n0 5\n0000000000 65535 f \n")
        for offset in offsets[1:]:
            data.extend(f"{offset:010} 00000 n \n".encode())
        data.extend(f"trailer << /Size 5 /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode())
        path = self.path / 'rotated.pdf'
        path.write_bytes(data)
        page = doc.open_pdf(path).get_page(0)
        self.assertEqual(tuple(page.get_size()), (300, 200))
        result = doc.transform(path, self.path / 'rotated-out.pdf', {'paper': GeometryTests.paper})
        self.assertEqual((result['pages'][0]['width'], result['pages'][0]['height']), (300, 200))

    def test_direct_png_preserves_aspect_ratio_and_transparency(self):
        source = self.path / 'image.png'
        surface = self.cairo.ImageSurface(self.cairo.FORMAT_ARGB32, 600, 400)
        ctx = self.cairo.Context(surface)
        ctx.set_source_rgba(0.2, 0.4, 0.8, 0.5)
        ctx.rectangle(0, 0, 600, 400)
        ctx.fill()
        surface.write_to_png(str(source))
        output = self.path / 'image.pdf'
        info = doc.image_pdf(source, output)
        self.assertEqual(info['dpi'], 96)
        self.assertEqual(tuple(doc.open_pdf(output).get_page(0).get_size()), (450, 300))

    def test_direct_jpeg_respects_exif_rotation(self):
        import gi
        import struct
        gi.require_version('GdkPixbuf', '2.0')
        from gi.repository import GdkPixbuf
        pixbuf = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, False, 8, 200, 100)
        pixbuf.fill(0x336699ff)
        source = self.path / 'image.jpg'
        pixbuf.savev(str(source), 'jpeg', [], [])
        # Minimal EXIF IFD: orientation=6 (90 degrees clockwise).
        exif = b'Exif\0\0II' + struct.pack('<HIH', 42, 8, 1)
        exif += struct.pack('<HHIHHI', 0x0112, 3, 1, 6, 0, 0)
        jpeg = source.read_bytes()
        source.write_bytes(jpeg[:2] + b'\xff\xe1' + struct.pack('>H', len(exif)+2) + exif + jpeg[2:])
        output = self.path / 'image.pdf'
        doc.image_pdf(source, output)
        w, h = doc.open_pdf(output).get_page(0).get_size()
        self.assertAlmostEqual(h / w, 2)

    def test_invalid_pdf_is_rejected(self):
        file = self.path / 'source.pdf'
        file.write_bytes(b'not pdf')
        with self.assertRaises(ValueError):
            doc.open_pdf(file)

    def test_worker_keeps_selected_source_page_and_adjustment(self):
        source = self.make_pdf()
        request = {'action': 'render', 'source': str(source), 'output': str(self.path / 'out.pdf'),
                   'image': str(self.path / 'out.png'), 'sourceImage': str(self.path / 'original.png'),
                   'viewSource': 2, 'settings': {'paper': GeometryTests.paper,
                   'adjustments': {'2': {'zoom': 175, 'x': 12}}}}
        for selection, expected_view in (('', 1), ('2', 0)):
            request['settings']['pages'] = selection
            result = subprocess.run([sys.executable, doc.__file__], input=json.dumps(request),
                                    text=True, capture_output=True, check=True)
            meta = json.loads(result.stdout)['data']
            self.assertEqual(meta['viewPage'], expected_view)
            self.assertEqual(meta['pages'][expected_view]['source'], 2)
            self.assertEqual(meta['pages'][expected_view]['scale'], 1.75)
            original = self.cairo.ImageSurface.create_from_png(request['sourceImage'])
            self.assertEqual((original.get_width(), original.get_height()), (800, 600))

    def test_worker_rejects_invalid_page_ranges(self):
        source = self.make_pdf()
        request = {'action': 'render', 'source': str(source), 'output': str(self.path / 'out.pdf'),
                   'image': str(self.path / 'out.png'), 'settings': {'paper': GeometryTests.paper, 'pages': '99'}}
        result = subprocess.run([sys.executable, doc.__file__], input=json.dumps(request), text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)['ok'])


if __name__ == '__main__':
    unittest.main()
