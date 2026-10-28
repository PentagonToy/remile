"""Check generated pages for broken local links, assets and fragment targets."""
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids, self.links = set(), []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if attributes.get("id"):
            self.ids.add(attributes["id"])
        for key in ("href", "src"):
            if attributes.get(key):
                self.links.append(attributes[key])


def check(root):
    pages = {path.resolve(): Page(path) for path in root.rglob("*.html")}
    failures = []
    version = (Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()
    home = pages.get((root / "index.html").resolve())
    download = f"https://github.com/PentagonToy/remile/releases/download/v{version}/remile-{version}-arm64.dmg"
    if home is None or download not in home.links:
        failures.append("Homepage download must match VERSION.")
    count = 0
    for source, page in pages.items():
        for link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            path = unquote(url.path)
            if path.startswith("/remile/"):
                destination = (root / path.removeprefix("/remile/")).resolve()
            else:
                destination = (source.parent / path).resolve() if path else source
            if destination.is_dir():
                destination /= "index.html"
            count += 1
            if not destination.is_relative_to(root) or not destination.is_file():
                failures.append(f"{source.relative_to(root)}: missing {link}")
            elif url.fragment and destination.suffix == ".html" and unquote(url.fragment) not in pages[destination].ids:
                failures.append(f"{source.relative_to(root)}: missing fragment {link}")
    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Checked {len(pages)} pages and {count} local links/assets.")


if __name__ == "__main__":
    check(Path(sys.argv[1]).resolve())
