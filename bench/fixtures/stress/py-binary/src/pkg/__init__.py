"""Tiny package — Phase 4 stress fixture (py-binary).

The asset/ subdir contains a non-text binary file; pharos's file
walker must not choke on it when scanning for symbol-name matches.
"""

from .core import Engine, run_default

__all__ = ["Engine", "run_default"]
