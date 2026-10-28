"""Stage portable Markdown and canonical artwork, then build with Zensical."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def build(workspace, output):
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-beta\.\d+)?", version):
        raise ValueError("Use a valid package version for the website download.")
    for path in (workspace, output):
        if path == ROOT or path.is_relative_to(ROOT) or ROOT.is_relative_to(path):
            raise ValueError("Keep generated files outside the source checkout.")
    if output.exists():
        raise ValueError("Choose a new site output directory.")
    workspace.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="remile-docs-", dir=workspace) as temporary:
        stage = Path(temporary)
        docs = stage / "docs"
        shutil.copytree(ROOT / "docs", docs)
        (docs / "README.md").rename(docs / "overview.md")
        shutil.copy2(ROOT / "CHANGELOG.md", docs / "changelog.md")
        shutil.copytree(ROOT / "others/brand", docs / "assets/brand")
        shutil.copytree(ROOT / "others/symbols/guide", docs / "assets/controls", ignore=shutil.ignore_patterns("*.md"))
        shutil.copytree(ROOT / "tools/docs/overrides", stage / "tools/docs/overrides")
        for source in (ROOT / "docs").rglob("*.md"):
            target = docs / ("overview.md" if source.name == "README.md" and source.parent == ROOT / "docs" else source.relative_to(ROOT / "docs"))

            def link(match):
                value = match.group(2)
                if "://" in value or value.startswith(("#", "mailto:")):
                    return match.group(0)
                path, separator, fragment = value.partition("#")
                original = (source.parent / path).resolve()
                suffix = separator + fragment
                if original == ROOT / "docs/README.md":
                    return match.group(1) + os.path.relpath(docs / "overview.md", target.parent) + suffix
                if original.is_relative_to(ROOT / "others/brand"):
                    asset = docs / "assets/brand" / original.relative_to(ROOT / "others/brand")
                    return match.group(1) + os.path.relpath(asset, target.parent) + suffix
                if original.is_relative_to(ROOT / "others/symbols/guide"):
                    asset = docs / "assets/controls" / original.relative_to(ROOT / "others/symbols/guide")
                    return match.group(1) + os.path.relpath(asset, target.parent) + suffix
                if original.is_relative_to(ROOT) and not original.is_relative_to(ROOT / "docs"):
                    return match.group(1) + "https://github.com/PentagonToy/remile/blob/main/" + str(original.relative_to(ROOT)) + suffix
                return match.group(0)

            rendered = re.sub(r'''(\]\(|src=["']|srcset=["'])([^"'\s)>]+)''', link, source.read_text())
            if source == ROOT / "docs/index.md":
                rendered = rendered.replace("---\n", f'---\nrelease_version: "{version}"\n', 1)
            target.write_text(rendered)
        shutil.copy2(ROOT / "zensical.toml", stage / "zensical.toml")
        subprocess.run([sys.executable, "-m", "zensical", "build", "--strict", "-f", str(stage / "zensical.toml")], cwd=stage, check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(stage / "site", output)
        (output / ".nojekyll").touch()
    print(f"Built {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--site-dir", required=True, type=Path)
    args = parser.parse_args()
    build(args.workspace.resolve(), args.site_dir.resolve())
