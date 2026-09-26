#!/usr/bin/env python3
"""Rebuild the bundled test PDF using the installed Omarchy vector logo.
Build-only dependencies: Cairo and librsvg GI (not needed to print the PDF).
"""
from pathlib import Path
import cairo
import gi

gi.require_version('Rsvg', '2.0')
from gi.repository import Rsvg

root = Path(__file__).resolve().parents[1]
surface = cairo.PDFSurface(str(root / 'assets/test-page.pdf'), 595.276, 841.89)
surface.set_metadata(cairo.PDF_METADATA_TITLE, 'Omarchy printer test page')
ctx = cairo.Context(surface)
ctx.set_source_rgb(1, 1, 1)
ctx.paint()
ctx.set_source_rgb(0, 0, 0)
logo = Rsvg.Handle.new_from_file('/usr/share/omarchy/logo.svg')
rect = Rsvg.Rectangle()
rect.x, rect.y, rect.width, rect.height = 56, 65, 483, 114
logo.render_document(ctx, rect)


def text(value, x, y, size=11, bold=False):
    ctx.set_source_rgb(0, 0, 0)
    ctx.select_font_face('monospace', cairo.FONT_SLANT_NORMAL,
                         cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    ctx.set_font_size(size)
    ctx.move_to(x, y)
    ctx.show_text(value)


def rule(y):
    ctx.set_source_rgb(0.7, 0.7, 0.7)
    ctx.set_line_width(.5)
    ctx.move_to(56, y)
    ctx.line_to(539, y)
    ctx.stroke()


text('PRINTER TEST PAGE', 56, 225, 18, True)
text('A simple check of text, shading, and line quality.', 56, 251, 10)
rule(278)
text('TEXT', 56, 310, 11, True)
text('The quick brown fox jumps over the lazy dog.', 56, 340, 12)
text('ABCDEFGHIJKLMNOPQRSTUVWXYZ  0123456789', 56, 365, 10)
text('Small text should remain sharp and readable.', 56, 388, 8)
rule(416)
text('GRAYSCALE', 56, 448, 11, True)
for i in range(11):
    gray = i / 10
    ctx.set_source_rgb(gray, gray, gray)
    ctx.rectangle(56 + i * 43.9, 472, 43.9, 50)
    ctx.fill()
ctx.set_source_rgb(0, 0, 0)
ctx.set_line_width(.5)
ctx.rectangle(56, 472, 483, 50)
ctx.stroke()
text('Black', 56, 542, 9)
text('White', 509, 542, 9)
rule(565)
text('LINES & LOGO DETAIL', 56, 597, 11, True)
for i, width in enumerate([.25, .5, 1, 2]):
    y = 625 + i * 22
    ctx.set_source_rgb(0, 0, 0)
    ctx.set_line_width(width)
    ctx.move_to(56, y)
    ctx.line_to(327, y)
    ctx.stroke()
    text(str(width) + ' pt', 347, y + 3, 9)
# Keep the official square mark alongside the line samples: its flat fills
# and stepped corners expose banding and loss of edge definition.
icon = cairo.ImageSurface.create_from_png('/usr/share/omarchy/icon.png')
ctx.save()
ctx.translate(439, 612)
ctx.scale(100 / icon.get_width(), 100 / icon.get_height())
ctx.set_source_surface(icon, 0, 0)
ctx.get_source().set_filter(cairo.FILTER_NEAREST)
ctx.paint()
ctx.restore()
text('Check solid fills and sharp corners.', 56, 719, 9)
rule(743)
text('OMARCHY PRINTERS', 56, 768, 9, True)
text('One page. Ready to print.', 56, 786, 9)
ctx.show_page()
surface.finish()
