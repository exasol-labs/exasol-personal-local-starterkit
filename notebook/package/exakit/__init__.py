"""The Starter Kit's Python namespace in the notebook environment. ``exakit.nb`` is the notebook helpers:

    import exakit.nb as nb
    conn = nb.connect()

``exakit.nb`` IS the ``exakit_nb`` module (one module under two names, so one remembered statement for show_sql()
whichever name a notebook used); ``import exakit_nb`` keeps working for notebooks written before the rename.
"""

from __future__ import annotations

import importlib
from typing import Any

__all__ = ["nb"]


def __getattr__(name: str) -> Any:
    """``import exakit; exakit.nb`` loads the helpers on first use."""
    if name == "nb":
        return importlib.import_module("exakit.nb")
    raise AttributeError(f"module 'exakit' has no attribute '{name}'")
