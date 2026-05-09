#!/usr/bin/env python3
"""HTTP twin of test-chained.py — same shape, HTTP transport."""

from __future__ import annotations

import importlib.util
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)

# Load test-chained.py module via importlib (filename has dash).
_spec = importlib.util.spec_from_file_location(
    "_test_chained", os.path.join(_dir, "test-chained.py")
)
_test_chained = importlib.util.module_from_spec(_spec)
sys.modules["_test_chained"] = _test_chained
_spec.loader.exec_module(_test_chained)

# Swap drive to HTTP.
from _pharos_drive_http import drive as _http_drive  # noqa: E402

_test_chained.drive = _http_drive

if __name__ == "__main__":
    sys.exit(_test_chained.main())
