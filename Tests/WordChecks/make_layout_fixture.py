"""Add independent header/footer, OMML and inline-shape fixtures to the basic suite."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import sys

root = Path(sys.argv[1])
with ZipFile(root / 'Rich.docx') as archive:
    entries = {name: archive.read(name) for name in archive.namelist()}
ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office"'
p = lambda text: f'<w:p><w:r><w:t>{text}</w:t></w:r></w:p>'
r = lambda text: f'<m:r><m:t>{text}</m:t></m:r>'
formula = '<m:oMath><m:f><m:num>' + r('a+b') + '</m:num><m:den><m:rad><m:radPr><m:degHide m:val="1"/></m:radPr><m:deg/ ><m:e>' + r('x') + '</m:e></m:rad></m:den></m:f>' + r('=') + '<m:sSup><m:e>' + r('y') + '</m:e><m:sup>' + r('2') + '</m:sup></m:sSup></m:oMath>'
formula = formula.replace('<m:deg/ >', '<m:deg/>')
shape = '<w:r><w:drawing><wp:inline><wp:extent cx="1828800" cy="914400"/><wps:wsp><wps:spPr><a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="A13F3B"/></a:solidFill><a:ln><a:solidFill><a:srgbClr val="222C35"/></a:solidFill></a:ln></wps:spPr></wps:wsp></wp:inline></w:drawing></w:r>'
section = '<w:sectPr><w:headerReference w:type="default" r:id="hDefault"/><w:headerReference w:type="first" r:id="hFirst"/><w:headerReference w:type="even" r:id="hEven"/><w:footerReference w:type="default" r:id="fDefault"/><w:footerReference w:type="first" r:id="fDefault"/><w:footerReference w:type="even" r:id="fDefault"/><w:titlePg/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1134" w:bottom="1440" w:left="1134" w:header="360" w:footer="360"/></w:sectPr>'
preview = '<w:p><w:r><w:object><v:shape style="width:120pt;height:60pt"><v:imagedata r:id="rPreview"/></v:shape><o:OLEObject Type="Embed" ProgID="Equation.3" r:id="rObject"/></w:object></w:r></w:p>'
body = p('BodyOne') + '<w:p>' + formula + '</w:p><w:p>' + shape + '</w:p>' + preview + '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' + p('BodyTwo') + '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' + p('BodyThree')
entries['word/document.xml'] = f'<w:document {ns}><w:body>{body}{section}</w:body></w:document>'.encode()
relationships = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
for id, target, kind in [('hDefault','header1.xml','header'), ('hFirst','header2.xml','header'), ('hEven','header3.xml','header'), ('fDefault','footer1.xml','footer')]:
    relationships += f'<Relationship Id="{id}" Target="{target}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/{kind}"/>'
relationships += '<Relationship Id="rPreview" Target="media/blue.png" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"/>'
entries['word/_rels/document.xml.rels'] = (relationships + '</Relationships>').encode()
entries['word/header1.xml'] = f'<w:hdr {ns}>{p("DefaultHeader")}</w:hdr>'.encode()
entries['word/header2.xml'] = f'<w:hdr {ns}>{p("FirstHeader")}</w:hdr>'.encode()
entries['word/header3.xml'] = f'<w:hdr {ns}>{p("EvenHeader")}</w:hdr>'.encode()
footer = '<w:p><w:r><w:t>Page </w:t></w:r><w:fldSimple w:instr=" PAGE "><w:r><w:t>9</w:t></w:r></w:fldSimple><w:r><w:t> of </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> NUMPAGES </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>9</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
entries['word/footer1.xml'] = f'<w:ftr {ns}>{footer}</w:ftr>'.encode()
entries['word/settings.xml'] = f'<w:settings {ns}><w:evenAndOddHeaders/></w:settings>'.encode()
for filename in ['Layout.docx', 'MissingHeader.docx', 'UnknownMath.docx', 'OverflowHeader.docx', 'Freeform.docx']:
    current = entries.copy()
    if filename == 'MissingHeader.docx': current.pop('word/header2.xml')
    if filename == 'OverflowHeader.docx': current['word/header2.xml'] = f'<w:hdr {ns}>{p("Too tall") * 30}</w:hdr>'.encode()
    if filename == 'Freeform.docx': current['word/document.xml'] = current['word/document.xml'].replace(b'<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>', b'<a:custGeom><a:pathLst><a:path w="1000" h="1000"><a:moveTo><a:pt x="0" y="0"/></a:moveTo><a:cubicBezTo><a:pt x="1000" y="0"/><a:pt x="0" y="1000"/><a:pt x="1000" y="1000"/></a:cubicBezTo><a:lnTo><a:pt x="0" y="1000"/></a:lnTo><a:close/></a:path></a:pathLst></a:custGeom>')
    if filename == 'UnknownMath.docx': current['word/document.xml'] = current['word/document.xml'].replace(b'<m:f>', b'<m:unknown>').replace(b'</m:f>', b'</m:unknown>')
    with ZipFile(root / filename, 'w', compression=ZIP_DEFLATED) as archive:
        for name, data in current.items(): archive.writestr(name, data)
