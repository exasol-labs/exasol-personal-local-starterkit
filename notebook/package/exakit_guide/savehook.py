"""Jupyter save hook: don't save guided-view cards into the notebook file.

A guided card is a live widget. It only exists while its kernel runs, so a saved
copy of it reopens as "Error displaying widget: model not found". Before a
notebook is written, this clears the outputs of guided-view cells only (cells that
use exakit_guide or %%ask). The open tab keeps its cards; the kit's own records
(approvals, answers, hand-off bundle) are untouched. Other cells and notebooks
are saved exactly as before.

Enabled as a server extension by etc/jupyter/jupyter_server_config.d/exakit_guide.json in the kit's
notebook environment:
    {"ServerApp": {"jpserver_extensions": {"exakit_guide.savehook": true}}}
Delete that file (and restart JupyterLab) to turn it off.
"""

from __future__ import annotations

import re

GUIDED_CELL = re.compile(r"^\s*%%ask\b|\bexakit_guide\b|\bguide\.(start|home|understand|explore|ask|share)\(", re.M)


def _source(cell) -> str:
    src = cell.get("source", "")
    return "".join(src) if isinstance(src, list) else str(src)


def strip_guided_outputs(model=None, **_kwargs):
    try:
        if not model or model.get("type") != "notebook":
            return
        nb = model.get("content") or {}
        for cell in nb.get("cells") or []:
            if cell.get("cell_type") == "code" and cell.get("outputs") and GUIDED_CELL.search(_source(cell)):
                cell["outputs"] = []
                cell["execution_count"] = None
    except Exception:
        pass   # never block a save


# -- loaded as a Jupyter server extension -------------------------------------------------------
# The kit starts JupyterLab with its own --config file, so ContentsManager settings in the usual
# config folders are never read. Server extensions are found separately, so the hook registers itself.
def _jupyter_server_extension_points():
    return [{"module": "exakit_guide.savehook"}]


def _load_jupyter_server_extension(serverapp):
    cm = serverapp.contents_manager
    if hasattr(cm, "register_pre_save_hook"):
        cm.register_pre_save_hook(strip_guided_outputs)
    else:
        cm.pre_save_hook = strip_guided_outputs
    serverapp.log.info("exakit_guide: guided-view card outputs are left out of saved notebooks")
