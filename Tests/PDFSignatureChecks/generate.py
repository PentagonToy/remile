"""Generate disposable, self-signed CMS fixtures. Never use or install a user's certificate."""
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
openssl = shutil.which("openssl")
if not openssl:
    raise SystemExit("OpenSSL is required for the detached-signature fixture")
key, cert = root / "fixture-key.pem", root / "fixture-cert.pem"
subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-keyout", str(key), "-out", str(cert), "-sha256", "-days", "1", "-nodes", "-subj", "/CN=remile disposable test signer"], check=True, capture_output=True)
for permission in (0, 1, 2, 3):
    perms = f"/Perms << /DocMDP 7 0 R >>" if permission else ""
    transform = f"/Reference [<< /Type /SigRef /TransformMethod /DocMDP /TransformParams << /Type /TransformParams /P {permission} /V /1.2 >> >>]" if permission else ""
    text = b"BT /F1 16 Tf 72 700 Td (Signed annotation fixture) Tj ET"
    objects = [
        f"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] /SigFlags 3 >> {perms} >>".encode(),
        b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 8 0 R /Annots [6 0 R] >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 8 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Type /Annot /Subtype /Widget /FT /Sig /T (FixtureSignature) /Rect [0 0 0 0] /P 3 0 R /V 7 0 R >>",
        (f"<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached {transform} /ByteRange [" + " ".join(["0" * 12] * 4) + "] /Contents <" + "0" * 32768 + "> >>").encode(),
        f"<< /Length {len(text)} >>\nstream\n".encode() + text + b"\nendstream",
    ]
    data, offsets = bytearray(b"%PDF-1.4\n"), [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(data)); data.extend(f"{number} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Root 1 0 R /Size {len(objects)+1} >>\nstartxref\n{xref}\n%%EOF\n".encode())
    start = data.index(b"/Contents <") + len(b"/Contents ")
    end = start + 32770
    marker = " ".join(["0" * 12] * 4).encode()
    ranges = (0, start, end, len(data)-end)
    data = data.replace(marker, " ".join(f"{value:012}" for value in ranges).encode(), 1)
    payload = root / "signed-payload.bin"
    payload.write_bytes(data[:start] + data[end:])
    signature = root / "fixture-signature.der"
    subprocess.run([openssl, "cms", "-sign", "-binary", "-in", str(payload), "-signer", str(cert), "-inkey", str(key), "-outform", "DER", "-out", str(signature), "-md", "sha256", "-nosmimecap"], check=True, capture_output=True)
    cms = signature.read_bytes().hex().encode()
    assert len(cms) <= 32768
    data[start+1:end-1] = cms.ljust(32768, b"0")
    (root / f"signed-p{permission}.pdf").write_bytes(data)
print("Generated approval and DocMDP P=1/2/3 fixtures with a disposable self-signed certificate.")

damaged = bytearray((root / "signed-p3.pdf").read_bytes())
position = damaged.index(b"Signed annotation fixture")
damaged[position] = ord("X")
(root / "damaged.pdf").write_bytes(damaged)
