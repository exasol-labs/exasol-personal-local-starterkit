"""``exakit.nb``: the notebook helpers under the name the requirements give them. The implementation is ``exakit_nb``;
this module replaces itself with it, and registers each of its submodules under ``exakit.nb.<name>`` too, so
``import exakit.nb as nb``, ``from exakit import nb``, ``exakit.nb.trace(...)`` and ``import exakit.nb.own_file`` all
reach the very same modules as ``import exakit_nb`` (never a second copy with classes of its own).
"""

import importlib
import pkgutil
import sys

import exakit_nb as _impl

for _found in pkgutil.iter_modules(_impl.__path__):
    sys.modules[f"{__name__}.{_found.name}"] = importlib.import_module(f"exakit_nb.{_found.name}")
sys.modules[__name__] = _impl
