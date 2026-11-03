"""Exasol's usage telemetry stays off in every process the kit starts.

pyexasol 3 reports one anonymous usage event per connect through the
exasol-telemetry-client library unless EXASOL_TELEMETRY_DISABLE is present in
the environment; any value disables it, the variable's presence is the switch
(exasol/telemetry/client/config.py). The kit sets it before anything it runs
can load pyexasol, and never replaces a value the user already set.

This is the marketplace's one copy of the rule: runtime.py applies it when it
is imported, so every marketplace command and every child it starts inherits
it, and the stand-alone launchers (Dash Server, dbt-exasol, Exasol Scheduler)
apply it to the environment they hand to their service. The same rule lives in
exakit_nb._kit for the notebook environment, in common.sh and
exakit-common.ps1 for the shell entry points, and inline in the few stand-alone
scripts that cannot import either.
"""

from __future__ import annotations

import os
from typing import MutableMapping

VARIABLE = "EXASOL_TELEMETRY_DISABLE"
VALUE = "1"


def default_off(environment: MutableMapping[str, str] | None = None) -> MutableMapping[str, str]:
    """Set EXASOL_TELEMETRY_DISABLE unless it is already present; returns the mapping it changed.

    With no argument it changes this process's environment, so every child
    inherits it. A value the user set, even an empty one, is left alone.
    """
    target = os.environ if environment is None else environment
    target.setdefault(VARIABLE, VALUE)
    return target
