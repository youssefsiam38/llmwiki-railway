"""Let LLM Wiki's converter fetch documents from the template's own object storage.

The converter downloads each document from a signed URL the API hands it, and refuses any URL that is not
on Amazon S3 -- the check that stops it from being used to fetch arbitrary addresses. This template stores
documents in a bundled S3-compatible service instead, so the check is extended, not removed: when
LLMWIKI_S3_ENDPOINT is set, a URL must have exactly that scheme, host and port, and a path inside the
configured bucket (path-style), and nothing else is accepted -- Amazon included.

Applied at image build time; the build fails if upstream's function no longer matches.
"""

import sys
from pathlib import Path

ANCHOR = '''def _validate_s3_url(url: str) -> None:
    parsed = urlparse(url)
    if not parsed.hostname:
        raise HTTPException(400, "URL has no hostname")
'''

PATCH = ANCHOR + '''    # llmwiki-railway: the template's bundled object storage is the only allowed source.
    _railway_endpoint = os.environ.get("LLMWIKI_S3_ENDPOINT", "").strip().rstrip("/")
    if _railway_endpoint:
        _expected = urlparse(_railway_endpoint)
        if (
            not S3_BUCKET
            or parsed.scheme != _expected.scheme
            or parsed.hostname != _expected.hostname
            or parsed.port != _expected.port
            or parsed.username is not None
            or not parsed.path.startswith(f"/{S3_BUCKET}/")
        ):
            raise HTTPException(400, "URL does not point to the configured S3 bucket")
        return
'''

path = Path(sys.argv[1])
source = path.read_text()
if source.count(ANCHOR) != 1:
    sys.exit("patch_s3_endpoint: upstream's _validate_s3_url changed; review the patch before building")
if "import os\n" not in source:
    sys.exit("patch_s3_endpoint: converter/main.py no longer imports os")
path.write_text(source.replace(ANCHOR, PATCH))
print("patch_s3_endpoint: applied")
