"""Build a scoped, non-production live cleanup trial from the compiled bundle."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "dist" / "ee-dcs.lua"
OUT = Path(__file__).resolve().parent / "cleanup-trial.lua"
META = Path(__file__).resolve().parent / "payload.json"
NAMES = (
    "lualib_bundle",
    "sides",
    "campaign_state",
    "airbase_clearance",
    "airbase_cleanup",
)


def main() -> None:
    text = SOURCE.read_text(encoding="utf-8")
    pattern = re.compile(r'^\["([^"]+)"\] = function\(\.\.\.\)\s*$', re.M)
    matches = list(pattern.finditer(text))
    assert matches and matches[0].group(1) == "lualib_bundle"
    modules = {
        match.group(1): text[match.start() : matches[i + 1].start()]
        for i, match in enumerate(matches[:-1])
    }
    assert all(name in modules for name in NAMES)
    prefix = text[: matches[0].start()]
    assert prefix.count("____modules = {") == 2
    assert "require(\"index\"" not in prefix

    old = "_DMT_GEN = (_DMT_GEN or 0) + 1"
    replacement = 'assert(_DMT_GEN == ____trialGeneration, "generation changed during trial load")'
    assert modules["campaign_state"].count(old) == 1
    modules["campaign_state"] = modules["campaign_state"].replace(old, replacement)
    assert all(modules[name].rstrip().endswith("end,") for name in NAMES)

    allowed = set(NAMES)
    for name in NAMES:
        # Only unindented requires execute while loading these factories. The
        # campaign_state helper functions contain dormant imports (for example
        # imap) that cleanup never calls.
        dependencies = set(re.findall(r'^local [^\n]*require\("([^"]+)"\)', modules[name], re.M))
        assert dependencies <= allowed, (name, dependencies - allowed)
    assembled = (
        'local ____trialGeneration = assert(_DMT_GEN, "campaign generation missing")\n'
        + prefix
        + "".join(modules[name] for name in NAMES)
        + """}
assert(_DMT_GEN == ____trialGeneration, "generation changed before trial schedule")
assert(_G.__airbase_clearance_trial_scheduled == nil, "cleanup trial already scheduled")
local cleanup = require("airbase_cleanup")
assert(_DMT_GEN == ____trialGeneration, "generation changed while loading cleanup")
_G.__airbase_clearance_trial_scheduled = { generation = ____trialGeneration, at = timer.getTime() }
cleanup.schedule(function(message) env.info("[cleanup_live_trial] " .. message) end)
return { generation = _DMT_GEN, scheduled_at = _G.__airbase_clearance_trial_scheduled.at }
"""
    )
    assert 'require("main")' not in assembled
    assert 'require("index")' not in assembled
    assert 'require("reset")' not in assembled
    assert old not in assembled
    OUT.write_text(assembled, encoding="utf-8", newline="\n")
    digest = hashlib.sha256(assembled.encode("utf-8")).hexdigest()
    META.write_text(
        json.dumps(
            {
                "note": "Scoped live-trial payload; NOT the production bundle",
                "source": str(SOURCE),
                "source_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
                "payload": OUT.name,
                "payload_sha256": digest,
                "adaptation": f"single compiled assignment {old!r} replaced by {replacement!r}",
                "modules": NAMES,
                "bytes": len(assembled.encode("utf-8")),
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    print(f"payload bytes={len(assembled.encode('utf-8'))} sha256={digest}")


if __name__ == "__main__":
    main()
