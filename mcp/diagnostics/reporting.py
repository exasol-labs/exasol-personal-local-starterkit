"""Human-readable summary helpers."""

from __future__ import annotations

from mcp.core.models import Finding, OperationStatus


def summarize_findings(findings: list[Finding]) -> str:
    """Summarize findings for compact result messages."""

    if not findings:
        return "No active findings."
    counts = {"critical": 0, "error": 0, "warning": 0, "info": 0}
    for finding in findings:
        counts[finding.severity.value] += 1
    parts = [f"{count} {label if count == 1 else label + 's'}" for label, count in counts.items() if count]
    return ", ".join(parts)


def summarize_status(status: OperationStatus, findings: list[Finding]) -> str:
    """Build a short summary line from status plus findings."""

    return f"{status.value}: {summarize_findings(findings)}"
