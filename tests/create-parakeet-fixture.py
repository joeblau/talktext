#!/usr/bin/env python3
"""Create tiny, digest-verified assets to exercise bundle assembly in CI."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = Path(__file__).resolve().parent.parent / "TalkText/Sources/TalkText/Resources/parakeet-model.json"
manifest = json.loads(source.read_text())
directory = root / manifest["directory"]
for item in manifest["files"]:
    payload = ("TalkText model fixture: " + item["path"]).encode()
    path = directory / item["path"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    item["size"] = len(payload)
    item["sha256"] = hashlib.sha256(payload).hexdigest()
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
