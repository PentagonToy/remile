"""Generate isolated import fixtures. No account or user library is read."""
from pathlib import Path
from zipfile import ZipFile
import sys

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
with ZipFile(root / "source.zip", "w") as archive:
    archive.writestr("main.tex", "\\documentclass{article}\n\\begin{document}\nFree project baseline.\n\\end{document}\n")
    archive.writestr("refs.bib", "@article{test,title={Example}}\n")
    archive.writestr("contents/part.tex", "Nested source.\n")
    archive.writestr("images/marker.bin", bytes([0, 1, 2, 255]))
for name, entry in [("traversal", "../escape.tex"), ("git", ".git/config"), ("backslash", "folder\\escape.tex"), ("absolute", "/escape.tex")]:
    with ZipFile(root / (name + ".zip"), "w") as archive:
        archive.writestr(entry, "Unsafe synthetic entry")
