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
  STUB_LSP_LOG=path           append "<pid> <method>" for every message
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
                              without the `version` field

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
import sys
import time


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


def write_message(stream, msg):
    body = json.dumps(msg).encode("utf-8")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
    stream.write(body)
    stream.flush()


def handle_initialize(req):
    delay = int(os.environ.get("STUB_LSP_INIT_DELAY_MS", "0")) / 1000.0
    if delay:
        time.sleep(delay)
    if os.environ.get("STUB_LSP_FAIL_HANDSHAKE") == "1":
        return None
    capabilities = {
        "hoverProvider": True,
        "documentSymbolProvider": True,
    }
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


def sha8(text):
    import hashlib
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:8]


def sync_log_suffix(method, params):
    doc = params.get("textDocument") or {}
    name = os.path.basename(doc.get("uri", ""))
    return (" " + name if name else "") + sync_log_detail(method, params, doc)


def sync_log_detail(method, params, doc):
    if method == "textDocument/didOpen":
        return " v=%s sha=%s" % (doc.get("version"), sha8(doc.get("text", "")))
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


def maybe_publish(stdout, uri):
    mode = os.environ.get("STUB_LSP_DIAGNOSTICS", "")
    if not mode or uri not in DOCS:
        return
    doc = DOCS[uri]
    diagnostics = [
        {
            "range": {"start": {"line": i, "character": 0},
                      "end": {"line": i, "character": len(line)}},
            "severity": 1,
            "source": "stub",
            "message": "stub error on line %d" % i,
        }
        for i, line in enumerate(doc["text"].split("\n")) if "ERROR" in line
    ]
    if mode == "push-suppress" and LAST_PUBLISHED.get(uri) == diagnostics:
        return
    LAST_PUBLISHED[uri] = diagnostics
    params = {"uri": uri, "diagnostics": diagnostics}
    if mode != "push-versionless":
        params["version"] = doc["version"]
    write_message(stdout, {"jsonrpc": "2.0",
                           "method": "textDocument/publishDiagnostics",
                           "params": params})


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
                    pid_param = (msg.get("params") or {}).get("processId")
                    log.write(f"{os.getpid()} {method} processId={pid_param}\n")
                else:
                    suffix = sync_log_suffix(method, msg.get("params") or {})
                    log.write(f"{os.getpid()} {method}{suffix}\n")
        if method == "initialize":
            resp = handle_initialize(msg)
            if resp is not None:
                write_message(stdout, resp)
        elif method == "initialized":
            # notification, no reply
            continue
        elif method == "shutdown":
            write_message(stdout, {"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            return
        elif method in ("textDocument/didOpen", "textDocument/didChange"):
            uri = apply_sync(method, msg.get("params") or {})
            maybe_publish(stdout, uri)
        elif method == "textDocument/didClose":
            apply_sync(method, msg.get("params") or {})
        elif method == "textDocument/didSave":
            continue
        elif method == "textDocument/hover":
            resp = handle_hover(msg)
            write_message(stdout, resp)
        elif method == "$/cancelRequest":
            continue
        else:
            # Unknown method — return method-not-found if it has an id.
            if "id" in msg:
                write_message(stdout, {
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "error": {"code": -32601, "message": f"stub_lsp: unknown method {method}"},
                })


if __name__ == "__main__":
    main()
