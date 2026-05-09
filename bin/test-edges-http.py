#!/usr/bin/env python3
"""HTTP twin of test-edges.py — same shape, HTTP transport.

Closes the last coverage gap in the M13 matrix: the edge-case
plumbing (content-modified retry, handshake-delay tolerance, brand-
new language via per-server array) is now exercised under HTTP too.
HTTP serializes per POST while stdio batches, so the per-tool retry
+ readiness paths take a different shape under HTTP — worth
covering even though the boot-time config-merge is transport-
agnostic.
"""

from __future__ import annotations

import importlib.util
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)

_spec = importlib.util.spec_from_file_location(
    "_test_edges", os.path.join(_dir, "test-edges.py")
)
_test_edges = importlib.util.module_from_spec(_spec)
sys.modules["_test_edges"] = _test_edges
_spec.loader.exec_module(_test_edges)

from _pharos_drive_http import drive as _http_drive  # noqa: E402

_test_edges.drive = _http_drive

if __name__ == "__main__":
    sys.exit(_test_edges.main())
