#!/usr/bin/env python3
"""HTTP twin of bin/test-raw.py.

Same shape, HTTP drive."""

from __future__ import annotations

import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)

# Reuse test-raw.py main via importlib-then-monkey-patch.
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "_test_raw", os.path.join(_dir, "test-raw.py")
)
_test_raw = importlib.util.module_from_spec(_spec)
sys.modules["_test_raw"] = _test_raw
_spec.loader.exec_module(_test_raw)

from _pharos_drive_http import drive as _http_drive  # noqa: E402

_test_raw.drive = _http_drive

if __name__ == "__main__":
    sys.exit(_test_raw.main())
