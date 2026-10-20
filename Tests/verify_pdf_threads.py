"""Independent structural checks; requires pypdf in the chosen test environment."""
import json
import sys
from pathlib import Path
from pypdf import PdfReader

folder = Path(sys.argv[1])
results = {}
for name in ("threaded.pdf", "threaded-redo.pdf"):
    reader = PdfReader(folder / name, strict=True)
    annotations = reader.pages[0]["/Annots"]
    page_refs = {(ref.idnum, ref.generation) for ref in annotations}
    links = []
    for ref in annotations:
        annotation = ref.get_object()
        if "/IRT" not in annotation:
            continue
        parent = annotation.raw_get("/IRT")
        assert (parent.idnum, parent.generation) in page_refs
        assert parent.get_object()["/Subtype"] != "/Popup"
        assert annotation["/RT"] == "/R"
        assert "/NM" in annotation and "/NM" in parent.get_object()
        links.append({"child": annotation["/Contents"], "parent": parent.get_object()["/Contents"]})
    assert len(links) == 3
    assert {item["child"] for item in links} == {"First reply", "Nested reply", "Sibling reply"}
    assert next(item for item in links if item["child"] == "Nested reply")["parent"] == "First reply"
    assert "Deerstalker keeps document text." in reader.pages[0].extract_text()
    results[name] = links
(folder / "independent-check.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
if (folder / "independent-output.pdf").exists():
    reader = PdfReader(folder / "independent-output.pdf", strict=True)
    refs = reader.pages[0]["/Annots"]
    parent = next(ref for ref in refs if ref.get_object().get("/Contents") == "Independent parent")
    assert parent.get_object()["/NM"] == "부모 (검토) \\ 1"
    children = [ref.get_object() for ref in refs if "/IRT" in ref.get_object()]
    assert len(children) == 2
    assert all(child.raw_get("/IRT") == parent for child in children)
print("Independent pypdf checks passed: actual parent references, names, reply type and page text.")
