#!/usr/bin/env python3
"""ADR-032 dogfood harness — out-of-tree dependency routing against
real rust-analyzer and gopls.

The gleeunit suite covers the *decision* (which workspace
`resolve_workspace` picks) but structurally cannot cover the thing the
ADR actually claims: that routing a registry-crate file to the owning
project's session produces a better answer from a real language server.
Step 1 already killed option A on exactly that distinction — TypeScript
rooted correctly and still answered wrongly — so "the routing works" is
not the same finding as "the defect is fixed."

Nine cells, all hard pass/fail on pharos behaviour, plus one OBSERVE
row (5b) carrying the raw counts behind cell 5.

Cell 5 asserts the ADR's actual claim and is the reason this harness
exists: routing must produce references in the project's own files,
which a session rooted in the dependency structurally cannot return.
An earlier revision compared TOTAL reference counts instead and read a
correct result as a failure — the floored session sees the crate's own
tests and examples, so it returns more references while containing
none the agent asked for.

    Cell 1  rust cold start floors to the registry crate (no hard error)
    Cell 2  rust warm call routes to the project session
    Cell 3  routed find_references carries no dependency-scope note
    Cell 4  floored find_references DOES carry the note
    Cell 5  routed answer reaches first-party files the floor cannot
    Cell 5b OBSERVE — reference-set shape behind cell 5
    Cell 6  `dependency_cache_fragments = []` in toml disables routing
    Cell 7  go cold start floors to the module cache
    Cell 8  go warm call routes to the project session
    Cell 9  two live workspaces floor rather than hard-erroring (opt-in)

Each batch spawns a FRESH pharos. That is load-bearing, not tidiness:
the pool keeps sessions warm across calls, so a cold-start cell sharing
a process with a warm one silently tests the warm path twice.

Fixtures: defaults to `tmp/fixtures/{rust,go}` from
`bin/dogfood-fixtures.sh`, because the tier-1 `~/rust_dev` / `~/go_dev`
workspaces have no dependencies and therefore nothing in either cache.

Usage:
    bin/dogfood-fixtures.sh rust go        # once, if not already cloned
    python3 bin/dogfood-adr-032.py
    python3 bin/dogfood-adr-032.py --rust-project ~/some/smaller/crate
    python3 bin/dogfood-adr-032.py --second-rust-project ~/other_rust  # enables cell 9
    python3 bin/dogfood-adr-032.py --skip-on-missing   # quiet exit if prereqs absent

Exit codes:
    0   all hard cells passed
    1   one or more hard cells failed
    2   setup failure (missing LSP, project, or dependency source)

⚠ This reads your real `CARGO_HOME/registry/src` and `GOPATH/pkg/mod`.
Read-only — it opens dependency sources and asks questions about them.
It never writes to, clears, or rebuilds either cache.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pharos_drive import (  # noqa: E402
    drive_serial,
    find_response,
    initialize_request,
    tool_call_request,
    tool_is_error,
    tool_text,
)

# rust-analyzer cold start on a real project is 30-60s and gopls can
# stall on a first module load. Generous, because a timeout here reads
# as a routing failure and is not one.
PER_REQ_TIMEOUT_S = 180

# The substring `session.attribution_note` emits for a dependency-rooted
# answer. Matching prose is brittle by nature; this is the load-bearing
# clause and changing it should break this harness on purpose.
DEP_NOTE_MARKER = "inside a dependency directory"

INITIALIZED = {"jsonrpc": "2.0", "method": "notifications/initialized"}

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The handle-2 fixtures, not the `~/rust_dev` / `~/go_dev` workspaces the
# tier-1 harness uses. Those two are dependency-free — no Cargo.lock
# entries beyond themselves, no `require` block — so nothing of theirs
# is ever in the registry or module cache and every cell here would
# report setup failure. The cloned fixtures are real projects with real
# dependency trees, which is the whole premise.
#
# The cost is indexing: rust-analyzer on rust-lang/cargo is minutes of
# cold start, repeated per batch because each batch needs a fresh
# process. Point `--rust-project` at any smaller rust project with
# dependencies if you would rather trade breadth for wall-clock.
DEFAULT_RUST_PROJECT = os.path.join(PROJECT_ROOT, "tmp", "fixtures", "rust")
DEFAULT_GO_PROJECT = os.path.join(PROJECT_ROOT, "tmp", "fixtures", "go")


# -- fixture discovery ----------------------------------------------------


def cargo_home() -> str:
    return os.environ.get("CARGO_HOME") or os.path.expanduser("~/.cargo")


def gopath() -> str:
    return os.environ.get("GOPATH") or os.path.expanduser("~/go")


def first_source_file(project: str, suffix: str, preferred: tuple) -> str | None:
    """A first-party file to warm the project session with. Prefers the
    conventional entry points, falls back to any matching file."""
    for rel in preferred:
        candidate = os.path.join(project, rel)
        if os.path.isfile(candidate):
            return candidate
    for root, dirs, files in os.walk(project):
        dirs[:] = [
            d for d in dirs if d not in ("target", "vendor", ".git", "node_modules")
        ]
        for name in sorted(files):
            # `build.rs` is a build script — rust-analyzer treats it as
            # its own thing and warming on it does not reliably root a
            # session at the project the way an ordinary source file does.
            if name == "build.rs" or name.endswith("_test.go"):
                continue
            if name.endswith(suffix):
                return os.path.join(root, name)
    return None


def direct_dependency_names(project: str) -> list:
    """Crate names from the project's own `[dependencies]` table.

    Direct-vs-transitive is load-bearing for cell 5, not a nicety. A
    transitive crate is in the build graph but nothing in the project
    names its symbols, so `find_references` from one correctly returns
    zero project hits whether routing worked or not — the cell then
    measures nothing. The first run of this harness did exactly that.
    """
    manifest = os.path.join(project, "Cargo.toml")
    if not os.path.isfile(manifest):
        return []
    with open(manifest, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    names = []
    # `[dependencies]` only — dev- and build-dependencies are not in the
    # crate graph rust-analyzer answers ordinary queries from.
    for block in re.findall(
        r"^\[dependencies\]\n(.*?)(?=^\[|\Z)", text, re.MULTILINE | re.DOTALL
    ):
        for line in block.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r'^([\w-]+)\s*=', line)
            if m:
                names.append(m.group(1))
    return names


def rust_dependency_source(project: str) -> str | None:
    """A `lib.rs` inside the registry cache belonging to a crate this
    project actually depends on.

    Restricting to the project's own dependency set matters: a random
    crate from the cache would not be in the project session's crate
    graph, so routing to it would prove nothing about whether the
    routed session can answer better.

    Direct dependencies are tried first, in manifest order, and only
    then the rest of the lockfile. Both are in the crate graph, so
    either satisfies cells 1-4 and 6; only a direct one gives cell 5 a
    symbol the project might actually reference.
    """
    lock = os.path.join(project, "Cargo.lock")
    if not os.path.isfile(lock):
        return None
    with open(lock, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    packages = re.findall(
        r'\[\[package\]\]\nname = "([^"]+)"\nversion = "([^"]+)"', text
    )
    direct = direct_dependency_names(project)
    ordered = sorted(
        packages, key=lambda pv: direct.index(pv[0]) if pv[0] in direct else len(direct)
    )
    registry_src = os.path.join(cargo_home(), "registry", "src")
    fallback = None
    for name, version in ordered:
        # Per-crate, not the project-wide identifier bag: only names the
        # project imports from THIS crate can anchor a meaningful query.
        wanted = crate_referenced_names(project, name)
        for crate_dir in sorted(
            glob.glob(os.path.join(registry_src, "*", f"{name}-{version}"))
        ):
            hit = defining_source_file(crate_dir, wanted)
            if hit:
                return hit
            lib = os.path.join(crate_dir, "src", "lib.rs")
            # Skip trivially small shims — they yield symbol-free
            # document_symbols responses and no anchor for cell 3-5.
            if fallback is None and os.path.isfile(lib) and os.path.getsize(lib) > 2000:
                fallback = lib
    return fallback


def defining_source_file(crate_dir: str, prefer_names: set) -> str | None:
    """The crate file that DEFINES a symbol the project names.

    `src/lib.rs` is the obvious pick and frequently the wrong one: the
    common Rust layout makes it module wiring plus `pub use`
    re-exports, so its only own symbols are crate-private macros. hecs
    is exactly this — `World` lives in `world.rs` — and anchoring on
    its lib.rs gives cell 5 nothing a dependent could reference, which
    is indistinguishable from routing having failed.

    Re-exports are not enough: `document_symbols` reports what a file
    declares, so the anchor has to sit at the definition.
    """
    if not prefer_names:
        return None
    src_dir = os.path.join(crate_dir, "src")
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs if d not in ("tests", "benches", "examples")]
        for fname in sorted(files):
            if not fname.endswith(".rs"):
                continue
            path = os.path.join(root, fname)
            if os.path.getsize(path) <= 2000:
                continue
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            for defined in re.findall(
                r"^pub (?:struct|enum|trait|fn) ([A-Za-z_][A-Za-z0-9_]*)",
                text,
                re.MULTILINE,
            ):
                if defined in prefer_names:
                    return path
    return None


def escape_module_path(module: str) -> str:
    """Go's module cache lowercases uppercase letters and prefixes them
    with `!` (github.com/BurntSushi → github.com/!burnt!sushi)."""
    out = []
    for ch in module:
        if ch.isupper():
            out.append("!" + ch.lower())
        else:
            out.append(ch)
    return "".join(out)


def go_dependency_source(project: str) -> str | None:
    """A `.go` file inside the module cache belonging to a module this
    project requires. Same crate-graph reasoning as the rust side."""
    gomod = os.path.join(project, "go.mod")
    if not os.path.isfile(gomod):
        return None
    with open(gomod, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    requires = re.findall(r"^\s*([\w./\-~]+)\s+(v[\w.\-+]+)", text, re.MULTILINE)
    mod_root = os.path.join(gopath(), "pkg", "mod")
    for module, version in requires:
        if module in ("go", "module", "require", "toolchain"):
            continue
        dep_dir = os.path.join(mod_root, escape_module_path(module) + "@" + version)
        if not os.path.isdir(dep_dir):
            continue
        for root, dirs, files in os.walk(dep_dir):
            dirs[:] = [d for d in dirs if d not in ("testdata", "internal", ".git")]
            for name in sorted(files):
                if name.endswith(".go") and not name.endswith("_test.go"):
                    path = os.path.join(root, name)
                    if os.path.getsize(path) > 2000:
                        return path
    return None


# -- response readers -----------------------------------------------------


def uri(path: str) -> str:
    return "file://" + path


def parse_json_text(response) -> object | None:
    """Tool payloads are JSON in the first content block. The
    attribution note, when present, is a SECOND text block — so parsing
    the joined text would fail exactly when a note fires. Read block one
    on its own."""
    if not response or "result" not in response:
        return None
    content = response["result"].get("content", [])
    for block in content:
        if block.get("type") != "text":
            continue
        try:
            return json.loads(block.get("text", ""))
        except json.JSONDecodeError:
            continue
    return None


def sessions_for(response, language: str) -> list:
    """`runtime_server_capabilities` entries for one language, each
    carrying the `workspace` that session is rooted at.

    Only **Ready** sessions are listed. Every batch here asks for
    capabilities after the LSP-bound call has already responded, so a
    session that served a request is necessarily Ready by then — an
    empty list means no session was created, not a race."""
    parsed = parse_json_text(response)
    if not isinstance(parsed, dict):
        return []
    entries = parsed.get("sessions", parsed.get("entries", []))
    if not isinstance(entries, list):
        return []
    return [e for e in entries if e.get("language") == language]


def project_identifiers(project: str, suffix: str) -> set:
    """Identifiers that appear anywhere in the project's own sources.

    Used only to RANK anchor candidates, never to filter them: an
    anchor the project mentions makes cell 5's question well-posed
    ("does routing widen the answer for a symbol this project uses?"),
    while an anchor it never mentions makes 0-vs-0 unfalsifiable. The
    ranking cannot manufacture a pass — routing still has to return the
    project's references for the cell to observe widening.
    """
    names = set()
    budget = 400  # files; enough to characterise a project, bounded for big ones
    for root, dirs, files in os.walk(project):
        dirs[:] = [
            d for d in dirs if d not in ("target", "vendor", ".git", "node_modules")
        ]
        for fname in files:
            if not fname.endswith(suffix):
                continue
            budget -= 1
            if budget < 0:
                return names
            try:
                with open(os.path.join(root, fname), encoding="utf-8", errors="replace") as fh:
                    names.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", fh.read()))
            except OSError:
                continue
    return names


def crate_name_from_dep_path(dep_path: str) -> str:
    """`.../registry/src/<index>/hecs-0.10.5/src/world.rs` -> `hecs`."""
    parts = os.path.abspath(dep_path).split(os.sep)
    for part in reversed(parts):
        if re.match(r"^[A-Za-z0-9_-]+-\d+\.\d+", part):
            return re.sub(r"-\d+\.\d+.*$", "", part)
    return ""


def crate_referenced_names(project: str, crate: str) -> set:
    """Symbols the project imports FROM this specific crate.

    A bag of every identifier in the project is too coarse to pick an
    anchor with: hecs defines `View`, and any project with a camera
    also contains the word "View", so an unrelated crate file scores a
    false match. Matching `hecs::World` and `use hecs::{...}` instead
    ties the anchor to a symbol the project genuinely depends on.
    """
    if not crate:
        return set()
    mod = crate.replace("-", "_")
    names = set()
    budget = 400
    for root, dirs, files in os.walk(project):
        dirs[:] = [
            d for d in dirs if d not in ("target", "vendor", ".git", "node_modules")
        ]
        for fname in files:
            if not fname.endswith(".rs"):
                continue
            budget -= 1
            if budget < 0:
                return names
            try:
                with open(os.path.join(root, fname), encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            # `use hecs::{World, Entity};` / `use hecs::World;`
            for group in re.findall(rf"use\s+{mod}::(\{{[^}}]*\}}|[A-Za-z_][A-Za-z0-9_]*)", text):
                names.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", group))
            # bare path use: `hecs::World::new()`
            names.update(re.findall(rf"{mod}::([A-Za-z_][A-Za-z0-9_]*)", text))
    names.discard("self")
    names.discard("crate")
    return names


# DocumentSymbol kinds worth anchoring on: class, method, interface,
# function, struct. A module or variable anchor tends to yield an empty
# reference set for reasons unrelated to routing.
ANCHOR_KINDS = (5, 6, 11, 12, 23)
MODULE_KIND = 2


def anchor_from_symbols(response, prefer_names: set | None = None) -> tuple | None:
    """A `(line, character, name)` to anchor find_references on, taken
    from a real declaration in the dependency file.

    Two rules earned by a bad run. The first pass of this harness
    anchored on `fn assert_all` inside aho-corasick's `mod testoibits`
    and reported "no widening" — a test-only helper has no downstream
    references by construction, so the cell measured nothing.

      * Test modules are pruned. Their symbols are unreferencable from
        outside the crate, so a zero from one says nothing about
        routing.
      * Symbols the project mentions rank first, then shallower ones
        (a crate's top-level exports are what a dependent names).

    Handles both response shapes: hierarchical DocumentSymbol[]
    (selectionRange) and flat SymbolInformation[] (location.range).
    """
    parsed = parse_json_text(response)
    if not isinstance(parsed, list):
        return None
    prefer = prefer_names or set()
    candidates = []  # (rank, order, line, char, name)
    fallback = []

    def position(node):
        rng = node.get("selectionRange") or node.get("location", {}).get("range")
        if not rng:
            return None
        start = rng.get("start", {})
        if start.get("line") is None:
            return None
        return (start["line"], start.get("character", 0))

    def walk(nodes, depth):
        for node in nodes:
            if not isinstance(node, dict):
                continue
            name = node.get("name", "") or ""
            kind = node.get("kind")
            # `#[cfg(test)]` is invisible over LSP; the module name is
            # the only signal available, and it is a reliable one.
            if kind == MODULE_KIND and "test" in name.lower():
                continue
            pos = position(node)
            if pos:
                if kind in ANCHOR_KINDS and not name.startswith("_"):
                    candidates.append(
                        (0 if name in prefer else 1, depth, len(candidates), pos, name)
                    )
                else:
                    fallback.append((pos, name))
            walk(node.get("children", []) or [], depth + 1)

    walk(parsed, 0)
    if candidates:
        candidates.sort(key=lambda c: (c[0], c[1], c[2]))
        _, _, _, pos, name = candidates[0]
        return (pos[0], pos[1], name)
    if fallback:
        pos, name = fallback[0]
        return (pos[0], pos[1], name)
    return None


def reference_count(response) -> int | None:
    parsed = parse_json_text(response)
    if isinstance(parsed, list):
        return len(parsed)
    if isinstance(parsed, dict) and isinstance(parsed.get("locations"), list):
        return len(parsed["locations"])
    return None


def first_party_references(response, project: str) -> int:
    """References that land in the project's OWN files.

    This, not the total count, is what ADR-032 claims. A floored
    session rooted at the dependency reports every use inside that
    crate — tests and examples included — so it routinely returns MORE
    references than a routed one while containing zero the agent asked
    about. Step 1's probe used exactly this criterion ("at least one
    reference in a first-party file"); comparing totals instead reads a
    correct routing result as a failure.
    """
    parsed = parse_json_text(response)
    if isinstance(parsed, dict):
        parsed = parsed.get("locations", [])
    if not isinstance(parsed, list):
        return 0
    root = os.path.abspath(project)
    return sum(
        1
        for loc in parsed
        if isinstance(loc, dict)
        and loc.get("uri", "").replace("file://", "").startswith(root)
    )


def has_dependency_note(response) -> bool:
    return DEP_NOTE_MARKER in tool_text(response)


def path_is_under(path: str, *segments: str) -> bool:
    probe = (path or "") + "/"
    return all(seg in probe for seg in segments)


# -- batches --------------------------------------------------------------


def batch_cold(dep_path: str):
    """Fresh pharos, first call anchored in the dependency cache. No
    project session exists to route to, so this must floor."""
    return [
        initialize_request(rid=1),
        INITIALIZED,
        tool_call_request(rid=10, name="document_symbols", arguments={"uri": uri(dep_path)}),
        tool_call_request(rid=11, name="runtime_server_capabilities", arguments={}),
    ]


def batch_warm(project_file: str, dep_path: str, anchor):
    """Fresh pharos, first-party call FIRST so a project session is
    Ready, then the dependency-anchored call that should route to it."""
    requests = [
        initialize_request(rid=1),
        INITIALIZED,
        tool_call_request(
            rid=20, name="document_symbols", arguments={"uri": uri(project_file)}
        ),
    ]
    if anchor:
        requests.append(
            tool_call_request(
                rid=21,
                name="find_references",
                arguments={
                    "uri": uri(dep_path),
                    "line": anchor[0],
                    "character": anchor[1],
                    "include_declaration": True,
                },
            )
        )
    else:
        requests.append(
            tool_call_request(
                rid=21, name="document_symbols", arguments={"uri": uri(dep_path)}
            )
        )
    requests.append(
        tool_call_request(rid=22, name="runtime_server_capabilities", arguments={})
    )
    return requests


def batch_floor_references(dep_path: str, anchor):
    """Fresh pharos, dependency-anchored find_references with nothing
    warm — the floor, for the cell 5 comparison."""
    return [
        initialize_request(rid=1),
        INITIALIZED,
        tool_call_request(
            rid=30,
            name="find_references",
            arguments={
                "uri": uri(dep_path),
                "line": anchor[0],
                "character": anchor[1],
                "include_declaration": True,
            },
        ),
    ]


def batch_two_workspaces(project_a: str, project_b: str, dep_path: str):
    return [
        initialize_request(rid=1),
        INITIALIZED,
        tool_call_request(rid=40, name="document_symbols", arguments={"uri": uri(project_a)}),
        tool_call_request(rid=41, name="document_symbols", arguments={"uri": uri(project_b)}),
        tool_call_request(rid=42, name="document_symbols", arguments={"uri": uri(dep_path)}),
        tool_call_request(rid=43, name="runtime_server_capabilities", arguments={}),
    ]


# -- runner ---------------------------------------------------------------


class Results:
    def __init__(self):
        self.rows = []
        self.failures = 0

    def hard(self, name, passed, detail):
        self.rows.append(("PASS" if passed else "FAIL", name, detail))
        if not passed:
            self.failures += 1

    def observe(self, name, detail):
        self.rows.append(("OBSERVE", name, detail))

    def skip(self, name, detail):
        self.rows.append(("SKIP", name, detail))

    def report(self):
        print("", file=sys.stderr)
        print("DOGFOOD — ADR-032 out-of-tree dependency routing", file=sys.stderr)
        for marker, name, detail in self.rows:
            print(f"  [{marker:7}] {name}", file=sys.stderr)
            print(f"            {detail}", file=sys.stderr)
        print("", file=sys.stderr)
        if self.failures:
            print(f"== {self.failures} CELL(S) FAILED ==", file=sys.stderr)
        else:
            print("== ALL HARD CELLS PASSED ==", file=sys.stderr)
        print(
            "Cell 5 is the ADR's claim: the routed answer must reach files the "
            "floored session cannot see. Totals are NOT the metric — a floor "
            "rooted in the dependency legitimately returns more references, all "
            "of them inside that dependency.",
            file=sys.stderr,
        )


def run_language_cells(
    results, language, project_file, dep_path, cache_segments, cells,
    prefer_names=None,
):
    """Cold-floor + warm-route, the two cells every probed language gets.

    Returns the warm batch's responses so language-specific extra cells
    can read them without re-driving.
    """
    cold_cell, warm_cell = cells

    print(f"== {language}: cold start (fresh pharos, dep-anchored) ==", file=sys.stderr)
    cold, _ = drive_serial(
        env_overrides={},
        requests=batch_cold(dep_path),
        per_request_timeout=PER_REQ_TIMEOUT_S,
    )
    dep_call = find_response(cold, 10)
    caps = find_response(cold, 11)
    if tool_is_error(dep_call):
        results.hard(cold_cell, False, "dep-anchored call hard-errored: " + tool_text(dep_call)[:200])
    else:
        rooted = [
            s for s in sessions_for(caps, language)
            if path_is_under(s.get("workspace", ""), *cache_segments)
        ]
        results.hard(
            cold_cell,
            bool(rooted),
            (
                f"floored at {rooted[0].get('workspace')}"
                if rooted
                else "expected a session rooted in the cache; got "
                + str([s.get("workspace") for s in sessions_for(caps, language)])
            ),
        )

    anchor = anchor_from_symbols(dep_call, prefer_names)
    if anchor:
        print(f"   anchor: {anchor[2]} @ {anchor[0]}:{anchor[1]}", file=sys.stderr)

    print(f"== {language}: warm (project session first, then dep) ==", file=sys.stderr)
    warm, _ = drive_serial(
        env_overrides={},
        requests=batch_warm(project_file, dep_path, anchor),
        per_request_timeout=PER_REQ_TIMEOUT_S,
    )
    warm_caps = find_response(warm, 22)
    live = sessions_for(warm_caps, language)
    cache_rooted = [
        s for s in live if path_is_under(s.get("workspace", ""), *cache_segments)
    ]
    results.hard(
        warm_cell,
        len(live) == 1 and not cache_rooted,
        (
            f"single session at {live[0].get('workspace')} — dep call routed to it"
            if len(live) == 1 and not cache_rooted
            else "expected one project-rooted session; got "
            + str([s.get("workspace") for s in live])
        ),
    )
    return warm, anchor


def check_prereqs(args, results):
    missing = []
    if not shutil.which("rust-analyzer"):
        missing.append("rust-analyzer not on PATH")
    if not shutil.which("gopls"):
        missing.append("gopls not on PATH")
    if not os.path.isdir(args.rust_project):
        missing.append(
            f"rust project missing: {args.rust_project} — "
            "run `bin/dogfood-fixtures.sh rust go`"
        )
    if not os.path.isdir(args.go_project):
        missing.append(
            f"go project missing: {args.go_project} — "
            "run `bin/dogfood-fixtures.sh rust go`"
        )
    if missing:
        for m in missing:
            print(("SKIPPED: " if args.skip_on_missing else "FAIL setup: ") + m, file=sys.stderr)
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--rust-project", default=DEFAULT_RUST_PROJECT)
    parser.add_argument("--go-project", default=DEFAULT_GO_PROJECT)
    parser.add_argument(
        "--second-rust-project",
        default=None,
        help="A second rust project. Enables cell 9 (ambiguity floors).",
    )
    parser.add_argument("--skip-on-missing", action="store_true")
    args = parser.parse_args()

    if not check_prereqs(args, None):
        return 0 if args.skip_on_missing else 2

    rust_file = first_source_file(args.rust_project, ".rs", ("src/main.rs", "src/lib.rs"))
    go_file = first_source_file(args.go_project, ".go", ("main.go",))
    rust_dep = rust_dependency_source(args.rust_project)
    go_dep = go_dependency_source(args.go_project)

    setup_problems = []
    if not rust_file:
        setup_problems.append(f"no .rs file under {args.rust_project}")
    if not go_file:
        setup_problems.append(f"no .go file under {args.go_project}")
    if not rust_dep:
        setup_problems.append(
            "no registry source for any Cargo.lock dependency under "
            + os.path.join(cargo_home(), "registry", "src")
            + " — run `cargo fetch` in the project first"
        )
    if not go_dep:
        setup_problems.append(
            "no module-cache source for any go.mod requirement under "
            + os.path.join(gopath(), "pkg", "mod")
            + " — run `go mod download` in the project first"
        )
    if setup_problems:
        for p in setup_problems:
            print(("SKIPPED: " if args.skip_on_missing else "FAIL setup: ") + p, file=sys.stderr)
        return 0 if args.skip_on_missing else 2

    print("rust project :", args.rust_project, file=sys.stderr)
    print("rust dep     :", rust_dep, file=sys.stderr)
    print("go project   :", args.go_project, file=sys.stderr)
    print("go dep       :", go_dep, file=sys.stderr)

    results = Results()

    # -- rust: cells 1 + 2, plus the reference-scope cells 3-5 ------------
    warm, anchor = run_language_cells(
        results,
        "rust",
        rust_file,
        rust_dep,
        ("/registry/src/",),
        (
            "1. rust cold start floors to the registry crate",
            "2. rust warm call routes to the project session",
        ),
        prefer_names=crate_referenced_names(
            args.rust_project, crate_name_from_dep_path(rust_dep)
        )
        or project_identifiers(args.rust_project, ".rs"),
    )

    if anchor is None:
        results.skip(
            "3-5. reference-scope cells",
            "no anchorable symbol in the dependency file; document_symbols "
            "returned nothing usable",
        )
    else:
        routed_refs = find_response(warm, 21)
        results.hard(
            "3. routed find_references carries no dependency-scope note",
            not has_dependency_note(routed_refs),
            "no note — the answer came from a project-rooted session"
            if not has_dependency_note(routed_refs)
            else "note fired on a routed answer, so it did NOT route",
        )

        print("== rust: floored find_references (fresh pharos) ==", file=sys.stderr)
        floored, _ = drive_serial(
            env_overrides={},
            requests=batch_floor_references(rust_dep, anchor),
            per_request_timeout=PER_REQ_TIMEOUT_S,
        )
        floor_refs = find_response(floored, 30)
        results.hard(
            "4. floored find_references DOES carry the note",
            has_dependency_note(floor_refs),
            "note fired on the floor, as attribution intends"
            if has_dependency_note(floor_refs)
            else "no note on a dependency-rooted answer — attribution regressed",
        )

        routed_n = reference_count(routed_refs)
        floor_n = reference_count(floor_refs)
        routed_fp = first_party_references(routed_refs, args.rust_project)
        floor_fp = first_party_references(floor_refs, args.rust_project)
        results.hard(
            "5. routed answer reaches first-party files the floor cannot",
            routed_fp > 0 and floor_fp == 0,
            f"routed found {routed_fp} reference(s) in the project, floored "
            f"found {floor_fp} — routing answers the question the agent asked"
            if routed_fp > 0 and floor_fp == 0
            else f"routed first-party={routed_fp} floored first-party={floor_fp}. "
            "Expected >0 routed and 0 floored; a routed answer with no "
            "first-party hits is the failure mode that killed option A and "
            "is the finding to record.",
        )
        results.observe(
            "5b. reference-set shape",
            f"routed={routed_n} ({routed_fp} first-party) "
            f"floored={floor_n} ({floor_fp} first-party) at "
            f"{os.path.basename(rust_dep)}:{anchor[0]}:{anchor[1]} "
            f"(`{anchor[2]}`, direct dep, non-test). The floor returning MORE "
            "total references is expected — it sees the crate's own tests and "
            "examples — and is why totals are not the metric.",
        )

    # -- cell 6: the config key is live in a real spawn -------------------
    print("== rust: routing disabled via PHAROS_CONFIG_FILE ==", file=sys.stderr)
    with tempfile.NamedTemporaryFile(
        "w", suffix=".toml", prefix="pharos-adr032-", delete=False
    ) as fh:
        fh.write("[languages.rust]\ndependency_cache_fragments = []\n")
        override_path = fh.name
    try:
        disabled, _ = drive_serial(
            env_overrides={"PHAROS_CONFIG_FILE": override_path},
            requests=batch_warm(rust_file, rust_dep, None),
            per_request_timeout=PER_REQ_TIMEOUT_S,
        )
        caps = find_response(disabled, 22)
        cache_rooted = [
            s for s in sessions_for(caps, "rust")
            if path_is_under(s.get("workspace", ""), "/registry/src/")
        ]
        results.hard(
            "6. `dependency_cache_fragments = []` disables routing",
            bool(cache_rooted),
            "registry-rooted session appeared, so the toml key reached the "
            "resolver in a real spawn"
            if cache_rooted
            else "still routed with the key emptied — the override never "
            "reached registry.merge_one, or the key name is wrong",
        )
    finally:
        os.unlink(override_path)

    # -- go: cells 7 + 8 --------------------------------------------------
    run_language_cells(
        results,
        "go",
        go_file,
        go_dep,
        ("/pkg/mod/",),
        (
            "7. go cold start floors to the module cache",
            "8. go warm call routes to the project session",
        ),
        prefer_names=project_identifiers(args.go_project, ".go"),
    )

    # -- cell 9: ambiguity floors, never hard-errors ----------------------
    if not args.second_rust_project:
        results.skip(
            "9. two live workspaces floor rather than erroring",
            "pass --second-rust-project <path> to enable",
        )
    elif not os.path.isdir(args.second_rust_project):
        results.skip(
            "9. two live workspaces floor rather than erroring",
            f"missing: {args.second_rust_project}",
        )
    else:
        second_file = first_source_file(
            args.second_rust_project, ".rs", ("src/main.rs", "src/lib.rs")
        )
        if not second_file:
            results.skip(
                "9. two live workspaces floor rather than erroring",
                f"no .rs file under {args.second_rust_project}",
            )
        else:
            print("== rust: two live workspaces ==", file=sys.stderr)
            ambiguous, _ = drive_serial(
                env_overrides={},
                requests=batch_two_workspaces(rust_file, second_file, rust_dep),
                per_request_timeout=PER_REQ_TIMEOUT_S,
            )
            dep_call = find_response(ambiguous, 42)
            caps = find_response(ambiguous, 43)
            cache_rooted = [
                s for s in sessions_for(caps, "rust")
                if path_is_under(s.get("workspace", ""), "/registry/src/")
            ]
            results.hard(
                "9. two live workspaces floor rather than erroring",
                not tool_is_error(dep_call) and bool(cache_rooted),
                "floored to the crate with no hard error, per constraint 3"
                if not tool_is_error(dep_call) and cache_rooted
                else "expected a degraded floor; got error="
                + str(tool_is_error(dep_call))
                + " roots="
                + str([s.get("workspace") for s in sessions_for(caps, "rust")]),
            )

    results.report()
    return 1 if results.failures else 0


if __name__ == "__main__":
    sys.exit(main())
