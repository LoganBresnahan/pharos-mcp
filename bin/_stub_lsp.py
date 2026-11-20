#!/usr/bin/env python3
"""Tiny stub LSP for deterministic edge-case testing.

Speaks LSP framing (Content-Length headers + JSON body) on stdio.
Behavior is controlled via env vars:

  STUB_LSP_INIT_DELAY_MS=0   delay before initialize response
  STUB_LSP_HOVER_DELAY_MS=0  delay before each textDocument/hover response
  STUB_LSP_HOVER_RESPONSES=value
                              what to return for hover; either
                              "null" (LSP-null), "panic" (raise), or
                              "content_modified" (return -32801 first
                              call, then real content on retry)
  STUB_LSP_FAIL_HANDSHAKE=0   if 1, never reply to initialize
  STUB_LSP_LOG=path           append "<pid> <method>" for every message;
                              initialize logs "processId=<n> pull=<bool>",
                              whether pull diagnostics were advertised
                              received (proves e.g. that a cancel
                              reached the LSP as $/cancelRequest);
                              initialize also logs its processId
  STUB_LSP_GRANDCHILD=path    at startup, start a long-lived `sleep` in
                              the stub's process group, detached from
                              its stdio, and append its pid to path:
                              the shape of rust-analyzer's in-flight
                              `cargo check`, which outlives the LSP's
                              EOF exit (ADR-037)

STUB_LSP_HOVER_RESPONSES=whoami answers hover with the stub's pid and
the value of STUB_LSP_TAG, so a test can tell which LSP process, started
under which environment, answered (ADR-034 sharing).

Document sync (ADR-038). The stub keeps each open document's text and
version, applies didOpen / didChange / didClose, and logs what it got:

  STUB_LSP_HOVER_RESPONSES=line
                              answer hover with the stub's copy of the
                              hovered line ("line N: <text>"), so a
                              test can tell which text the server holds
  STUB_LSP_SYNC_KIND=1        the advertised TextDocumentSyncKind (0, 1,
                              2), or "omit" to leave textDocumentSync out
  STUB_LSP_SYNC_SAVE=         unset: the number form. Set, the options
                              form with save = "none" (left out),
                              "true", or "text" ({includeText: true})
  STUB_LSP_DIAGNOSTICS=       unset: never publish. "push": publish after
                              every open/change, one diagnostic per line
                              containing ERROR. "push-suppress": the same,
                              but skip a publish whose diagnostics equal
                              the last ones for the file (rust-analyzer's
                              behaviour). "push-versionless": like push,
                              without the `version` field. "push-stale":
                              tsserver's race (ADR-038 F4): on a change,
                              publish the OLD text's diagnostics at once,
                              without a version, and the new ones after
                              STUB_LSP_STALE_DELAY_MS (default 600)

tsserver asked directly (ADR-039). The stub answers
`workspace/executeCommand` for `typescript.tsserverRequest` the way
typescript-language-server forwards it:

  STUB_LSP_TSSERVER=          unset: method not found. "answer":
                              semanticDiagnosticsSync returns one
                              tsserver diagnostic (code 9001) per line
                              of the stub's current text containing
                              ERROR, and one with relatedInformation;
                              the other two requests return []. "fail":
                              an error response, so pharos falls back to
                              the push cache. "slow": answer as "answer",
                              after STUB_LSP_TSSERVER_DELAY_MS (default
                              3000), so a short timeout_ms runs out.
                              "busy": answer as "answer", in order, the
                              way tsserver does, the first request after
                              a didOpen or didChange waiting
                              STUB_LSP_TSSERVER_DELAY_MS for the program
                              update and the rest queued behind it
  STUB_LSP_TSSERVER_PROJECT_DELAY_MS=
                              any mode but "busy": projectInfo answers
                              after this long (the other requests as
                              their mode says)
  STUB_LSP_TSSERVER_PROJECT=  what projectInfo names as the file's
                              project (configFileName); unset: tsserver's
                              "No Project." failure

URIs escaped differently (#16):

  STUB_LSP_URI_STYLE=         unset: publish each URI as pharos sent it.
                              "vscode": re-escape it as vscode-uri does
                              (typescript-language-server; every byte
                              but A-Z a-z 0-9 - . _ ~ / escaped). "rust":
                              as Rust's `url` does (rust-analyzer; sub-
                              delims and : @ left raw). Either way the
                              tsserver requests find the document by its
                              decoded path and name files by plain path,
                              and a didOpen log line ends " uri=<uri>"
Symbols (#21):

  STUB_LSP_WORKSPACE_SYMBOL=  unset: no workspace/symbol. "tsserver":
                              advertise it and answer the way tsserver's
                              navto does, from loaded projects only: an
                              error ("No Project.") while no document is
                              open; then, until a tsserver projectInfo
                              request has loaded the project, every
                              `function <query>` line in the open
                              documents only (tsserver's first navto after
                              a didOpen), and after it, in every file of
                              the open documents' folders. documentSymbol then
                              answers each `function <name>` line of a
                              document (open, or read from disk).
                              "null": workspace/symbol answers null (#26).
                              "all": every file under the open documents'
                              folders, node_modules included, matched
                              case-insensitively, like jdtls (#29)
  STUB_LSP_SYMBOL_PARAMS=1    documentSymbol names functions with a
                              parameter list, "helper(int)", as jdtls does
  STUB_LSP_WORKSPACE_SYMBOL=none  documentSymbol only: no
                              workspaceSymbolProvider, as zls (#28)

Readiness (#12):

  STUB_LSP_PROGRESS=tok:ms    if the client advertised window.workDoneProgress,
                              after `initialized` send
                              window/workDoneProgress/create and a $/progress
                              begin for token `tok`, and its end `ms` later
                              (real servers report progress only to clients
                              that can show it)
  STUB_LSP_EARLY_PUBLISH=path after `initialized`, publish one diagnostic
                              ("early publish") for that file, before any
                              didOpen: cargo check's publish lands that way
  STUB_LSP_EARLY_PUBLISH_SPLIT=path:ms
                              the same publish ("early split publish") in
                              two writes `ms` apart, so its frame straddles
                              pharos's 200 ms readiness read windows (#33;
                              verifier's scenario)

Frames in one read (#25):

  STUB_LSP_PUBLISH_WITH_REPLY=1  write each hover reply and a
                              publishDiagnostics for that file ("published
                              with the reply") in ONE write, so they reach
                              pharos in one read, as zls's often do

A check on save, like rust-analyzer's cargo check (#30):

  STUB_LSP_CHECK_ON_SAVE=ms   publish on didOpen as usual; on didChange
                              republish the LAST check's diagnostics at the
                              new version (stale); on didSave begin progress
                              "stub/check", and `ms` later publish the
                              current text's diagnostics and end it. Needs
                              STUB_LSP_SYNC_SAVE so pharos sends didSave,
                              and the client's window.workDoneProgress
  STUB_LSP_INDEX_DELAY_MS=ms  workspace/symbol answers [] until `ms` after
                              `initialized` (a cold index, #27)
  STUB_LSP_INDEX_PROGRESS=1   with STUB_LSP_INDEX_DELAY_MS: at the first
                              didOpen, begin a progress "stub/index" that
                              ends when the index is ready (clangd's
                              background index starts with the first file)

An error reply with frames behind it (#31):

  STUB_LSP_ERROR_WITH_PUBLISH=code[:split]
                              the FIRST hover answers a JSON-RPC error with
                              `code`, and a publishDiagnostics for that file
                              ("published behind an error") in the same
                              write; with ":split", the publish's last 20
                              bytes come 0.3 s later. Later hovers answer
                              normally

A reply split across a timeout (#33):

  STUB_LSP_SPLIT_FIRST_REPLY=ms
                              write the FIRST hover reply's first half at
                              once and the rest `ms` later (past a short
                              hover timeout_ms); later hovers answer whole

With STUB_LSP_LOG set, didOpen / didChange / didSave / didClose log a
line like "<pid> textDocument/didChange main.stub v=3 changes=1
range=False sha=1a2b3c4d", so a test can check exactly what pharos sent
for which file. Publishes carry the document's current version, the way
rust-analyzer and pyright stamp them.

Used by `bin/test-edges.py` to simulate cold-start races, transport
errors, content-modified races deterministically — without depending
on any real language server's behavior.
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
from urllib.parse import quote, unquote


HOVER_RETRY_STATE: dict[str, int] = {}

# uri -> {"version": int, "text": str}
DOCS: dict[str, dict] = {}
# uri -> the diagnostics last published for it
LAST_PUBLISHED: dict[str, list] = {}


def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        if b":" in line:
            key, _, value = line.partition(b":")
            headers[key.strip().decode().lower()] = value.strip().decode()
    length = int(headers.get("content-length", "0"))
    if length == 0:
        return None
    body = stream.read(length)
    return json.loads(body.decode("utf-8"))


WRITE_LOCK = threading.Lock()

# STUB_LSP_TSSERVER=busy: tsserver's requests, answered in order by one
# worker; PROGRAM_STALE marks a sync the next request has to wait out.
TSSERVER_QUEUE: "queue.Queue[dict]" = queue.Queue()
PROGRAM_STALE = threading.Event()


def tsserver_worker(stdout):
    delay = int(os.environ.get("STUB_LSP_TSSERVER_DELAY_MS", "3000")) / 1000.0
    while True:
        msg = TSSERVER_QUEUE.get()
        if PROGRAM_STALE.is_set():
            PROGRAM_STALE.clear()
            time.sleep(delay)
        write_message(stdout, handle_tsserver_request(msg))


def write_message(stream, msg):
    body = json.dumps(msg).encode("utf-8")
    with WRITE_LOCK:
        stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
        stream.write(body)
        stream.flush()


CLIENT_PROGRESS = threading.Event()
ERRORED_ONCE: list = []
SPLIT_ONCE: list = []


LAST_CHECKED: dict[str, list] = {}


def check_on_save(stdout, method, uri):
    """STUB_LSP_CHECK_ON_SAVE: rust-analyzer's flycheck shape."""
    delay = int(os.environ["STUB_LSP_CHECK_ON_SAVE"]) / 1000.0
    doc = DOCS.get(uri)
    if doc is None:
        return
    if method == "textDocument/didOpen":
        LAST_CHECKED[uri] = stub_diagnostics(doc["text"])
        write_message(stdout, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                               "params": {"uri": uri, "version": doc["version"], "diagnostics": LAST_CHECKED[uri]}})
    elif method == "textDocument/didChange":
        write_message(stdout, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                               "params": {"uri": uri, "version": doc["version"], "diagnostics": LAST_CHECKED.get(uri, [])}})
    elif method == "textDocument/didSave" and CLIENT_PROGRESS.is_set():
        write_message(stdout, {"jsonrpc": "2.0", "method": "$/progress",
                               "params": {"token": "stub/check", "value": {"kind": "begin", "title": "check"}}})

        def finish():
            d = DOCS.get(uri)
            if d is None:
                return
            LAST_CHECKED[uri] = stub_diagnostics(d["text"])
            write_message(stdout, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                                   "params": {"uri": uri, "version": d["version"], "diagnostics": LAST_CHECKED[uri]}})
            write_message(stdout, {"jsonrpc": "2.0", "method": "$/progress",
                                   "params": {"token": "stub/check", "value": {"kind": "end"}}})
        threading.Timer(delay, finish).start()


