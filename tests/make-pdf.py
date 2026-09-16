#!/usr/bin/env python3
"""Write a small, valid, two-page PDF whose pages carry the given text. Test fixture only.

    tests/make-pdf.py OUT.pdf "text on page one" "text on page two"
"""
import sys

out, *pages = sys.argv[1:]
if not pages:
    sys.exit("usage: make-pdf.py OUT.pdf TEXT [TEXT...]")


def esc(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


objects: list[bytes] = []
kids = []
# 1 catalog, 2 pages, 3 font, then (page, content) pairs
objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
objects.append(b"")  # pages, filled below
objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
for text in pages:
    stream = f"BT /F1 18 Tf 72 720 Td ({esc(text)}) Tj ET".encode()
    page_no = len(objects) + 1
    kids.append(f"{page_no} 0 R")
    objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {page_no + 1} 0 R >>".encode())
    objects.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
objects[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(kids)} >>".encode()

body = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = []
for number, obj in enumerate(objects, start=1):
    offsets.append(len(body))
    body += f"{number} 0 obj\n".encode() + obj + b"\nendobj\n"
xref = len(body)
body += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
for off in offsets:
    body += f"{off:010d} 00000 n \n".encode()
body += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
with open(out, "wb") as fh:
    fh.write(body)
