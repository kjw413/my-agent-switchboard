"""Upstream interop oracle for switchboard-kit.

Usage:
    python upstream_interop.py <upstream_src_dir> <fake_home>

Imports the REAL agent-switchboard code (hierarchy_install, setup, ...) from
<upstream_src_dir> -- nothing from upstream is copied into this repository --
points it at <fake_home> (which must live under %TEMP%), and replays exactly
what `agent-switchboard serve` does on start-up:

    setup.refresh_hierarchy(silent=True)
      -> hierarchy_install.refresh(HierarchyPaths(HOME, BROKER_HOME), ...)
         instruction blocks (CLAUDE.md / AGENTS.md / GEMINI.md),
         the four managed role files, update_hooks(.claude/settings.json), ...

The refresh runs twice with live Codex roles and once more as if the Codex
CLI were absent (the other role-discovery branch).  After every pass it
asserts that the installed kit was left alone.  One line per assertion,
ASCII only (cp949-safe); exit code 0 = all passed, 1 = assertion failed,
2 = setup error.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="ascii", errors="backslashreplace")
    sys.stderr.reconfigure(encoding="ascii", errors="backslashreplace")
except Exception:  # noqa: BLE001
    pass

FAILURES: list[str] = []

# A result string from an upstream writer that means "the file was not written".
QUIET_PREFIXES = ("unchanged", "skipped")
QUIET_MARKER = "left untouched"

# Synthetic `codex debug models` catalog fed through upstream's own role selection.
SYNTHETIC_CODEX_CATALOG = {
    "models": [
        {"slug": "fixture-frontier", "display_name": "Fixture Frontier", "priority": 1, "visibility": "list"},
        {"slug": "fixture-workhorse", "display_name": "Fixture Workhorse", "priority": 2, "visibility": "list"},
        {"slug": "fixture-reader", "display_name": "Fixture Reader", "priority": 3, "visibility": "list"},
    ]
}


def emit(status: str, message: str) -> None:
    print(f"[{status}] {message}", flush=True)


def check(ok: bool, message: str, detail: str = "") -> None:
    if ok:
        emit("PASS", message)
    else:
        FAILURES.append(message)
        emit("FAIL", message + (f" -- {detail}" if detail else ""))


def die(message: str) -> None:
    emit("FAIL", "setup: " + message)
    sys.exit(2)


def is_within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


# ---------------------------------------------------------------- arguments & guards
if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

UPSTREAM = Path(sys.argv[1]).resolve()
FAKE_HOME = Path(sys.argv[2]).resolve()
TEMP_ROOT = Path(tempfile.gettempdir()).resolve()
REAL_HOME = Path(os.environ.get("USERPROFILE") or Path.home()).resolve()
REPO_ROOT = Path(__file__).resolve().parents[2]

if not (UPSTREAM / "hierarchy_install.py").is_file():
    die(f"no hierarchy_install.py in {UPSTREAM}")
if is_within(UPSTREAM, REPO_ROOT):
    die("upstream source must live outside this repository (PolyForm-Noncommercial)")
if not is_within(FAKE_HOME, TEMP_ROOT) or FAKE_HOME == TEMP_ROOT:
    die(f"fake home {FAKE_HOME} is not under %TEMP% ({TEMP_ROOT})")
if FAKE_HOME == REAL_HOME or is_within(REAL_HOME, FAKE_HOME):
    die("fake home must not be (or contain) the real profile")
if not FAKE_HOME.is_dir():
    die(f"fake home {FAKE_HOME} does not exist")

FAKE_BROKER = FAKE_HOME / ".agent-broker"

# Upstream reads Path.home() / AGENT_BROKER_HOME at import time.  These are
# process-local environment changes only (no User/Machine variables).
os.environ["USERPROFILE"] = str(FAKE_HOME)
os.environ["HOME"] = str(FAKE_HOME)
os.environ["AGENT_BROKER_HOME"] = str(FAKE_BROKER)
sys.dont_write_bytecode = True
sys.path.insert(0, str(UPSTREAM))

try:
    import atomic_io  # noqa: E402
    import hierarchy_install  # noqa: E402
    import model_roles  # noqa: E402
    import setup as upstream_setup  # noqa: E402
    import routing_gate  # noqa: E402
    from switchboard_version import BROKER_VERSION  # noqa: E402
except Exception as exc:  # noqa: BLE001
    die(f"cannot import upstream modules from {UPSTREAM}: {type(exc).__name__}: {exc}")

for mod in (atomic_io, hierarchy_install, model_roles, upstream_setup, routing_gate):
    if not is_within(Path(mod.__file__).resolve(), UPSTREAM):
        die(f"module {mod.__name__} was imported from {mod.__file__}, not from {UPSTREAM}")
if Path(upstream_setup.HOME).resolve() != FAKE_HOME:
    die(f"upstream setup.HOME resolved to {upstream_setup.HOME}, not the fake home")
if Path(upstream_setup.BROKER_HOME).resolve() != FAKE_BROKER:
    die(f"upstream setup.BROKER_HOME resolved to {upstream_setup.BROKER_HOME}")
if Path(routing_gate.BROKER_HOME).resolve() != FAKE_BROKER:
    die(f"upstream routing_gate.BROKER_HOME resolved to {routing_gate.BROKER_HOME}")

emit("INFO", f"upstream Agent Switchboard {BROKER_VERSION} from {UPSTREAM}")
emit("INFO", f"fake home {FAKE_HOME}")

# ---------------------------------------------------------------- write guard
WRITES: list[Path] = []
_real_atomic_write_text = atomic_io.atomic_write_text


def guarded_atomic_write_text(path, *args, **kwargs):
    target = Path(path).resolve()
    if not is_within(target, FAKE_HOME):
        raise PermissionError(f"interop oracle refused an upstream write outside the fake home: {target}")
    WRITES.append(target)
    return _real_atomic_write_text(path, *args, **kwargs)


atomic_io.atomic_write_text = guarded_atomic_write_text  # hierarchy_install uses atomic_io.atomic_write_text

# ---------------------------------------------------------------- serve-equivalent refresh
# `serve` runs setup.refresh_hierarchy(silent=True).  Two things in it depend on
# the machine and are pinned here:
#   * _discover_hierarchy_roles() shells out to the real `codex debug models`;
#     we feed the same upstream selection code a synthetic catalog instead, or
#     return the "Codex CLI not found" shape.
#   * FROZEN: an installed broker runs as agent-switchboard.exe, so its hook
#     prefix is "<BROKER_HOME>\agent-switchboard.exe routing-hook".
ROLE_MODE = {"codex": "live"}


def discover_roles_pinned() -> tuple[dict, dict]:
    codex_roles = {"frontier": None, "workhorse": None, "reader": None}
    if ROLE_MODE["codex"] == "live":
        catalog = SYNTHETIC_CODEX_CATALOG
        if hasattr(model_roles, "seed_codex_frontier"):
            catalog = model_roles.seed_codex_frontier(catalog)
        selected = model_roles.select_codex_roles(catalog)
        codex_roles = {
            "frontier": selected.frontier,
            "workhorse": selected.workhorse,
            "reader": selected.reader,
        }
    return codex_roles, model_roles.select_claude_roles()


upstream_setup._discover_hierarchy_roles = discover_roles_pinned
upstream_setup.FROZEN = True
emit("INFO", "hook prefix " + upstream_setup._routing_hook_command_prefix())

PATHS = hierarchy_install.HierarchyPaths(FAKE_HOME, FAKE_BROKER)
INSTRUCTION_TARGETS = {
    "Claude global hierarchy": PATHS.claude_md,
    "Codex global hierarchy": PATHS.codex_agents_md,
    "Gemini global hierarchy": PATHS.gemini_md,
}
ROLE_TARGETS = {
    "Claude Explore role": PATHS.claude_explore,
    "Claude worker role": PATHS.claude_worker,
    "Codex explorer role": PATHS.codex_explorer,
    "Codex worker role": PATHS.codex_worker,
}
PROTECTED = {**INSTRUCTION_TARGETS, **ROLE_TARGETS}
SETTINGS = PATHS.claude_settings
# Files upstream legitimately owns or rewrites; everything else must not move.
UPSTREAM_OWNED = {SETTINGS.resolve(), PATHS.codex_hooks.resolve()}


def rel(path: Path) -> str:
    try:
        return str(Path(path).resolve().relative_to(FAKE_HOME))
    except ValueError:
        return str(path)


def read_bytes(path: Path) -> bytes | None:
    return path.read_bytes() if path.is_file() else None


def tree_snapshot() -> dict[str, bytes]:
    snap: dict[str, bytes] = {}
    for p in sorted(FAKE_HOME.rglob("*")):
        rp = p.resolve()
        if not p.is_file() or is_within(rp, FAKE_BROKER) or rp in UPSTREAM_OWNED:
            continue
        snap[rel(p)] = p.read_bytes()
    return snap


def handler_invocation(handler: object) -> str:
    if not isinstance(handler, dict):
        return ""
    args = handler.get("args") if isinstance(handler.get("args"), list) else []
    return " ".join([str(handler.get("command") or ""), *(str(a) for a in args)])


def session_start_handlers(path: Path) -> tuple[list[dict] | None, str]:
    raw = read_bytes(path)
    if raw is None:
        return None, "settings.json missing"
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except Exception as exc:  # noqa: BLE001
        return None, f"settings.json does not parse: {exc}"
    groups = ((data.get("hooks") or {}) if isinstance(data, dict) else {}).get("SessionStart") or []
    out: list[dict] = []
    for group in groups if isinstance(groups, list) else []:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            out.extend(h for h in group["hooks"] if isinstance(h, dict))
    return out, ""


def kit_handlers(handlers: list[dict]) -> list[dict]:
    return [h for h in handlers if "sync-roles.ps1" in handler_invocation(h).lower()]


def is_quiet(result: str) -> bool:
    return result.startswith(QUIET_PREFIXES) or QUIET_MARKER in result


# ---------------------------------------------------------------- baseline
BASE_TREE = tree_snapshot()
BASE_PROTECTED = {name: read_bytes(path) for name, path in PROTECTED.items()}
base_ss, err = session_start_handlers(SETTINGS)
if base_ss is None:
    die(err)
BASE_KIT = kit_handlers(base_ss)
BASE_FOREIGN_SS = [h for h in base_ss if h not in BASE_KIT]
check(len(BASE_KIT) == 1, "precondition: kit SessionStart handler (sync-roles.ps1) installed exactly once",
      f"found {len(BASE_KIT)}")
for name, path in PROTECTED.items():
    state = "absent" if BASE_PROTECTED[name] is None else f"{len(BASE_PROTECTED[name])} bytes"
    emit("INFO", f"baseline {rel(path)}: {state}")

PASSES = [
    ("refresh#1", "live"),
    ("refresh#2", "live"),
    ("refresh#3 codex-cli-absent", "absent"),
]
settings_after: dict[str, bytes | None] = {}

for label, codex_mode in PASSES:
    ROLE_MODE["codex"] = codex_mode
    WRITES.clear()
    try:
        results = upstream_setup.refresh_hierarchy(silent=True)
    except Exception as exc:  # noqa: BLE001
        check(False, f"{label}: setup.refresh_hierarchy completed", f"{type(exc).__name__}: {exc}")
        continue
    emit("INFO", f"{label}: " + "; ".join(f"{k} = {v}" for k, v in results.items()))

    for name, path in PROTECTED.items():
        result = results.get(name, "<missing result>")
        check(is_quiet(result), f"{label}: {name} writer left the file alone",
              f"upstream returned '{result}'")
        after = read_bytes(path)
        before = BASE_PROTECTED[name]
        if before is None:
            check(after is None, f"{label}: {rel(path)} still absent",
                  f"upstream created it ({len(after or b'')} bytes)")
        else:
            check(after == before, f"{label}: {rel(path)} byte-identical to the installed kit",
                  "content changed" if after is not None else "file deleted")

    protected_resolved = {p.resolve() for p in PROTECTED.values()}
    hit = sorted({rel(p) for p in WRITES if p in protected_resolved})
    check(not hit, f"{label}: upstream issued no atomic write to instruction/role files",
          ", ".join(hit))

    hooks_result = results.get("Claude routing hooks", "<missing result>")
    check(not hooks_result.startswith("ERROR"), f"{label}: update_hooks merged .claude/settings.json",
          f"upstream returned '{hooks_result}'")
    ss, err = session_start_handlers(SETTINGS)
    if ss is None:
        check(False, f"{label}: settings.json still valid JSON", err)
    else:
        kit = kit_handlers(ss)
        check(len(kit) == 1, f"{label}: kit SessionStart handler (sync-roles.ps1) present exactly once",
              f"found {len(kit)}")
        check(kit == BASE_KIT, f"{label}: kit SessionStart handler unchanged (command/args/timeout)",
              json.dumps(kit, ensure_ascii=True))
        foreign = [h for h in ss if h not in kit]
        check(foreign == BASE_FOREIGN_SS, f"{label}: other SessionStart handlers preserved",
              json.dumps(foreign, ensure_ascii=True))
    settings_after[label] = read_bytes(SETTINGS)

    now = tree_snapshot()
    changed = sorted(k for k in set(BASE_TREE) | set(now) if BASE_TREE.get(k) != now.get(k))
    check(not changed, f"{label}: no other home file changed (outside .agent-broker, settings.json, .codex/hooks.json)",
          ", ".join(changed))

if "refresh#1" in settings_after and "refresh#2" in settings_after:
    check(settings_after["refresh#1"] == settings_after["refresh#2"],
          "idempotent: second refresh left .claude/settings.json byte-identical")

atomic_io.atomic_write_text = _real_atomic_write_text

if FAILURES:
    emit("INFO", f"{len(FAILURES)} assertion(s) failed against upstream {BROKER_VERSION}")
    sys.exit(1)
emit("INFO", f"all assertions passed against upstream {BROKER_VERSION}")
sys.exit(0)
