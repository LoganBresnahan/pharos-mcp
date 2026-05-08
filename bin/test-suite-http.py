#!/usr/bin/env python3
"""HTTP twin of bin/test-suite.py.

Loads test-suite.py via importlib (filename has a dash), monkey-patches
the module's `_drive` to point at the HTTP transport's drive function,
then runs `main()`. Same SPECS, same cells, different wire.

Run:
    python3 bin/test-suite-http.py                 # all langs
    python3 bin/test-suite-http.py rust go         # subset
"""

from __future__ import annotations

import importlib.util
import os
import sys

_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _dir)

_spec = importlib.util.spec_from_file_location(
    "_test_suite", os.path.join(_dir, "test-suite.py")
)
_test_suite = importlib.util.module_from_spec(_spec)
# Register before exec — the dataclass decorator looks up
# cls.__module__ in sys.modules at class-definition time. Without
# registration, dataclass sees None and raises.
sys.modules["_test_suite"] = _test_suite
_spec.loader.exec_module(_test_suite)

# Swap drive to HTTP. Same call signature as the stdio drive.
from _pharos_drive_http import drive as _http_drive  # noqa: E402

_test_suite._drive = _http_drive

if __name__ == "__main__":
    sys.exit(_test_suite.main())
