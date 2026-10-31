#!/usr/bin/env python3
"""Writes Resources/models-manifest.json: for each model, where it comes from (Hugging Face repository at a pinned revision) and the
size and SHA-256 of every file, read from a known-good local copy (the one scripts/setup-models.sh downloads).

Usage:  python3 scripts/make-manifest.py [models folder]      (default: Application Support/Voice It/models)
Run it again only when a pinned revision changes. The app's downloader checks every downloaded file against this list, and
`voice-it-download` plus the downloader tests prove the list matches what the host really serves."""
import hashlib, json, os, sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Library/Application Support/Voice It/models")
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "models-manifest.json")

MODELS = [
    {"id": "speech", "name": "Parakeet TDT 0.6B v2 (speech recognition, Core ML)", "repo": "FluidInference/parakeet-tdt-0.6b-v2-coreml",
     "revision": "ee09c569f73759e6d44c9bd16766f477b2b36d39", "licence": "CC-BY-4.0", "destination": "parakeet-tdt-0.6b-v2"},
    {"id": "cleanup", "name": "Qwen3-4B-Instruct-2507, 4-bit (text cleanup, MLX)", "repo": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
     "revision": "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b", "licence": "Apache-2.0", "destination": "cleanup/Qwen3-4B-Instruct-2507-4bit"},
]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(4 << 20), b""): h.update(chunk)
    return h.hexdigest()

for m in MODELS:
    base = os.path.join(root, m["destination"])
    if not os.path.isdir(base): sys.exit(f"missing {base}: run scripts/setup-models.sh first")
    files = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != ".cache"]          # the downloader's own bookkeeping, not part of the model
        for name in filenames:
            p = os.path.join(dirpath, name)
            if name == ".DS_Store" or name.endswith(".part"): continue
            files.append({"path": os.path.relpath(p, base), "sha256": sha256(p), "size": os.path.getsize(p)})
    m["files"] = sorted(files, key=lambda f: f["path"])
    print(f'{m["id"]}: {len(files)} files, {sum(f["size"] for f in files):,} bytes')

with open(out, "w") as f:
    json.dump({"models": MODELS}, f, indent=2, ensure_ascii=False); f.write("\n")
print("wrote", os.path.normpath(out))
