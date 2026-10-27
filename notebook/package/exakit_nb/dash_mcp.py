"""Call the kit-managed Dash Server through its MCP control plane."""

from __future__ import annotations

import asyncio
import ipaddress
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlsplit


def _local_url(url: str) -> str:
    parts = urlsplit(url)
    try:
        local = ipaddress.ip_address(parts.hostname or "").is_loopback
        valid_port = parts.port is not None
    except ValueError:
        local, valid_port = False, False
    if (parts.scheme != "http" or not local or not valid_port or parts.username or parts.password
            or parts.path not in {"", "/"} or parts.query or parts.fragment):
        raise RuntimeError("The kit reported an unexpected Dash Server URL; inspect exakit status --json.")
    return url.rstrip("/")


def dash_server_url() -> str:
    """Take the dashboard URL from exakit status, never from a guessed port."""
    launcher = Path.home() / ".local" / "bin" / ("exakit.cmd" if sys.platform == "win32" else "exakit")
    command = str(launcher) if launcher.is_file() else "exakit"
    try:
        result = subprocess.run([command, "status", "--json"], capture_output=True, text=True,
                                timeout=15, check=False, env=os.environ.copy())
        status = json.loads(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise RuntimeError("Cannot read the kit status. Run exakit status --json.") from error
    url = status.get("urls", {}).get("dash-server")
    if not isinstance(url, str):
        raise RuntimeError("Dash Server is not running. Run exakit marketplace dash-server, exakit mcp-setup, and exakit start.")
    if status.get("services", {}).get("dash-server") != "running":
        raise RuntimeError("Dash Server is stopped. Run exakit start dash-server and retry.")
    return _local_url(url)


class DashTools:
    """Synchronous adapter for notebook cells, which already run an event loop."""

    def __init__(self, url: str | None = None):
        self.url = _local_url(url) if url is not None else dash_server_url()

    def __call__(self, name: str, arguments: dict) -> dict:
        async def call() -> dict:
            from mcp import ClientSession
            from mcp.client.streamable_http import streamable_http_client

            async with streamable_http_client(self.url + "/mcp") as channels:
                async with ClientSession(channels[0], channels[1]) as session:
                    await session.initialize()
                    result = await session.call_tool(name, arguments)
                    return result.model_dump(by_alias=True)

        # Jupyter and Marimo have a live asyncio loop on the calling thread.
        with ThreadPoolExecutor(max_workers=1) as pool:
            return pool.submit(lambda: asyncio.run(call())).result()


def dash_tools() -> DashTools:
    """The notebook's Dash Server tool adapter; each call is an MCP tool call."""
    return DashTools()
