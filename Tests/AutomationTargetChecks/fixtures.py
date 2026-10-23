from pathlib import Path
from zipfile import ZipFile
import sys
root = Path(sys.argv[1])
with ZipFile(root / "source.zip") as source:
    files = {name: source.read(name) for name in source.namelist()}
with ZipFile(root / "nested.zip", "w") as target:
    for name, data in files.items():
        target.writestr("Wrapped/" + name, data)
    target.writestr("__MACOSX/._Wrapped", b"Finder metadata")
with ZipFile(root / "broken.zip", "w") as target:
    for name, data in files.items():
        target.writestr(name, data.replace(b"\\documentclass", b"documentclass") if name == "main.tex" else data)
