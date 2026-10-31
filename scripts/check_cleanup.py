#!/usr/bin/env python3
"""Regression check for the cleanup model and prompt.

Runs the samples in fixtures/cleanup (natural ones with the Natural prompt, polished ones with the Polished prompt, exact ones as the rules only) through the real model (offline, in the no-network sandbox), then:
  * HARD CHECKS (exit 1 if any fail): a question is not answered, instructions inside the transcript are not obeyed,
    an already-clean sentence is unchanged, nothing comes back empty.
  * COMPARES every output with fixtures/cleanup/baseline.json and lists what changed (exit 2 if anything did).
  * Prints speed (mean and slowest cleanup) and how many outputs match the hand-written targets exactly.

Usage:  python3 scripts/check_cleanup.py            check against the baseline
        python3 scripts/check_cleanup.py --update   accept the current outputs as the new baseline
Needs a built harness (scripts/build.sh) and the models (scripts/setup-models.sh). Run it after changing the prompt, model or config defaults.
Note the samples are invented and unpunctuated; replace or extend them with real transcripts when you have them."""
import json, os, re, subprocess, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
os.chdir(root)
harness = "build/DerivedData/Build/Products/Release/voice-it-harness"
model = os.path.expanduser("~/Library/Application Support/Voice It/models/cleanup/Qwen3-4B-Instruct-2507-4bit")
baseline_path = "fixtures/cleanup/baseline.json"
for p in (harness, model):
    if not os.path.exists(p):
        sys.exit(f"missing {p}: run scripts/build.sh and scripts/setup-models.sh first")

run = subprocess.run(["sandbox-exec", "-f", "scripts/no-network.sb", harness, "--cleanup", model], capture_output=True, text=True)
if run.returncode != 0:
    sys.exit("harness failed:\n" + run.stdout[-1500:] + run.stderr[-1500:])

results, speeds, exact = {}, [], 0
for block in re.split(r"\n(?=\d\d-)", run.stdout)[1:]:
    head = block.split("\n")[0]
    name = head.split("  [")[0]
    ms = re.search(r"\[(\d+) ms total", head)
    got = re.search(r"  got:    (.*)", block).group(1).strip()
    raw = re.search(r"  raw:    (.*)", block).group(1).strip()
    results[name] = {"raw": raw, "got": got}
    if "[exact style" not in head: speeds.append(int(ms.group(1)) if ms else 0)      # exact samples are the rules only: no model, no timing
    exact += "exact match" in block

def words(s): return re.findall(r"[a-z0-9']+", s.lower())
failures = []
for name, r in results.items():
    if not r["got"]: failures.append(f"{name}: empty output")
for key, why in (("05-", "question was answered instead of cleaned"), ("06-", "instruction was obeyed"), ("14-", "instruction was obeyed")):
    for name, r in results.items():
        if name.startswith(key):
            gw, rw = words(r["got"]), words(r["raw"])
            # Cleaned text may drop or lightly rearrange words but must not bring in new ones.
            new = [w for w in gw if w not in rw]
            if len(new) > max(1, len(gw) // 5): failures.append(f"{name}: {why}: {r['got']!r}")
for name, r in results.items():
    if name.startswith("09-") and r["got"] != r["raw"]: failures.append(f"{name}: an already-clean sentence was changed: {r['got']!r}")

changed = []
if "--update" in sys.argv:
    json.dump({k: v["got"] for k, v in sorted(results.items())}, open(baseline_path, "w"), indent=2, ensure_ascii=False)
    print(f"baseline updated: {len(results)} samples")
elif os.path.exists(baseline_path):
    base = json.load(open(baseline_path))
    for name, r in sorted(results.items()):
        if base.get(name) != r["got"]: changed.append((name, base.get(name), r["got"]))
else:
    print("no baseline yet: run with --update to create one")

print(f"{len(results)} samples | exact matches with the hand-written targets: {exact}/{len(results)} | cleanup mean {sum(speeds)//max(1,len(speeds))} ms, slowest {max(speeds)} ms")
for f in failures: print("HARD CHECK FAILED:", f)
for name, was, now in changed: print(f"CHANGED {name}\n   was: {was}\n   now: {now}")
if not failures and not changed: print("OK: safety checks pass, outputs identical to the baseline")
sys.exit(1 if failures else (2 if changed else 0))
