#!/usr/bin/env python3
"""HTTP twin of bin/test-suite-write.py.

Same SPECS, same round-trip apply_workspace_edit semantics — just
HTTP transport for the JSON-RPC delivery.
"""

from __future__ import annotations

import importlib.util
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)

# Load test-suite.py for SPECS.
_ts_spec = importlib.util.spec_from_file_location(
    "_test_suite", os.path.join(_dir, "test-suite.py")
)
_test_suite = importlib.util.module_from_spec(_ts_spec)
sys.modules["_test_suite"] = _test_suite
_ts_spec.loader.exec_module(_test_suite)

# Load test-suite-write.py for run logic.
_tsw_spec = importlib.util.spec_from_file_location(
    "_test_suite_write", os.path.join(_dir, "test-suite-write.py")
)
_test_suite_write = importlib.util.module_from_spec(_tsw_spec)
sys.modules["_test_suite_write"] = _test_suite_write
_tsw_spec.loader.exec_module(_test_suite_write)

# Swap drive to HTTP.
from _pharos_drive_http import drive as _http_drive  # noqa: E402

_test_suite_write.drive = _http_drive

if __name__ == "__main__":
    sys.exit(_test_suite_write.main())
