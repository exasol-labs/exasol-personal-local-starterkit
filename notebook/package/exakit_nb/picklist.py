"""The kit's dropdown for the notebooks' code paths: one widget, the guided cards' look, in JupyterLab and Marimo.

    pick = PickList([("category", "category", "A short list of repeated values"), ...], value="category",
                    description="REGION", note="120 distinct values")
    pick.value                      # what is picked now (JupyterLab: the widget itself; Marimo: wrap it)
    element = mo.ui.anywidget(pick)  # in Marimo: element.value["value"] is the pick

The list opens in place under the button, inside the cell, so it never covers the page; a long list has a box to
narrow it, and an option can carry a second line saying what it is. ``options`` are (label, value) or (label, value,
hint) tuples, or {"label", "value", "hint"} dicts - the shapes ipywidgets.Dropdown and mo.ui.dropdown take.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import anywidget
import traitlets

__all__ = ["PickList", "pick_options"]

STATIC = Path(__file__).parent / "static"


def pick_options(options) -> list[dict[str, Any]]:
    """Options as the widget holds them: [{"label", "value", "hint"}], from tuples, dicts or a {label: value} map."""
    if isinstance(options, dict):
        options = list(options.items())
    out = []
    for o in options:
        if isinstance(o, dict):
            out.append({"label": str(o.get("label", o.get("value"))), "value": o.get("value"), "hint": o.get("hint") or ""})
        elif isinstance(o, (tuple, list)):
            out.append({"label": str(o[0]), "value": o[1] if len(o) > 1 else o[0], "hint": (o[2] if len(o) > 2 else "") or ""})
        else:
            out.append({"label": str(o), "value": o, "hint": ""})
    return out


class PickList(anywidget.AnyWidget):
    """A dropdown with the kit's look: ``value`` is the picked option's value (None allowed)."""

    _esm = STATIC / "picklist.js"
    _css = STATIC / "picklist.css"
    options = traitlets.List().tag(sync=True)
    value = traitlets.Any(None, allow_none=True).tag(sync=True)
    description = traitlets.Unicode("").tag(sync=True)
    note = traitlets.Unicode("").tag(sync=True)
    placeholder = traitlets.Unicode("").tag(sync=True)

    def __init__(self, options=(), value=None, description: str = "", note: str = "", placeholder: str = "", **kwargs):
        kwargs.pop("style", None)          # ipywidgets.Dropdown's layout argument: not used here
        super().__init__(options=pick_options(options), value=value, description=description, note=note,
                         placeholder=placeholder, **kwargs)
