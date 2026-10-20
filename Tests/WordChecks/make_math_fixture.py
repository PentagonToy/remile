"""Independently authored semantic math cases; no LibreOffice fixture/code is used."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import sys

root = Path(sys.argv[1])
with ZipFile(root / 'Layout.docx') as archive:
    entries = {name: archive.read(name) for name in archive.namelist()}
namespace = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"'
run = lambda text: f'<m:r><m:t>{text}</m:t></m:r>'
expr = lambda text: f'<m:e>{run(text)}</m:e>'
math = lambda content: f'<m:oMath>{content}</m:oMath>'
p = lambda label, content: f'<w:p><w:r><w:t xml:space="preserve">{label}: </w:t></w:r>{math(content)}</w:p>'
def nary(character, location=''):
    return '<m:nary><m:naryPr><m:chr m:val="' + character + '"/>' + (f'<m:limLoc m:val="{location}"/>' if location else '') + '</m:naryPr><m:sub>' + run('0') + '</m:sub><m:sup>' + run('n') + '</m:sup>' + expr('x') + '</m:nary>'
body = p('Side limits', nary('∫', 'subSup')) + p('Stacked limits', nary('∫', 'undOvr')) + p('Document default sum', nary('∑'))
body += p('Underbrace', '<m:groupChr>' + expr('x+y+z') + '</m:groupChr>')
body += p('Border', '<m:borderBox>' + expr('E=mc²') + '</m:borderBox>')
body += p('Hidden spacer', run('A') + '<m:phant><m:phantPr><m:show m:val="0"/></m:phantPr>' + expr('HIDDEN') + '</m:phant>' + run('B'))
body += p('Visible default', '<m:phant>' + expr('VISIBLE') + '</m:phant>')
body += p('Zero width', run('A') + '<m:phant><m:phantPr><m:show m:val="0"/><m:zeroWid/></m:phantPr>' + expr('HIDDEN') + '</m:phant>' + run('B'))
section = '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1134" w:bottom="1440" w:left="1134"/></w:sectPr>'
entries['word/document.xml'] = f'<w:document {namespace}><w:body>{body}{section}</w:body></w:document>'.encode()
entries['word/settings.xml'] = f'<w:settings {namespace}><m:mathPr><m:intLim m:val="undOvr"/><m:naryLim m:val="subSup"/></m:mathPr></w:settings>'.encode()
with ZipFile(root / 'MathSemantics.docx', 'w', compression=ZIP_DEFLATED) as archive:
    for name, data in entries.items(): archive.writestr(name, data)