def after_initialized(stdout):
    spec = os.environ.get("STUB_LSP_PROGRESS", "")
    if spec and CLIENT_PROGRESS.is_set():
        token, _, ms = spec.rpartition(":")
        write_message(stdout, {"jsonrpc": "2.0", "id": "progress-create",
                               "method": "window/workDoneProgress/create", "params": {"token": token}})
        write_message(stdout, {"jsonrpc": "2.0", "method": "$/progress",
                               "params": {"token": token, "value": {"kind": "begin", "title": "Indexing"}}})

        def end():
            write_message(stdout, {"jsonrpc": "2.0", "method": "$/progress",
                                   "params": {"token": token, "value": {"kind": "end"}}})
        threading.Timer(int(ms) / 1000.0, end).start()
    early = os.environ.get("STUB_LSP_EARLY_PUBLISH", "")
    if early:
        write_message(stdout, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                               "params": {"uri": "file://" + early, "diagnostics": [{
                                   "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                                   "severity": 1, "source": "stub", "message": "early publish"}]}})
    split = os.environ.get("STUB_LSP_EARLY_PUBLISH_SPLIT", "")
    if split:
        path, _, ms = split.rpartition(":")
        body = json.dumps({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                           "params": {"uri": "file://" + path, "diagnostics": [{
                               "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                               "severity": 1, "source": "stub", "message": "early split publish"}]}}).encode()
        frame = b"Content-Length: %d\r\n\r\n%s" % (len(body), body)
        half = len(frame) // 2
        with WRITE_LOCK:
            stdout.write(frame[:half])
            stdout.flush()

        def rest():
            with WRITE_LOCK:
                stdout.write(frame[half:])
                stdout.flush()
        late = threading.Timer(int(ms) / 1000.0, rest)
        late.daemon = True
        late.start()


def handle_initialize(req):
    delay = int(os.environ.get("STUB_LSP_INIT_DELAY_MS", "0")) / 1000.0
    if delay:
        time.sleep(delay)
    if os.environ.get("STUB_LSP_FAIL_HANDSHAKE") == "1":
        return None
    caps = (req.get("params") or {}).get("capabilities") or {}
    if (caps.get("window") or {}).get("workDoneProgress"):
        CLIENT_PROGRESS.set()
    capabilities = {
        "hoverProvider": True,
        "documentSymbolProvider": True,
    }
    if os.environ.get("STUB_LSP_WORKSPACE_SYMBOL", "none") != "none":
        capabilities["workspaceSymbolProvider"] = True
    kind = os.environ.get("STUB_LSP_SYNC_KIND", "1")
    save = os.environ.get("STUB_LSP_SYNC_SAVE")
    if kind != "omit":
        if save is None:
            capabilities["textDocumentSync"] = int(kind)
        else:
            options = {"openClose": True, "change": int(kind)}
            if save == "true":
                options["save"] = True
            elif save == "text":
                options["save"] = {"includeText": True}
            capabilities["textDocumentSync"] = options
    return {
        "jsonrpc": "2.0",
        "id": req["id"],
        "result": {
            "capabilities": capabilities,
            "serverInfo": {"name": "stub_lsp", "version": "0.0.1"},
        },
    }


def uri_path(uri):
    return unquote(uri[len("file://"):]) if uri and uri.startswith("file://") else uri


def published_uri(uri):
    """The URI as a server that escapes in STUB_LSP_URI_STYLE would publish it."""
    style = os.environ.get("STUB_LSP_URI_STYLE", "")
    if not style or not uri or not uri.startswith("file://"):
        return uri
    return "file://" + quote(uri_path(uri), safe="/" if style == "vscode" else "/!$&'()*+,;=:@")


def sha8(text):
    import hashlib
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:8]


def sync_log_suffix(method, params):
    if method == "workspace/executeCommand":
        args = params.get("arguments") or []
        if len(args) >= 2 and isinstance(args[1], dict):
            return " %s %s" % (args[0], os.path.basename(args[1].get("file", "")))
        return ""
    doc = params.get("textDocument") or {}
    name = os.path.basename(doc.get("uri", ""))
    return (" " + name if name else "") + sync_log_detail(method, params, doc)


def sync_log_detail(method, params, doc):
    if method == "textDocument/didOpen":
        line = " v=%s sha=%s lang=%s" % (doc.get("version"), sha8(doc.get("text", "")), doc.get("languageId"))
        if os.environ.get("STUB_LSP_URI_STYLE"):
            line += " uri=%s" % doc.get("uri")
        return line
    if method == "textDocument/didChange":
        changes = params.get("contentChanges") or []
        ranged = any("range" in c or "rangeLength" in c for c in changes)
        text = changes[-1].get("text", "") if changes else ""
        return " v=%s changes=%d range=%s sha=%s" % (
            doc.get("version"), len(changes), ranged, sha8(text))
    if method == "textDocument/didSave":
        return " save_text=%s" % ("text" in params)
    return ""


def apply_sync(method, params):
    """Keep the stub's copy of each document. Returns the uri touched."""
    doc = params.get("textDocument") or {}
    uri = doc.get("uri")
    if method == "textDocument/didOpen":
        DOCS[uri] = {"version": doc.get("version"), "text": doc.get("text", "")}
    elif method == "textDocument/didChange":
        changes = params.get("contentChanges") or []
        # Full-content changes only: a change with a range would need
        # applying, and pharos never sends one.
        if len(changes) == 1 and "range" not in changes[0] and uri in DOCS:
            DOCS[uri] = {"version": doc.get("version"), "text": changes[0].get("text", "")}
    elif method == "textDocument/didClose":
        DOCS.pop(uri, None)
        LAST_PUBLISHED.pop(uri, None)
    return uri


def stub_diagnostics(text):
    return [
        {
            "range": {"start": {"line": i, "character": 0},
                      "end": {"line": i, "character": len(line)}},
            "severity": 1,
            "source": "stub",
            "message": "stub error on line %d" % i,
        }
        for i, line in enumerate(text.split("\n")) if "ERROR" in line
    ]


def publish_stale_then_fresh(stdout, uri, old_text):
    """tsserver's race: the set computed for the old text arrives after
    the change, without a version; the right one comes later."""
    write_message(stdout, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                           "params": {"uri": uri, "diagnostics": stub_diagnostics(old_text)}})
    delay = int(os.environ.get("STUB_LSP_STALE_DELAY_MS", "600")) / 1000.0

    def later():
        doc = DOCS.get(uri)
        if doc is not None:
            write_message(stdout, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                                   "params": {"uri": uri, "diagnostics": stub_diagnostics(doc["text"])}})
    threading.Timer(delay, later).start()


def handle_tsserver_request(req):
    """typescript-language-server's `typescript.tsserverRequest`."""
    mode = os.environ.get("STUB_LSP_TSSERVER", "")
    params = req.get("params") or {}
    args = params.get("arguments") or []
    if not mode or params.get("command") != "typescript.tsserverRequest" or len(args) < 2:
        return {"jsonrpc": "2.0", "id": req["id"],
                "error": {"code": -32601, "message": "stub_lsp: no such command"}}
    if mode == "fail":
        return {"jsonrpc": "2.0", "id": req["id"],
                "error": {"code": 1, "message": "stub_lsp: tsserver request failed"}}
    request, file_uri = args[0], (args[1] or {}).get("file")
    if request == "projectInfo":
        PROJECT_LOADED.set()
        project = os.environ.get("STUB_LSP_TSSERVER_PROJECT", "")
        if not project:
            return {"jsonrpc": "2.0", "id": req["id"],
                    "result": {"type": "response", "command": request, "success": False,
                               "message": "No Project."}}
        return {"jsonrpc": "2.0", "id": req["id"],
                "result": {"type": "response", "command": request, "success": True,
                           "body": {"configFileName": project, "languageServiceDisabled": False}}}
    body = []
    doc = DOCS.get(file_uri)
    related_file = file_uri[len("file://"):]
    if os.environ.get("STUB_LSP_URI_STYLE"):
        # typescript-language-server hands tsserver a path, and tsserver
        # names files by path.
        doc = next((d for u, d in DOCS.items() if uri_path(u) == uri_path(file_uri)), None)
        related_file = uri_path(file_uri)
    if doc is None:
        return {"jsonrpc": "2.0", "id": req["id"],
                "result": {"type": "response", "command": request, "success": False,
                           "message": "Could not find file"}}
    if request == "semanticDiagnosticsSync":
        lines = doc["text"].split("\n")
        for i, line in enumerate(lines):
            if "ERROR" in line:
                body.append({"start": {"line": i + 1, "offset": 1},
                             "end": {"line": i + 1, "offset": len(line) + 1},
                             "text": "tsserver error on line %d" % i, "code": 9001,
                             "category": "error",
                             "relatedInformation": [
                                 {"span": {"start": {"line": 1, "offset": 1},
                                           "end": {"line": 1, "offset": 2},
                                           "file": related_file},
                                  "message": "related here", "category": "message",
                                  "code": 9002}]})
    return {"jsonrpc": "2.0", "id": req["id"],
            "result": {"seq": 0, "type": "response", "command": request,
                       "request_seq": 0, "success": True, "body": body}}


def maybe_publish(stdout, uri):
    mode = os.environ.get("STUB_LSP_DIAGNOSTICS", "")
    if not mode or uri not in DOCS or mode == "push-stale":
        return
    doc = DOCS[uri]
    diagnostics = stub_diagnostics(doc["text"])
    if mode == "push-suppress" and LAST_PUBLISHED.get(uri) == diagnostics:
        return
    LAST_PUBLISHED[uri] = diagnostics
    params = {"uri": published_uri(uri), "diagnostics": diagnostics}
    if mode != "push-versionless":
        params["version"] = doc["version"]
    write_message(stdout, {"jsonrpc": "2.0",
                           "method": "textDocument/publishDiagnostics",
                           "params": params})


def function_lines(text):
    """(line, name, line text) for each `function <name>` line."""
    out = []
    for i, line in enumerate(text.split("\n")):
        idx = line.find("function ")
        if idx >= 0:
            name = line[idx + len("function "):].split("(")[0].strip()
            if name:
                out.append((i, name, line))
    return out


PROJECT_LOADED = threading.Event()


INITIALIZED_AT = [0.0]


INDEX_PROGRESS_SENT: list = []


def start_index_progress(stdout):
    left = INITIALIZED_AT[0] + int(os.environ.get("STUB_LSP_INDEX_DELAY_MS", "0")) / 1000.0 - time.time()
    write_message(stdout, {"jsonrpc": "2.0", "id": "index-create",
                           "method": "window/workDoneProgress/create", "params": {"token": "stub/index"}})
    write_message(stdout, {"jsonrpc": "2.0", "method": "$/progress",
                           "params": {"token": "stub/index", "value": {"kind": "begin", "title": "Indexing"}}})

    def end():
        write_message(stdout, {"jsonrpc": "2.0", "method": "$/progress",
                               "params": {"token": "stub/index", "value": {"kind": "end"}}})
    threading.Timer(max(left, 0.0), end).start()


def handle_workspace_symbol(req):
    delay = int(os.environ.get("STUB_LSP_INDEX_DELAY_MS", "0")) / 1000.0
    if delay and time.time() - INITIALIZED_AT[0] < delay:
        # Still indexing: an empty answer, as clangd, HLS and bash-ls give
        # on a cold session (#27).
        return {"jsonrpc": "2.0", "id": req["id"], "result": []}
    mode = os.environ.get("STUB_LSP_WORKSPACE_SYMBOL")
    if mode == "null":
        return {"jsonrpc": "2.0", "id": req["id"], "result": None}
    if mode == "all":
        # jdtls's shape: every file under the open documents' folders,
        # node_modules included, matched case-insensitively.
        query = ((req.get("params") or {}).get("query") or "").lower()
        result = []
        folders = {os.path.dirname(uri_path(u)) for u in DOCS}
        if os.environ.get("STUB_LSP_EXTRA_SYMBOL_DIR"):
            # A library outside the workspace root (a GOROOT, /usr/include).
            folders.add(os.environ["STUB_LSP_EXTRA_SYMBOL_DIR"])
        for folder in folders:
            for dirpath, _, names in os.walk(folder):
                for name in sorted(names):
                    path = os.path.join(dirpath, name)
                    try:
                        text = open(path).read()
                    except (OSError, UnicodeDecodeError):
                        continue
                    for i, fname, line in function_lines(text):
                        if fname.lower() == query:
                            rng = {"start": {"line": i, "character": 0}, "end": {"line": i, "character": len(line)}}
                            result.append({"name": fname, "kind": 12, "location": {"uri": "file://" + path, "range": rng}})
        return {"jsonrpc": "2.0", "id": req["id"], "result": result}
    if not DOCS:
        return {"jsonrpc": "2.0", "id": req["id"],
                "error": {"code": 1, "message": "<syntax> TypeScript Server Error (stub)\nNo Project."}}
    query = (req.get("params") or {}).get("query", "")
    texts = {uri: doc["text"] for uri, doc in DOCS.items()}
    if PROJECT_LOADED.is_set():
        for folder in {os.path.dirname(uri_path(u)) for u in DOCS}:
            for name in sorted(os.listdir(folder)):
                path = os.path.join(folder, name)
                uri = "file://" + path
                if uri not in texts and os.path.isfile(path):
                    try:
                        texts[uri] = open(path).read()
                    except (OSError, UnicodeDecodeError):
                        pass
    result = []
    for uri, text in texts.items():
        for i, name, line in function_lines(text):
            if name == query:
                rng = {"start": {"line": i, "character": 0}, "end": {"line": i, "character": len(line)}}
                result.append({"name": name, "kind": 12, "location": {"uri": uri, "range": rng}})
    return {"jsonrpc": "2.0", "id": req["id"], "result": result}


def handle_document_symbol(req):
    uri = ((req.get("params") or {}).get("textDocument") or {}).get("uri", "")
    doc = DOCS.get(uri)
    text = doc["text"] if doc else None
    if text is None:
        try:
            text = open(uri_path(uri)).read()
        except OSError:
            text = ""
    result = []
    params = os.environ.get("STUB_LSP_SYMBOL_PARAMS")
    for i, name, line in function_lines(text):
        rng = {"start": {"line": i, "character": 0}, "end": {"line": i, "character": len(line)}}
        shown = name + "(int)" if params else name
        result.append({"name": shown, "kind": 12, "range": rng, "selectionRange": rng, "children": []})
    return {"jsonrpc": "2.0", "id": req["id"], "result": result}


def handle_hover(req):
    mode = os.environ.get("STUB_LSP_HOVER_RESPONSES", "")
    delay = int(os.environ.get("STUB_LSP_HOVER_DELAY_MS", "0")) / 1000.0
    if delay:
        time.sleep(delay)
    if mode == "panic":
        # Crash the process — pharos should detect via port DOWN.
        sys.exit(1)
    if mode == "line":
        params = req.get("params") or {}
        uri = (params.get("textDocument") or {}).get("uri")
        line_no = (params.get("position") or {}).get("line", 0)
        lines = DOCS.get(uri, {}).get("text", "").split("\n")
        text = lines[line_no] if line_no < len(lines) else "<no such line>"
        return {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {"contents": {"kind": "plaintext",
                                    "value": "line %d: %s" % (line_no, text)}},
        }
    if mode == "whoami":
        tag = os.environ.get("STUB_LSP_TAG", "")
        return {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {
                "contents": {"kind": "markdown", "value": f"pid={os.getpid()} tag={tag}"},
            },
        }
    if mode == "content_modified":
        attempts = HOVER_RETRY_STATE.get("hover", 0) + 1
        HOVER_RETRY_STATE["hover"] = attempts
        if attempts == 1:
            return {
                "jsonrpc": "2.0",
                "id": req["id"],
                "error": {"code": -32801, "message": "content modified"},
            }
        return {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {
                "contents": {"kind": "markdown", "value": "stub hover (after retry)"},
            },
        }
    return {
        "jsonrpc": "2.0",
        "id": req["id"],
        "result": None,
    }


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    grandchild_log = os.environ.get("STUB_LSP_GRANDCHILD")
    if grandchild_log:
        import subprocess
        child = subprocess.Popen(["sleep", "600"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(grandchild_log, "a") as f:
            f.write(f"{child.pid}\n")
    if os.environ.get("STUB_LSP_TSSERVER") == "busy":
        threading.Thread(target=tsserver_worker, args=(stdout,), daemon=True).start()
    while True:
        try:
            msg = read_message(stdin)
        except Exception:  # noqa: BLE001
            return
        if msg is None:
            return
        method = msg.get("method")
        log_path = os.environ.get("STUB_LSP_LOG")
        if log_path:
            with open(log_path, "a") as log:
                if method == "initialize":
                    init = msg.get("params") or {}
                    pid_param = init.get("processId")
                    td = (init.get("capabilities") or {}).get("textDocument") or {}
                    log.write(f"{os.getpid()} {method} processId={pid_param} pull={'diagnostic' in td}\n")
                else:
                    suffix = sync_log_suffix(method, msg.get("params") or {})
                    log.write(f"{os.getpid()} {method}{suffix}\n")
        if method == "initialize":
            resp = handle_initialize(msg)
            if resp is not None:
                write_message(stdout, resp)
        elif method == "initialized":
            # notification, no reply
            after_initialized(stdout)
            INITIALIZED_AT[0] = time.time()
            continue
        elif method == "shutdown":
            write_message(stdout, {"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            return
        elif method in ("textDocument/didOpen", "textDocument/didChange"):
            if (method == "textDocument/didOpen" and os.environ.get("STUB_LSP_INDEX_PROGRESS")
                    and not INDEX_PROGRESS_SENT):
                INDEX_PROGRESS_SENT.append(True)
                start_index_progress(stdout)
            p = msg.get("params") or {}
            old = DOCS.get((p.get("textDocument") or {}).get("uri"), {}).get("text")
            uri = apply_sync(method, p)
            PROGRAM_STALE.set()
            if os.environ.get("STUB_LSP_DIAGNOSTICS") == "push-stale" and uri in DOCS:
                if method == "textDocument/didChange" and old is not None:
                    publish_stale_then_fresh(stdout, uri, old)
                else:
                    write_message(stdout, {"jsonrpc": "2.0",
                                           "method": "textDocument/publishDiagnostics",
                                           "params": {"uri": uri, "diagnostics": stub_diagnostics(DOCS[uri]["text"])}})
            maybe_publish(stdout, uri)
            if os.environ.get("STUB_LSP_CHECK_ON_SAVE"):
                check_on_save(stdout, method, uri)
        elif method == "textDocument/didClose":
            apply_sync(method, msg.get("params") or {})
        elif method == "textDocument/didSave":
            if os.environ.get("STUB_LSP_CHECK_ON_SAVE"):
                uri = ((msg.get("params") or {}).get("textDocument") or {}).get("uri")
                check_on_save(stdout, method, uri)
            continue
        elif method == "workspace/symbol" and os.environ.get("STUB_LSP_WORKSPACE_SYMBOL", "none") != "none":
            write_message(stdout, handle_workspace_symbol(msg))
        elif method == "textDocument/documentSymbol" and os.environ.get("STUB_LSP_WORKSPACE_SYMBOL"):
            write_message(stdout, handle_document_symbol(msg))
        elif method == "textDocument/hover" and os.environ.get("STUB_LSP_ERROR_WITH_PUBLISH") and not ERRORED_ONCE:
            ERRORED_ONCE.append(True)
            spec = os.environ["STUB_LSP_ERROR_WITH_PUBLISH"]
            code, _, split = spec.partition(":")
            uri = ((msg.get("params") or {}).get("textDocument") or {}).get("uri")
            err = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": int(code), "message": "stub_lsp: error with a publish behind it"}}
            publish = {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                       "params": {"uri": uri, "diagnostics": [{
                           "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                           "severity": 1, "source": "stub", "message": "published behind an error"}]}}
            frames = b"".join(b"Content-Length: %d\r\n\r\n%s" % (len(b), b)
                              for b in (json.dumps(err).encode(), json.dumps(publish).encode()))
            head, tail = (frames[:-20], frames[-20:]) if split == "split" else (frames, b"")
            with WRITE_LOCK:
                stdout.write(head)
                stdout.flush()
            if tail:
                def rest(t=tail):
                    with WRITE_LOCK:
                        stdout.write(t)
                        stdout.flush()
                threading.Timer(0.3, rest).start()
        elif method == "textDocument/hover" and os.environ.get("STUB_LSP_SPLIT_FIRST_REPLY") and not SPLIT_ONCE:
            SPLIT_ONCE.append(True)
            body = json.dumps(handle_hover(msg)).encode()
            frame = b"Content-Length: %d\r\n\r\n%s" % (len(body), body)
            half = len(frame) // 2
            with WRITE_LOCK:
                stdout.write(frame[:half])
                stdout.flush()

            def rest(t=frame[half:]):
                with WRITE_LOCK:
                    stdout.write(t)
                    stdout.flush()
            late = threading.Timer(int(os.environ["STUB_LSP_SPLIT_FIRST_REPLY"]) / 1000.0, rest)
            late.daemon = True
            late.start()
        elif method == "textDocument/hover" and os.environ.get("STUB_LSP_PUBLISH_WITH_REPLY"):
            resp = handle_hover(msg)
            uri = ((msg.get("params") or {}).get("textDocument") or {}).get("uri")
            publish = {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                       "params": {"uri": uri, "diagnostics": [{
                           "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                           "severity": 1, "source": "stub", "message": "published with the reply"}]}}
            frames = b"".join(b"Content-Length: %d\r\n\r\n%s" % (len(b), b)
                              for b in (json.dumps(resp).encode(), json.dumps(publish).encode()))
            with WRITE_LOCK:
                stdout.write(frames)
                stdout.flush()
        elif method == "textDocument/hover":
            resp = handle_hover(msg)
            write_message(stdout, resp)
        elif method == "workspace/executeCommand":
            args = (msg.get("params") or {}).get("arguments") or []
            project_delay = int(os.environ.get("STUB_LSP_TSSERVER_PROJECT_DELAY_MS", "0")) / 1000.0
            if os.environ.get("STUB_LSP_TSSERVER") == "busy":
                TSSERVER_QUEUE.put(msg)
            elif project_delay and args and args[0] == "projectInfo":
                late = threading.Timer(project_delay, lambda m=msg: write_message(
                    stdout, handle_tsserver_request(m)))
                late.daemon = True    # the stub exits with its stdin, not the timer
                late.start()
            elif os.environ.get("STUB_LSP_TSSERVER") == "slow":
                # Answer from a timer thread, so the stub keeps reading:
                # a didChange and push-stale's publishes go on meanwhile.
                delay = int(os.environ.get("STUB_LSP_TSSERVER_DELAY_MS", "3000")) / 1000.0
                threading.Timer(delay, lambda m=msg: write_message(
                    stdout, handle_tsserver_request(m))).start()
            else:
                write_message(stdout, handle_tsserver_request(msg))
        elif method == "$/cancelRequest":
            continue
        else:
            # Unknown method — return method-not-found if it has an id.
            # A message without a method is a reply to one of the stub's
            # own requests (window/workDoneProgress/create): no answer.
            if "id" in msg and method is not None:
                write_message(stdout, {
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "error": {"code": -32601, "message": f"stub_lsp: unknown method {method}"},
                })


if __name__ == "__main__":
    main()
