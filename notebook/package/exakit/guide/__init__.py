"""``exakit.guide``: the guided view of the kit's notebooks under the kit's namespace. The implementation is
``exakit_guide``; this module replaces itself with it, so ``import exakit.guide as guide`` and
``import exakit_guide`` reach the very same module (its screens still load on first use).
"""

import sys

import exakit_guide as _impl

sys.modules[__name__] = _impl
