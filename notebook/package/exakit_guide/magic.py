"""%%ask as an IPython extension. Lightweight on purpose: the Ask card loads only when %%ask is used.

Enable it in a notebook with `import exakit_guide` (or `%load_ext exakit_guide`). To have it in every kit
notebook from the start, add "exakit_guide" to the kernel's IPython extensions (see README)."""

from __future__ import annotations


def _ask(line: str, cell: str | None = None):
    from IPython.display import display

    from .screens.ask import Ask

    question = (cell if cell and cell.strip() else line or "").strip()
    if not question:
        print("Write your question on the lines below %%ask, then run the cell.")
        return
    display(Ask(question, box=False))


def register(ip=None) -> None:
    try:
        if ip is None:
            from IPython import get_ipython

            ip = get_ipython()
        if ip is not None:
            ip.register_magic_function(_ask, "line_cell", "ask")
    except Exception:
        pass
