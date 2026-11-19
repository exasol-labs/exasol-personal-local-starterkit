#!/usr/bin/env bash
# tty-replay.py runs bash scenarios; this one hands the pty to PowerShell so the
# twin of the connect flow is replayed by the same terminal model.
# The bridge runs the engine from the definitions it is given, and the engine
# imports setup/core beside them (the PowerShell suite copies it the same way).
[ -d "$TUI_DEFS/../core" ] || cp -R "$1/setup/core" "$TUI_DEFS/../core"
exec pwsh -NoProfile -File "$1/tests/lib/connect-tui-scenario.ps1" "$1"
