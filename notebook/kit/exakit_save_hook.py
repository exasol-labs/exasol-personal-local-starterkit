"""What the kit's JupyterLab leaves out of a notebook when it saves it: the output of a guided cell.

A guided cell (tagged ``exakit-guide``) shows a card, which is a live widget: it works only while the kernel that
made it is running. Saved into the file, it comes back as "Error displaying widget: model not found" when the
notebook is opened again, until the cell is run. So its output is not saved: a reopened notebook shows the cell,
ready to run, under its "Start here" line. Any other cell's widget output that could not be shown again is dropped
the same way; everything else (tables, text, charts) is saved as it is.

Loaded by name from the server's configuration (``ContentsManager.pre_save_hook``); it imports nothing but the
standard library, and a notebook it cannot read is saved untouched.
"""

GUIDED = "exakit-guide"
WIDGET = "application/vnd.jupyter.widget-view+json"


def strip_guided(model, **_kwargs):
    """Remove the saved output of guided cells and of live widgets from a notebook about to be written."""
    try:
        if model.get("type") != "notebook":
            return
        for cell in model["content"].get("cells", []):
            if cell.get("cell_type") != "code":
                continue
            outputs = cell.get("outputs") or []
            tagged = GUIDED in ((cell.get("metadata") or {}).get("tags") or [])
            kept = [] if tagged else [o for o in outputs if WIDGET not in (o.get("data") or {})]
            if len(kept) != len(outputs):
                cell["outputs"] = kept
                if tagged:
                    cell["execution_count"] = None
    except Exception:          # never the reason a notebook is not saved
        return
