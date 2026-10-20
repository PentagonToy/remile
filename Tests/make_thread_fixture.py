"""Generate a standards-based reply fixture independently of the Swift writer."""
import sys
from pathlib import Path
from pypdf import PdfWriter
from pypdf.generic import ArrayObject, DictionaryObject, FloatObject, NameObject, TextStringObject

folder = Path(sys.argv[1])
folder.mkdir(parents=True, exist_ok=True)
def annotation(text, name):
    return DictionaryObject({
        NameObject("/Type"): NameObject("/Annot"),
        NameObject("/Subtype"): NameObject("/Text"),
        NameObject("/Rect"): ArrayObject([FloatObject(n) for n in [40, 40, 64, 64]]),
        NameObject("/Contents"): TextStringObject(text),
        NameObject("/NM"): TextStringObject(name),
        NameObject("/T"): TextStringObject("Independent reviewer"),
    })
writer = PdfWriter()
writer.add_blank_page(width=500, height=600)
parent = writer.add_annotation(0, annotation("Independent parent", "부모 (검토) \\ 1"))
reply = annotation("Independent reply", "reply-2")
reply[NameObject("/IRT")] = parent.indirect_reference
reply[NameObject("/RT")] = NameObject("/R")
writer.add_annotation(0, reply)
writer.write(folder / "independent-input.pdf")
