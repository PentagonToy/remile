"""Bounded local handwriting conversion. No cloud or account connection."""
import io
import json
from pathlib import Path, PurePosixPath
import uuid
import zipfile
import xml.etree.ElementTree as ET

class InkInputError(ValueError):
    pass


MAX_ARCHIVE = 128 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024


def identifier(value):
    return str(uuid.UUID(value))


def unpack(data, directory):
    if len(data) > MAX_ARCHIVE:
        raise InkInputError("Document exceeds the download limit.")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        if len(members) > 4000 or sum(x.file_size for x in members) > MAX_EXPANDED:
            raise InkInputError("Document exceeds the extraction limit.")
        for item in members:
            path = PurePosixPath(item.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in item.filename or (item.external_attr >> 16) & 0o170000 == 0o120000:
                raise InkInputError("Unsafe document archive.")
            if item.file_size > 64 * 1024 * 1024:
                raise InkInputError("A document file exceeds the size limit.")
        for item in members:
            if item.is_dir() or PurePosixPath(item.filename).suffix not in {'.content', '.metadata', '.pdf', '.rm'}:
                continue
            destination = directory / item.filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(item) as source, destination.open('xb') as target:
                while chunk := source.read(65536):
                    target.write(chunk)


def scalar(value, default=None):
    return value.get('value', default) if isinstance(value, dict) else value


def ordered_pages(content):
    pages = content.get('pages')
    if isinstance(pages, list) and all(isinstance(x, str) for x in pages):
        result = [(identifier(page), index) for index, page in enumerate(pages)]
    else:
        pages = content.get('cPages', {}).get('pages', [])
        if not isinstance(pages, list):
            raise InkInputError("Unsupported page index.")
        active = [x for x in pages if not scalar(x.get('deleted'), False)]
        active.sort(key=lambda x: str(scalar(x.get('idx'), '')))
        result = [(identifier(x['id']), scalar(x.get('redir'), None)) for x in active]
    if not result or len(result) > 500 or len({x[0] for x in result}) != len(result):
        raise InkInputError("Unsupported or oversized page index.")
    if any(index is not None and (not isinstance(index, int) or index < 0 or index > 10000) for _, index in result):
        raise InkInputError("Invalid PDF page mapping.")
    return result


def convert_ink(source, target):
    from rmc import rm_to_svg
    from rmc.exporters.writing_tools import RM_PALETTE
    from rmscene.scene_items import PenColor
    approximated = PenColor.HIGHLIGHT in RM_PALETTE
    try:
        rm_to_svg(source, target)
    except KeyError as error:
        if error.args != (PenColor.HIGHLIGHT,):
            raise InkInputError("This ink colour is not supported yet. Use a PDF export from reMarkable.") from None
        # The renderer does not decode the separate highlight colour payload.
        # Keep the stroke visible and report the approximation instead of discarding ink.
        RM_PALETTE[PenColor.HIGHLIGHT] = (247, 232, 81)
        rm_to_svg(source, target)
        approximated = True
    return approximated


def prepare(data, directory, item_id):
    unpack(data, directory)
    contents = list(directory.rglob(item_id + '.content'))
    if len(contents) != 1:
        raise InkInputError("Document content index is unavailable.")
    content = json.loads(contents[0].read_text())
    # Custom PDF transforms need validation against actual device exports first.
    transform = content.get('transform')
    if transform and transform != {'m11': 1, 'm12': 0, 'm13': 0, 'm21': 0, 'm22': 1, 'm23': 0, 'm31': 0, 'm32': 0, 'm33': 1}:
        raise InkInputError("This page layout needs a reMarkable PDF export. Custom transforms are not supported yet.")
    backgrounds = list(directory.rglob(item_id + '.pdf'))
    if len(backgrounds) > 1:
        raise InkInputError("Ambiguous PDF background.")
    if content.get('fileType') not in {'pdf', 'notebook'}:
        raise InkInputError("Only PDF documents and notebooks are supported.")
    approximate_highlights = False
    result = []
    for page_id, index in ordered_pages(content):
        if not backgrounds:
            index = None
        candidates = list(directory.rglob(page_id + '.rm'))
        if len(candidates) > 1:
            raise InkInputError("Ambiguous ink page.")
        svg_name = None
        if candidates:
            rm = candidates[0]
            with rm.open('rb') as source:
                header = source.read(43)
            if not header.startswith(b'reMarkable .lines file, version=6'):
                raise InkInputError("Unsupported handwriting format. Export this document as PDF from reMarkable.")
            svg = directory / (page_id + '.svg')
            approximate_highlights = convert_ink(rm, svg) or approximate_highlights
            raw = svg.read_bytes()
            if len(raw) > 8 * 1024 * 1024 or b'<!' in raw or b'<?' in raw.replace(b'<?xml version="1.0" encoding="UTF-8"?>', b''):
                raise InkInputError("Unsupported ink image.")
            root = ET.fromstring(raw)
            for node in root.iter():
                if node.tag.split('}')[-1] not in {'svg','g','path','rect','circle','ellipse','line','polyline','polygon','text','tspan'}:
                    raise InkInputError("Unsupported ink element.")
                for name, value in node.attrib.items():
                    if name.lower().startswith('on') or 'href' in name.lower() or 'url(' in value.lower():
                        raise InkInputError("External ink resources are not permitted.")
            box = [float(x) for x in root.attrib['viewBox'].replace(',', ' ').split()]
            if len(box) != 4 or any(abs(x) > 10000 for x in box) or box[2] <= 0 or box[3] <= 0:
                raise InkInputError("Unsupported ink bounds.")
            svg_name = svg.name
        else:
            box = None
        result.append({'id': page_id, 'backgroundPage': index, 'svg': svg_name, 'bounds': box})
    return {'warning': 'Highlight colours approximated.' if approximate_highlights else None, 'pages': result, 'background': str(backgrounds[0].relative_to(directory)) if backgrounds else None}
