"""Independent OOXML fixtures; no document library or Office installation required."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED, ZIP_STORED
import struct
import sys
import zlib

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
width, height = 160, 80
raw = b''.join(b'\0' + bytes([35, 100, 200]) * width for _ in range(height))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
paragraph = lambda text: f'<w:p><w:r><w:t>{text}</w:t></w:r></w:p>'
image = '''<w:p><w:r><w:drawing><wp:inline><wp:extent cx="3048000" cy="1524000"/><wp:docPr id="1" name="Blue fixture"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="blue.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="3048000" cy="1524000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>'''
rows = ''.join('<w:tr>' + ''.join(f'<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr>{paragraph(cell)}</w:tc>' for cell in row) + '</w:tr>' for row in [('Element', 'Value'), ('Hydrogen', '1.008'), ('Helium', '4.003')])
table = '<w:tbl><w:tblPr><w:tblW w:w="8000" w:type="dxa"/><w:tblBorders>' + ''.join(f'<w:{edge} w:val="single" w:sz="8" w:color="222C35"/>' for edge in ['top', 'left', 'bottom', 'right', 'insideH', 'insideV']) + '</w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w="4000"/><w:gridCol w:w="4000"/></w:tblGrid>' + rows + '</w:tbl>'
body = '<w:p><w:r><w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="A13F3B"/></w:rPr><w:t>Word conversion fixture</w:t></w:r></w:p>' + paragraph('BeforeImageMarker') + image + paragraph('AfterImageMarker') + table + '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' + paragraph('SecondPageMarker') + paragraph('한글 문서 · Ελληνικά · scientific text')
long = ''.join(paragraph(f'Paragraph {i}: hydrogen helium and a searchable document.') for i in range(180)) + paragraph('FinalWordMarker')
ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"'
for name, content in [('Rich.docx', body), ('Stored.docx', body), ('Long.docx', long), ('Missing.docx', body), ('External.docx', body), ('Equation.docx', body + '<m:oMath xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"><m:r><m:t>x</m:t></m:r></m:oMath>'), ('Floating.docx', body.replace('wp:inline', 'wp:anchor')), ('Header.docx', body), ('LongTable.docx', table.replace(rows, ''.join('<w:tr><w:tc>' + paragraph(f'RowMarker{i}') + '</w:tc><w:tc>' + paragraph(f'ValueMarker{i}') + '</w:tc></w:tr>' for i in range(100))))]:
    with ZipFile(root / name, 'w', compression=ZIP_STORED if name == 'Stored.docx' else ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        archive.writestr('_rels/.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        archive.writestr('word/document.xml', f'<?xml version="1.0"?><w:document {ns}><w:body>{content}<w:sectPr>{'<w:headerReference w:type="default" r:id="header"/>' if name == 'Header.docx' else ''}<w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134"/></w:sectPr></w:body></w:document>')
        archive.writestr('word/_rels/document.xml.rels', '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdImage" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" ' + ('Target="https://example.invalid/image.png" TargetMode="External"' if name == 'External.docx' else 'Target="media/missing.png"' if name == 'Missing.docx' else 'Target="media/blue.png"') + '/></Relationships>')
        archive.writestr('word/media/blue.png', png)
