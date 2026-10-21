from pathlib import Path
import subprocess
import sys
import time

repo = Path(sys.argv[1])
out = Path(sys.argv[2])
assert out.is_absolute()
out.mkdir(parents=True, exist_ok=True)
(out / "module-cache").mkdir(exist_ok=True)
fixture = repo / "Tests/MarkdownRemoteImageChecks"
sources = ["Sources/Remile/App/NetworkAccess.swift", "Sources/Remile/Markdown/MathMarkup.swift", "Sources/Remile/Markdown/MarkdownHTML.swift", "Sources/Remile/Markdown/MarkdownRemoteImages.swift"]
(out / "checks.swift").write_text("\n".join((repo / path).read_text() for path in sources) + "\n" + (fixture / "main.swift").read_text())
port = out / "port"
port.unlink(missing_ok=True)
server = subprocess.Popen([sys.executable, str(fixture / "server.py"), str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        if port.exists():
            break
        time.sleep(.02)
    result = subprocess.run(["swift", "-module-cache-path", str(out / "module-cache"), str(out / "checks.swift"), port.read_text()], timeout=120)
    sys.exit(result.returncode)
finally:
    server.terminate()
    server.wait(timeout=5)
