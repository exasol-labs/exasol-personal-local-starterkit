"""The guided view for the Exasol starter kit's JupyterLab.

    import exakit.guide as guide
    guide.start()         # 00_quickstart: Home, then step 1, in one cell
    guide.home()          # the kit Home screen: setup, next step, continue
    guide.marketplace()   # every add-on and part of the kit: install, start, update (Home's Marketplace tab)
    guide.understand()    # step 1: choose data, approve what each column means
    guide.explore()       # step 2: check and clean, compare, predict, test feature ideas
    guide.ask()           # step 3: ask in plain words (also: a cell starting with %%ask)
    guide.share()         # step 4: preview and publish a dashboard, then the hand-off bundle

Runs in the kit's notebook environment, on top of exakit.nb. Nothing here replaces the kit: every
screen calls the kit's own commands and helpers. Importing it registers %%ask; the screens load
when first used, so the import is quick.
"""

from .magic import register as _register_magic

__version__ = "0.1.0"
__all__ = ["start", "home", "marketplace", "understand", "explore", "ask", "share", "Home", "ChooseData", "ColumnMap"]

_LAZY = {"home": ".screens.home", "Home": ".screens.home", "marketplace": ".screens.home", "understand": ".screens.understand",
         "ChooseData": ".screens.understand", "ColumnMap": ".screens.understand", "explore": ".screens.explore",
         "ask": ".screens.ask", "share": ".screens.share"}


def __getattr__(name):
    if name in _LAZY:
        import importlib

        value = getattr(importlib.import_module(_LAZY[name], __name__), name)
        # Importing the submodule binds e.g. exakit_guide.home to the MODULE, so a second guide.home() would fail
        # with "'module' object is not callable". Bind the name to the function itself.
        globals()[name] = value
        return value
    raise AttributeError(name)


def start():
    """The quickstart's cards in one cell: Home (the kit), then step 1 (your data and its column map). Each run starts
    a workflow (nb.workflow, a new id); every card action after it is logged under that id (nb.workflow_log)."""
    from . import actions
    from .card import show

    actions.run("data.workflow")
    from .screens.home import Home
    from .screens.understand import ChooseData, ColumnMap, DataMap

    return show(Home(), ChooseData(), ColumnMap(), DataMap(), docs="guides/load-data")


def load_ipython_extension(ip) -> None:
    """`%load_ext exakit_guide`, or listed in a kernel's IPython extensions: enables %%ask."""
    _register_magic(ip)


_register_magic()   # importing exakit_guide in a notebook also enables %%ask
