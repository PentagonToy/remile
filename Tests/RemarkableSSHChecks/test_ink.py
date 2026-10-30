"""Synthetic protocol tests. No account, device or network access."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ink', ROOT / 'others/extensions/remarkable/ink.py')
ink = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ink)


class InkChecks(unittest.TestCase):
    def archive(self, entries):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            for name, content in entries:
                z.writestr(name, content)
        return data.getvalue()

    def test_shared_highlight_colour_is_visible_and_marked_approximate(self):
        from rmc.exporters.writing_tools import RM_PALETTE
        from rmscene.scene_items import PenColor
        original = dict(RM_PALETTE)
        calls = []
        def render(source, target):
            calls.append(True)
            if PenColor.HIGHLIGHT not in RM_PALETTE:
                raise KeyError(PenColor.HIGHLIGHT)
        try:
            RM_PALETTE.pop(PenColor.HIGHLIGHT, None)
            with patch('rmc.rm_to_svg', side_effect=render):
                self.assertTrue(ink.convert_ink('source', 'target'))
            self.assertEqual(len(calls), 2)
            self.assertEqual(RM_PALETTE[PenColor.HIGHLIGHT], (247, 232, 81))
            with patch('rmc.rm_to_svg', side_effect=KeyError(999)):
                with self.assertRaises(ink.InkInputError):
                    ink.convert_ink('source', 'target')
        finally:
            RM_PALETTE.clear()
            RM_PALETTE.update(original)





    def test_traversal_absolute_and_symlink_rejected(self):
        for name in ['../escape.pdf', '/escape.pdf', 'folder\\escape.pdf']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ink.InkInputError):
                    ink.unpack(self.archive([(name, b'x')]), Path(directory))
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            link = zipfile.ZipInfo('link.pdf'); link.external_attr = 0o120777 << 16
            z.writestr(link, '../elsewhere')
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ink.InkInputError):
            ink.unpack(data.getvalue(), Path(directory))

    def test_page_order_mapping_and_deleted_pages(self):
        a, b, c = [str(uuid.uuid4()) for _ in range(3)]
        content = {'cPages': {'pages': [
            {'id': b, 'idx': {'value': 'b'}, 'redir': {'value': 2}},
            {'id': a, 'idx': {'value': 'a'}, 'redir': {'value': 0}},
            {'id': c, 'idx': {'value': 'c'}, 'deleted': {'value': True}}
        ]}}
        self.assertEqual(ink.ordered_pages(content), [(a, 0), (b, 2)])
        self.assertEqual(ink.ordered_pages({'pages': [a, b]}), [(a, 0), (b, 1)])

    def test_invalid_page_indices_fail_closed(self):
        for content in [{'pages': []}, {'pages': ['../file']}, {'pages': [str(uuid.uuid4())] * 2}]:
            with self.subTest(content=content), self.assertRaises((ValueError, KeyError)):
                ink.ordered_pages(content)

    def test_extraction_filters_executables(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ink.unpack(self.archive([('doc.pdf', b'PDF'), ('evil.py', b'code')]), root)
            self.assertEqual((root/'doc.pdf').read_bytes(), b'PDF')
            self.assertFalse((root/'evil.py').exists())

    def test_custom_transform_is_rejected_before_rendering(self):
        item = str(uuid.uuid4())
        data = self.archive([(item+'.content', json.dumps({'transform': {'m11': 2}, 'pages': [str(uuid.uuid4())], 'fileType': 'pdf'}))])
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ink.InkInputError):
            ink.prepare(data, Path(directory), item)


if __name__ == '__main__':
    unittest.main()
