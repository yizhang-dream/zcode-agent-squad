#!/usr/bin/env python3
"""Switch subagent models by time of day (idempotent).

Day window   -> the model reference in ZCODE_DAY_MODEL_REF
Night window -> the model reference in ZCODE_NIGHT_MODEL_REF

Both variables hold a fully qualified "<providerId>/<modelId>" reference
(split on the first "/") and are read only for the window being applied.
Window boundaries come from ZCODE_DAY_START (default 9) and ZCODE_NIGHT_START
(default 23); the current hour counts as night when it is at or after
night-start, or before day-start.

Targets rewritten under <ZCODE_HOME> (default: ~/.zcode):
  * agents/{coder,reviewer,watcher}.md  -> frontmatter `model:` line
    (agent files that are not present are skipped)
  * v2/agents-state.json                -> builtInModelOverrides (written as
    "custom:<providerId>:<modelId>") plus the providerId/modelId pair in
    builtInModelSelectionOverrides and pluginAgentModelSelectionOverrides

Files are written atomically and only when their content actually changes
(nothing is written or logged when a run is a no-op). Every run that changes
something appends one line to <ZCODE_HOME>/logs/model-switch.log.

Usage:
  python model_switch.py [day|night] [--dry-run]

  With no positional argument the mode is derived from the current hour.
  --dry-run prints what would change without touching any file.
  A missing or malformed configuration exits with status 2.
"""

import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

AGENT_NAMES = ["coder", "reviewer", "watcher"]
DEFAULT_ZCODE_HOME = "~/.zcode"
DEFAULT_DAY_START = 9
DEFAULT_NIGHT_START = 23
EXIT_CONFIG = 2


def fail(message):
    """Print a configuration error to stderr and exit with status 2."""
    print(f"model_switch.py: error: {message}", file=sys.stderr)
    raise SystemExit(EXIT_CONFIG)


def zcode_home():
    """Config root: $ZCODE_HOME, falling back to ~/.zcode."""
    return Path(os.environ.get("ZCODE_HOME") or DEFAULT_ZCODE_HOME).expanduser()


def parse_hour(var, default):
    """Read an hour (0-23) from the environment, falling back to default."""
    raw = os.environ.get(var)
    if raw is None or not raw.strip():
        return default
    try:
        hour = int(raw.strip())
    except ValueError:
        hour = None
    if hour is None or not 0 <= hour <= 23:
        fail(f"{var} must be an integer hour between 0 and 23, got: {raw!r}")
    return hour


def resolve_mode(explicit, day_start, night_start):
    """Explicit day/night wins; otherwise derive it from the local hour."""
    if explicit in ("day", "night"):
        return explicit
    hour = time.localtime().tm_hour
    return "night" if (hour >= night_start or hour < day_start) else "day"


def mode_ref(mode):
    """Return (model value, providerId, modelId, legacy 'custom:' value)."""
    var = "ZCODE_DAY_MODEL_REF" if mode == "day" else "ZCODE_NIGHT_MODEL_REF"
    ref = (os.environ.get(var) or "").strip()
    if not ref:
        fail(f"{mode} mode requires {var} (format '<providerId>/<modelId>'), "
             f"but the variable is unset or empty")
    provider_id, sep, model_id = ref.partition("/")
    if not sep or not provider_id or not model_id:
        fail(f"{var} must be '<providerId>/<modelId>', got: {ref!r}")
    return ref, provider_id, model_id, f"custom:{provider_id}:{model_id}"


def atomic_write_text(path, text):
    """Write text to path via a temp file in the same directory, then rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with open(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        Path(tmp).replace(path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def switch_agent_md(agents_dir, ref, dry_run):
    """Rewrite the frontmatter `model:` line of every agent file.

    The optional quotes in the pattern cover both shapes found in the wild:
    template-rendered installs (`model: "provider/model"`) and hand-edited
    files (`model: provider/model`); the existing quoting style is preserved.
    """
    changed = []
    pattern = re.compile(r'(?m)^(model:[ \t]*"?)[^"\r\n]*("?)')
    for name in AGENT_NAMES:
        path = agents_dir / f"{name}.md"
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        updated, count = pattern.subn(lambda m: m.group(1) + ref + m.group(2), text)
        if count and updated != text:
            if not dry_run:
                atomic_write_text(path, updated)
            changed.append(name)
    return changed


def switch_state(state_path, provider_id, model_id, custom, dry_run):
    """Rewrite every model override section of the agent state file."""
    if not state_path.exists():
        return []
    state = json.loads(state_path.read_text(encoding="utf-8"))
    touched = []

    for key, value in (state.get("builtInModelOverrides") or {}).items():
        if value != custom:
            state["builtInModelOverrides"][key] = custom
            touched.append(key)

    for section in ("builtInModelSelectionOverrides", "pluginAgentModelSelectionOverrides"):
        for key, selection in (state.get(section) or {}).items():
            if selection.get("providerId") != provider_id or selection.get("modelId") != model_id:
                selection["providerId"] = provider_id
                selection["modelId"] = model_id
                touched.append(key)

    if touched and not dry_run:
        atomic_write_text(state_path, json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    return touched


def switch(mode, dry_run):
    """Apply one mode; returns the human-readable summary line."""
    ref, provider_id, model_id, custom = mode_ref(mode)
    home = zcode_home()
    agents_dir = home / "agents"
    state_path = home / "v2" / "agents-state.json"

    md_changed = switch_agent_md(agents_dir, ref, dry_run)
    state_touched = switch_state(state_path, provider_id, model_id, custom, dry_run)

    if not any((agents_dir / f"{name}.md").exists() for name in AGENT_NAMES) and not state_path.exists():
        print(f"model_switch.py: warning: nothing to update under {home} "
              f"(no agent file and no {state_path.name}); check ZCODE_HOME",
              file=sys.stderr)

    summary = (f"{time.strftime('%Y-%m-%d %H:%M:%S')} mode={mode} ref={ref} "
               f"md_changed={','.join(md_changed) or '-'} "
               f"state_touched={','.join(state_touched) or '-'}")
    if dry_run:
        summary += " dry_run=1"

    if (md_changed or state_touched) and not dry_run:
        log_path = home / "logs" / "model-switch.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(summary + "\n")
    return summary


def main(argv):
    dry_run = False
    positional = []
    for arg in argv:
        if arg == "--dry-run":
            dry_run = True
        elif arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        elif arg.startswith("-"):
            fail(f"unknown option: {arg} (usage: model_switch.py [day|night] [--dry-run])")
        else:
            positional.append(arg)

    if len(positional) > 1:
        fail("expected at most one positional argument (day|night), got: " + " ".join(positional))
    explicit = positional[0] if positional else None
    if explicit is not None and explicit not in ("day", "night"):
        fail(f"unknown mode: {explicit!r} (expected 'day' or 'night')")

    day_start = parse_hour("ZCODE_DAY_START", DEFAULT_DAY_START)
    night_start = parse_hour("ZCODE_NIGHT_START", DEFAULT_NIGHT_START)
    mode = resolve_mode(explicit, day_start, night_start)

    print(switch(mode, dry_run))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
