"""Let LLM Wiki's API store files over the private network and sign browser links with the public address.

Upstream's S3Service uses one endpoint for everything: on AWS the same host serves the API and browsers. Here
the API reaches storage at its private address, and browsers and the converter at its public domain. Railway's
edge does not complete S3 uploads (botocore's `Expect: 100-continue` PUTs stall), and the private network is
faster and free of egress, so the API reads and writes privately and only the two signing methods use
LLMWIKI_S3_PUBLIC_ENDPOINT. Signing makes no network call.

Applied at image build time; the build fails if upstream's methods no longer match.
"""

import sys
from pathlib import Path

REPLACEMENTS = [
    (
        '''    async def generate_presigned_get(self, key: str, expires_in: int = 3600) -> str:
        async with self._session.client("s3") as s3:''',
        '''    async def generate_presigned_get(self, key: str, expires_in: int = 3600) -> str:
        # llmwiki-railway: links are for browsers and the converter, so they carry the public address.
        async with self._session.client("s3", endpoint_url=os.environ.get("LLMWIKI_S3_PUBLIC_ENDPOINT") or None) as s3:''',
    ),
    (
        '''    async def generate_presigned_put(self, key: str, content_type: str = "application/pdf", expires_in: int = 3600) -> str:
        async with self._session.client("s3") as s3:''',
        '''    async def generate_presigned_put(self, key: str, content_type: str = "application/pdf", expires_in: int = 3600) -> str:
        # llmwiki-railway: links are for browsers and the converter, so they carry the public address.
        async with self._session.client("s3", endpoint_url=os.environ.get("LLMWIKI_S3_PUBLIC_ENDPOINT") or None) as s3:''',
    ),
]

path = Path(sys.argv[1])
source = path.read_text()
for old, new in REPLACEMENTS:
    if source.count(old) != 1:
        sys.exit("patch_s3_presign: upstream's S3Service changed; review the patch before building")
    source = source.replace(old, new)
if "\nimport os\n" not in source:
    source = source.replace("import json\n", "import json\nimport os\n", 1)
    if "\nimport os\n" not in source:
        sys.exit("patch_s3_presign: could not add `import os`")
path.write_text(source)
print("patch_s3_presign: applied")
