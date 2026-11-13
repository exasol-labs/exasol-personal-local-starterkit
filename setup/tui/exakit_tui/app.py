"""exakit's terminal view: the whole kit on five tabs.

    Status            the database, every component and add-on service, their versions and updates
    Marketplace       every add-on: install, update, start, stop, remove
    AI clients        the AI clients and the MCP servers the kit set up in them: set up, check, remove
    External sources  the databases connected with `exakit connect`: their state, check, refresh, remove, new ones
    Personas          the personas in a sidebar; one opens on the right with its datasets, add-ons, AI clients and
                      notebooks, what is here and what is still missing

Every fact is read from the kit's own `exakit ... --json` answers (kit.py), in the background, so the view never
freezes. Every button runs the `exakit` command it names, in this terminal: the view steps aside while it runs, so its
questions, progress and confirmations are exactly the CLI's, then comes back and reads the tab again.
"""

from __future__ import annotations

import subprocess
from typing import Any, Callable

from rich.markup import escape
from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import (Button, DataTable, Footer, Header, Label, ListItem, ListView, Select, Static, TabbedContent,
                             TabPane)

from .kit import Kit

TABS = ("status", "marketplace", "clients", "sources", "personas")

GOOD = {"running", "ready", "installed", "ok", "healthy", "up to date", "current", "connected"}
BAD = {"failed", "error", "broken", "stopped", "unreachable", "not installed", "missing"}


def mark(state: Any) -> Text:
    """A state with its colour: green when it is well, red when it needs you, yellow in between."""
    text = str(state if state not in (None, "") else "-")
    low = text.lower()
    style = "green" if low in GOOD or low.startswith(("running", "ready", "connected")) else \
        "red" if low in BAD or low.startswith(("fail", "error", "stopped", "broken")) else "yellow"
    return Text(text, style=style)


def yes(flag: Any) -> Text:
    return Text("yes", style="green") if flag else Text("no", style="dim")


class Confirm(ModalScreen[bool]):
    """A yes/no before anything that removes."""

    DEFAULT_CSS = """
    Confirm { align: center middle; }
    #box { width: 72; height: auto; border: thick $error; background: $surface; padding: 1 2; }
    #box Horizontal { height: auto; margin-top: 1; }
    #box Button { margin-right: 2; }
    """

    def __init__(self, question: str, command: str) -> None:
        super().__init__()
        self.question, self.command = question, command

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Label(self.question)
            yield Static(Text("Runs: " + self.command, style="bold"))
            with Horizontal():
                yield Button("Yes, run it", variant="error", id="yes")
                yield Button("Cancel", id="no")

    @on(Button.Pressed)
    def answered(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


class Panel(Static):
    """The right-hand side of a tab: what is selected, in words."""

    DEFAULT_CSS = "Panel { padding: 0 1; height: auto; }"


class ExakitApp(App):
    TITLE = "exakit"
    SUB_TITLE = "Exasol Personal Local Starter Kit"
    CSS = """
    TabPane { padding: 0 1; }
    .row { height: auto; margin: 1 0 0 0; }
    .row Button { margin-right: 1; min-width: 12; }
    .side { width: 34; border-right: solid $primary; }
    .main { width: 1fr; }
    .split { height: 1fr; }
    .table { height: 1fr; min-height: 6; }
    .detail { width: 46%; border-left: solid $primary; padding-left: 1; }
    .muted { color: $text-muted; }
    .hint { color: $text-muted; height: auto; margin: 0 0 1 0; }
    #persona-list { height: 1fr; }
    #summary { height: auto; margin-bottom: 1; }
    """
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("1", "tab('status')", "Status", show=False),
        Binding("2", "tab('marketplace')", "Marketplace", show=False),
        Binding("3", "tab('clients')", "AI clients", show=False),
        Binding("4", "tab('sources')", "Sources", show=False),
        Binding("5", "tab('personas')", "Personas", show=False),
    ]

    def __init__(self, kit: Kit, tab: str = "status", persona: str | None = None) -> None:
        super().__init__()
        self.kit = kit
        self.first_tab = "personas" if persona else (tab if tab in TABS else "status")
        self.persona_wanted = persona
        self.data: dict[str, dict[str, Any]] = {}
        self.selected: dict[str, str] = {}

    # -- layout -----------------------------------------------------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(initial=self.first_tab):
            with TabPane("Status", id="status"):
                yield Static(id="summary")
                with Horizontal(classes="split"):
                    yield DataTable(id="components", classes="table main", cursor_type="row", zebra_stripes=True)
                    yield Panel(id="component-detail", classes="detail")
                with Horizontal(classes="row"):
                    yield Button("Start", id="kit-start", variant="success")
                    yield Button("Stop", id="kit-stop")
                    yield Button("Update", id="kit-update", variant="primary")
                    yield Button("Connection details", id="kit-info")
                    yield Button("Logs", id="kit-logs")
                    yield Button("Load data", id="kit-data-load")
            with TabPane("Marketplace", id="marketplace"):
                yield Static("Every add-on the kit offers. Pick one: what it is on the right, what you can do with it "
                             "under it.", classes="hint")
                with Horizontal(classes="split"):
                    yield DataTable(id="addons", classes="table main", cursor_type="row", zebra_stripes=True)
                    with VerticalScroll(classes="detail"):
                        yield Panel(id="addon-detail")
                        with Horizontal(classes="row"):
                            yield Button("Install", id="addon-install", variant="success")
                            yield Button("Update", id="addon-update", variant="primary")
                        with Horizontal(classes="row"):
                            yield Button("Start", id="addon-start")
                            yield Button("Stop", id="addon-stop")
                            yield Button("Remove", id="addon-remove", variant="error")
            with TabPane("AI clients", id="clients"):
                yield Static("The AI clients the kit can connect to your database (MCP), and the MCP servers it set up "
                             "in them.", classes="hint")
                with Horizontal(classes="split"):
                    yield DataTable(id="clients-table", classes="table main", cursor_type="row", zebra_stripes=True)
                    with VerticalScroll(classes="detail"):
                        yield Panel(id="client-detail")
                        with Horizontal(classes="row"):
                            yield Button("Remove from this client", id="client-remove", variant="error")
                with Horizontal(classes="row"):
                    yield Button("Set up AI clients", id="mcp-setup", variant="success")
                    yield Button("Check and repair", id="mcp-doctor", variant="primary")
            with TabPane("External sources", id="sources"):
                yield Static("Databases and lakes connected with exakit connect: the tables stay where they are and "
                             "are queried live as VS_<NAME>.", classes="hint")
                with Horizontal(classes="split"):
                    yield DataTable(id="sources-table", classes="table main", cursor_type="row", zebra_stripes=True)
                    with VerticalScroll(classes="detail"):
                        yield Panel(id="source-detail")
                        with Horizontal(classes="row"):
                            yield Button("Check", id="source-check", variant="primary")
                            yield Button("Refresh tables", id="source-refresh")
                            yield Button("New password", id="source-reauth")
                        with Horizontal(classes="row"):
                            yield Button("Disconnect", id="source-disconnect")
                            yield Button("Remove", id="source-remove", variant="error")
                with Horizontal(classes="row"):
                    yield Select([], prompt="New connection: pick a source", id="connector", allow_blank=True)
                    yield Button("Connect", id="source-connect", variant="success")
                    yield Button("Check all", id="source-check-all")
            with TabPane("Personas", id="personas"):
                with Horizontal(classes="split"):
                    with Vertical(classes="side"):
                        yield Label("Personas", classes="muted")
                        yield ListView(id="persona-list")
                    with VerticalScroll(classes="main"):
                        yield Panel(id="persona-detail")
                        with Horizontal(classes="row"):
                            yield Button("Add this persona", id="persona-add", variant="success")
                            yield Button("Bring in what is missing", id="persona-missing", variant="primary")
                        with Horizontal(classes="row"):
                            yield Button("Open the notebooks", id="persona-notebook")
                            yield Button("Remove this persona", id="persona-remove", variant="error")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#components", DataTable).add_columns("Component", "Installed", "Available", "State")
        self.query_one("#addons", DataTable).add_columns("Add-on", "Version", "Installed", "State")
        self.query_one("#clients-table", DataTable).add_columns("AI client", "Connected", "MCP servers")
        self.query_one("#sources-table", DataTable).add_columns("Source", "Kind", "Schema", "State", "Where")
        for tab in TABS:
            self.load(tab)

    # -- reading ----------------------------------------------------------------------------------------------------
    def action_tab(self, tab: str) -> None:
        self.query_one(TabbedContent).active = tab

    def action_refresh(self) -> None:
        self.load(self.query_one(TabbedContent).active or "status")

    @work(thread=True, group="read")
    def load(self, tab: str) -> None:
        """Read one tab's facts from the kit, off the screen's thread, then draw them."""
        kit = self.kit
        if tab == "status":
            found = {"status": kit.json("status"), "version": kit.json("version")}
        elif tab == "marketplace":
            found = {"list": kit.json("marketplace", "--list"), "status": kit.json("status")}
        elif tab == "clients":
            found = {"mcp": kit.json("mcp-status"), "names": kit.client_names()}
        elif tab == "sources":
            found = {"list": kit.json("source", "list"), "catalog": kit.json("source", "catalog")}
        else:
            found = {"list": kit.json("persona", "list"), "datasets": kit.datasets(), "status": kit.json("status")}
        self.data[tab] = found
        self.call_from_thread(getattr(self, f"draw_{tab}"))

    # -- Status -------------------------------------------------------------------------------------------------------
    def draw_status(self) -> None:
        status = self.data["status"]["status"]
        version = self.data["status"]["version"]
        lines = []
        if status.get("_error"):
            lines.append(f"[red]The kit did not answer:[/] {escape(status['_error'])}")
        elif not status.get("installed", True):
            lines.append(f"[red]Not installed[/] ({escape(str(status.get('reason') or status.get('status') or ''))}). "
                         f"Install: {escape(str(status.get('remedy') or ''))}")
        else:
            state = str(status.get("status") or ("running" if status.get("running") else "unknown"))
            colour = "green" if state.lower().startswith(("running", "healthy", "ok")) else "yellow"
            lines.append(f"Database: [{colour}]{escape(state)}[/]"
                         + (f"   Platform: {escape(str(status['platform']))}" if status.get("platform") else ""))
            services = status.get("services") or {}
            if services:
                lines.append("Services: " + "   ".join(f"{escape(k)} [{('green' if str(v).startswith('running') else 'yellow')}]"
                                                      f"{escape(str(v))}[/]" for k, v in services.items()))
            urls = status.get("urls") or {}
            if urls:
                lines.append("Open: " + "   ".join(f"{escape(k)} {escape(str(v))}" for k, v in urls.items()))
            loaded = status.get("datasets_loaded") or []
            if loaded:
                lines.append("Datasets loaded: " + ", ".join(escape(str(d)) for d in loaded))
            if status.get("remedy"):
                lines.append(f"[yellow]To do:[/] {escape(str(status['remedy']))}")
        self.query_one("#summary", Static).update("\n".join(lines))
        table = self.query_one("#components", DataTable)
        table.clear()
        for row in version.get("components") or []:
            name = str(row.get("component") or "")
            table.add_row(name + (" (add-on)" if row.get("addon") else ""),
                          str(row.get("installed_label") or row.get("installed") or "-"),
                          str(row.get("advertised") or "-"), mark(row.get("status")), key=name)
        if version.get("_error"):
            self.query_one("#component-detail", Panel).update(f"[red]{escape(version['_error'])}[/]")

    @on(DataTable.RowHighlighted, "#components")
    def component_picked(self, event: DataTable.RowHighlighted) -> None:
        name = str(event.row_key.value or "")
        self.selected["component"] = name
        row = next((r for r in self.data.get("status", {}).get("version", {}).get("components") or []
                    if r.get("component") == name), {})
        lines = [f"[b]{escape(name)}[/b]", "",
                 f"Installed: {escape(str(row.get('installed_label') or row.get('installed') or '-'))}",
                 f"Available: {escape(str(row.get('advertised') or '-'))}",
                 "State: " + escape(str(row.get("status") or "-"))]
        if row.get("ownership"):
            lines.append(f"Owned by: {escape(str(row['ownership']))}")
        if row.get("remedy"):
            lines += ["", f"[yellow]To do:[/] {escape(str(row['remedy']))}"]
        self.query_one("#component-detail", Panel).update("\n".join(lines))

    # -- Marketplace ---------------------------------------------------------------------------------------------------
    def _addons(self) -> list[dict[str, Any]]:
        return [a for a in self.data.get("marketplace", {}).get("list", {}).get("addons") or [] if isinstance(a, dict)]

    def draw_marketplace(self) -> None:
        table = self.query_one("#addons", DataTable)
        table.clear()
        for addon in self._addons():
            table.add_row(str(addon.get("name") or addon.get("id")), str(addon.get("version") or "-"),
                          yes(addon.get("installed")), mark(addon.get("status")), key=str(addon.get("id")))
        found = self.data["marketplace"]["list"]
        if found.get("_error") or found.get("error"):
            self.query_one("#addon-detail", Panel).update(
                f"[red]{escape(str(found.get('_error') or found.get('error')))}[/]\n{escape(str(found.get('remedy') or ''))}")
        elif not self._addons():
            self.query_one("#addon-detail", Panel).update("No add-ons listed.")

    @on(DataTable.RowHighlighted, "#addons")
    def addon_picked(self, event: DataTable.RowHighlighted) -> None:
        addon_id = str(event.row_key.value or "")
        self.selected["addon"] = addon_id
        addon = next((a for a in self._addons() if str(a.get("id")) == addon_id), {})
        services = self.data.get("marketplace", {}).get("status", {}).get("services") or {}
        urls = self.data.get("marketplace", {}).get("status", {}).get("urls") or {}
        lines = [f"[b]{escape(str(addon.get('name') or addon_id))}[/b]  [dim]{escape(addon_id)}[/]", ""]
        if addon.get("about"):
            lines += [escape(str(addon["about"])), ""]
        lines.append(f"Installed: {'yes' if addon.get('installed') else 'no'}"
                     + (f"   Version: {escape(str(addon['version']))}" if addon.get("version") else ""))
        lines.append(f"State: {escape(str(addon.get('status') or '-'))}")
        if addon_id in services:
            lines.append(f"Service: {escape(str(services[addon_id]))}")
        if addon_id in urls:
            lines.append(f"Open: {escape(str(urls[addon_id]))}")
        for key, label in (("repo", "Repository"), ("url", "Link"), ("docs", "Documentation")):
            if addon.get(key):
                lines.append(f"{label}: {escape(str(addon[key]))}")
        lines += ["", f"[dim]Full reference: exakit help {escape(addon_id)}[/]"]
        self.query_one("#addon-detail", Panel).update("\n".join(lines))
        installed = bool(addon.get("installed"))
        self.query_one("#addon-install", Button).disabled = installed
        for button in ("#addon-update", "#addon-remove", "#addon-start", "#addon-stop"):
            self.query_one(button, Button).disabled = not installed

    # -- AI clients ------------------------------------------------------------------------------------------------------
    def _entries(self) -> list[dict[str, Any]]:
        mcp = self.data.get("clients", {}).get("mcp", {})
        return [a for a in mcp.get("artifacts") or [] if isinstance(a, dict) and a.get("client")
                and not a.get("removed_at") and a.get("kind") == "client_config"]

    def draw_clients(self) -> None:
        names = self.data["clients"]["names"]
        entries = self._entries()
        by_client: dict[str, list[dict[str, Any]]] = {}
        for entry in entries:
            by_client.setdefault(str(entry["client"]), []).append(entry)
        table = self.query_one("#clients-table", DataTable)
        table.clear()
        for cid in list(names) + sorted(set(by_client) - set(names)):
            servers = sorted({str((e.get("metadata") or {}).get("entry_name") or (e.get("metadata") or {}).get("server")
                                  or "exasol") for e in by_client.get(cid, [])})
            table.add_row(names.get(cid, cid), yes(cid in by_client), ", ".join(servers) or "-", key=cid)
        mcp = self.data["clients"]["mcp"]
        if mcp.get("_error") or mcp.get("error"):
            self.query_one("#client-detail", Panel).update(
                f"[red]{escape(str(mcp.get('_error') or mcp.get('error')))}[/]\n{escape(str(mcp.get('remedy') or ''))}")

    @on(DataTable.RowHighlighted, "#clients-table")
    def client_picked(self, event: DataTable.RowHighlighted) -> None:
        cid = str(event.row_key.value or "")
        self.selected["client"] = cid
        names = self.data.get("clients", {}).get("names", {})
        entries = [e for e in self._entries() if str(e["client"]) == cid]
        lines = [f"[b]{escape(names.get(cid, cid))}[/b]  [dim]{escape(cid)}[/]", ""]
        if not entries:
            lines.append("Not connected. Set up AI clients connects it to your database.")
        for entry in entries:
            meta = entry.get("metadata") or {}
            lines.append(f"MCP server [b]{escape(str(meta.get('entry_name') or meta.get('server') or 'exasol'))}[/b]")
            for key in ("path", "target", "file", "scope"):
                if entry.get(key) or meta.get(key):
                    lines.append(f"  {key}: {escape(str(entry.get(key) or meta.get(key)))}")
            if entry.get("written_at") or entry.get("created_at"):
                lines.append(f"  set up: {escape(str(entry.get('written_at') or entry.get('created_at')))}")
        self.query_one("#client-detail", Panel).update("\n".join(lines))
        self.query_one("#client-remove", Button).disabled = not entries

    # -- External sources -------------------------------------------------------------------------------------------------
    def _sources(self) -> list[dict[str, Any]]:
        return [s for s in self.data.get("sources", {}).get("list", {}).get("sources") or [] if isinstance(s, dict)]

    def draw_sources(self) -> None:
        table = self.query_one("#sources-table", DataTable)
        table.clear()
        for source in self._sources():
            table.add_row(str(source.get("name")), str(source.get("connector_name") or source.get("connector") or ""),
                          str(source.get("schema") or ""), mark(source.get("status")), str(source.get("host") or ""),
                          key=str(source.get("name")))
        found = self.data["sources"]["list"]
        detail = self.query_one("#source-detail", Panel)
        if found.get("_error") or found.get("error"):
            detail.update(f"[red]{escape(str(found.get('_error') or found.get('error')))}[/]\n"
                          f"{escape(str(found.get('remedy') or ''))}")
        elif not self._sources():
            detail.update("No external source connected yet.\n\nPick one below and press Connect: PostgreSQL, MySQL, "
                          "Snowflake, BigQuery and more. Its tables stay where they are and are read live.")
        connectors = [c for c in self.data["sources"]["catalog"].get("connectors") or [] if isinstance(c, dict)]
        options = []
        for c in connectors:
            label = str(c.get("name") or c.get("label") or c.get("id"))
            status = str(c.get("status") or c.get("tier") or "")
            options.append((label + (f"  ({status})" if status and status.lower() not in ("ga", "") else ""), str(c.get("id"))))
        self.query_one("#connector", Select).set_options(options)

    @on(DataTable.RowHighlighted, "#sources-table")
    def source_picked(self, event: DataTable.RowHighlighted) -> None:
        name = str(event.row_key.value or "")
        self.selected["source"] = name
        source = next((s for s in self._sources() if str(s.get("name")) == name), {})
        lines = [f"[b]{escape(name)}[/b]  {escape(str(source.get('connector_name') or ''))}", "",
                 f"Tables in: [b]{escape(str(source.get('schema') or ''))}[/b] (queried live, nothing copied)",
                 f"Where: {escape(str(source.get('host') or '-'))}",
                 f"TLS: {escape(str(source.get('tls') or '-'))}",
                 f"State: {escape(str(source.get('status') or '-'))}"
                 + (f"   last checked {escape(str(source['last_check']))}" if source.get("last_check") else "")]
        if source.get("needs_refresh"):
            lines.append("[yellow]Its table list changed: Refresh tables reads it again.[/]")
        lines += ["", f"[dim]Its tables and columns: exakit source describe {escape(name)}[/]"]
        self.query_one("#source-detail", Panel).update("\n".join(lines))
        for button in ("#source-check", "#source-refresh", "#source-reauth", "#source-disconnect", "#source-remove"):
            self.query_one(button, Button).disabled = not source

    # -- Personas ----------------------------------------------------------------------------------------------------------
    def _personas(self) -> list[dict[str, Any]]:
        return [p for p in self.data.get("personas", {}).get("list", {}).get("personas") or [] if isinstance(p, dict)]

    def draw_personas(self) -> None:
        listing = self.query_one("#persona-list", ListView)
        keep = self.selected.get("persona") or self.persona_wanted
        listing.clear()
        personas = self._personas()
        for persona in personas:
            title = str(persona.get("title") or persona.get("id"))
            here = "  [green]●[/]" if persona.get("recorded") else ""
            listing.append(ListItem(Label(title + here), id="p-" + str(persona.get("id"))))
        found = self.data["personas"]["list"]
        if found.get("_error"):
            self.query_one("#persona-detail", Panel).update(f"[red]{escape(found['_error'])}[/]")
            return
        ids = [str(p.get("id")) for p in personas]
        if keep and keep not in ids and self.persona_wanted == keep:
            self.query_one("#persona-detail", Panel).update(
                f"[red]No persona named {escape(keep)}.[/] The kit has: {escape(', '.join(ids))}")
            return
        if ids:
            pick = ids.index(keep) if keep in ids else 0
            listing.index = pick
            self.open_persona(ids[pick])

    @on(ListView.Highlighted, "#persona-list")
    def persona_picked(self, event: ListView.Highlighted) -> None:
        if event.item is not None and event.item.id:
            pid = event.item.id[2:]
            if pid != self.selected.get("persona"):
                self.open_persona(pid)

    def open_persona(self, pid: str) -> None:
        self.selected["persona"] = pid
        self.query_one("#persona-detail", Panel).update(f"Reading {escape(pid)}…")
        self.read_plan(pid)

    @work(thread=True, group="plan", exclusive=True)
    def read_plan(self, pid: str) -> None:
        plan = self.kit.json("persona", "plan", pid)
        self.call_from_thread(self.draw_persona, pid, plan)

    def draw_persona(self, pid: str, plan: dict[str, Any]) -> None:
        if pid != self.selected.get("persona"):
            return
        self.data.setdefault("plans", {})[pid] = plan
        persona = next((p for p in self._personas() if str(p.get("id")) == pid), {})
        catalog = self.data.get("personas", {}).get("datasets", {})
        loaded_here = set(self.data.get("personas", {}).get("status", {}).get("datasets_loaded") or [])
        datasets = plan.get("datasets") or {}
        addons = plan.get("addons") or {}
        loaded = set(datasets.get("loaded") or []) | (loaded_here & set(persona.get("datasets") or []))
        installed = set(addons.get("installed") or [])
        unavailable = set(addons.get("unavailable") or [])
        lines = [f"[b]{escape(str(persona.get('title') or pid))}[/b]  [dim]{escape(pid)}[/]",
                 escape(str(persona.get("summary") or "")), ""]
        lines.append("[green]This kit is set up as this persona.[/]" if persona.get("recorded")
                     else "[yellow]Not added to this kit yet: Add this persona brings everything below in.[/]")
        if plan.get("_error"):
            lines.append(f"[dim]What is still missing could not be read: {escape(plan['_error'])}[/]")
        lines += ["", "[b]Recommended datasets[/b]"]
        for did in persona.get("datasets") or []:
            info = catalog.get(did, {})
            state = "[green]loaded[/]" if did in loaded else "[yellow]to load[/]"
            lines.append(f"  {state}  {escape(info.get('label') or did)}  [dim]{escape(did)}[/]")
        lines += ["", "[b]Add-ons[/b]"]
        for aid in persona.get("addons") or []:
            state = ("[green]installed[/]" if aid in installed else "[red]not offered here[/]" if aid in unavailable
                     else "[yellow]to install[/]")
            lines.append(f"  {state}  {escape(aid)}")
        clients = persona.get("mcp_clients")
        lines += ["", "[b]AI clients[/b]", "  " + escape("every AI client the kit supports" if clients == "all"
                                                         else ", ".join(clients or []) or "none")]
        notebooks = [n for n in persona.get("notebooks") or [] if isinstance(n, dict)]
        if notebooks:
            lines += ["", "[b]Notebooks[/b]"]
            for n in notebooks:
                lines.append(f"  {escape(str(n.get('title') or n.get('id')))}  [dim]{escape(str(n.get('jupyter') or ''))}[/]")
        if plan.get("nothing_pending"):
            lines += ["", "[green]Nothing is missing.[/]"]
        self.query_one("#persona-detail", Panel).update("\n".join(lines))
        missing = [d for d in persona.get("datasets") or [] if d not in loaded] + \
                  [a for a in persona.get("addons") or [] if a not in installed and a not in unavailable]
        self.query_one("#persona-add", Button).disabled = bool(persona.get("recorded"))
        self.query_one("#persona-missing", Button).disabled = not missing
        self.query_one("#persona-remove", Button).disabled = not persona.get("recorded")
        self.query_one("#persona-notebook", Button).disabled = not notebooks

    # -- running a command --------------------------------------------------------------------------------------------------
    def run_kit(self, *args: str, then: str | None = None) -> None:
        """Run `exakit <args>` in this terminal - the view steps aside so the command's own questions and progress
        show as they do in the CLI - then come back and read the tab again."""
        command = self.kit.command(*args)
        shown = "exakit " + " ".join(args)
        try:
            with self.suspend():
                print(f"\n$ {shown}\n", flush=True)
                try:
                    code = subprocess.run(command, env=self.kit.env()).returncode
                except KeyboardInterrupt:
                    code = 130
                except OSError as exc:
                    print(f"exakit could not be started: {exc}")
                    code = 127
                try:
                    input(f"\n{'Done' if code == 0 else f'Finished with exit code {code}'}. Press Enter to go back to exakit. ")
                except (EOFError, KeyboardInterrupt):
                    pass
        except Exception as exc:     # a terminal that cannot hand itself over: say what to run instead
            self.notify(f"Run it in a terminal: {shown} ({exc})", severity="warning", timeout=10)
            return
        self.notify(f"{shown}: {'done' if code == 0 else f'exit {code}'}", severity="information" if code == 0 else "error")
        self.load(then or (self.query_one(TabbedContent).active or "status"))
        if then != "status":
            self.load("status")

    def confirm_then(self, question: str, *args: str, then: str | None = None) -> None:
        def go(answer: bool | None) -> None:
            if answer:
                self.run_kit(*args, then=then)
        self.push_screen(Confirm(question, "exakit " + " ".join(args)), go)

    def _need(self, what: str) -> str | None:
        value = self.selected.get(what)
        if not value:
            self.notify(f"Pick a{'n' if what[0] in 'aeiou' else ''} {what} first.", severity="warning")
        return value

    @on(Button.Pressed)
    def pressed(self, event: Button.Pressed) -> None:
        button = event.button.id or ""
        simple: dict[str, Callable[[], None]] = {
            "kit-start": lambda: self.run_kit("start"),
            "kit-stop": lambda: self.run_kit("stop"),
            "kit-update": lambda: self.run_kit("update"),
            "kit-info": lambda: self.run_kit("info"),
            "kit-logs": lambda: self.run_kit("logs"),
            "kit-data-load": lambda: self.run_kit("data-load"),
            "mcp-setup": lambda: self.run_kit("mcp-setup", then="clients"),
            "mcp-doctor": lambda: self.run_kit("mcp-doctor", then="clients"),
            "source-check-all": lambda: self.run_kit("source", "check", "--all", then="sources"),
        }
        if button in simple:
            simple[button]()
            return
        if button.startswith("addon-") and (addon := self._need("addon")):
            {"addon-install": lambda: self.run_kit("marketplace", addon, then="marketplace"),
             "addon-update": lambda: self.run_kit("update", addon, then="marketplace"),
             "addon-start": lambda: self.run_kit("start", addon, then="marketplace"),
             "addon-stop": lambda: self.run_kit("stop", addon, then="marketplace"),
             "addon-remove": lambda: self.confirm_then(f"Remove the add-on {addon}? The rest of the kit is untouched.",
                                                       "uninstall", addon, then="marketplace")}[button]()
        elif button == "client-remove" and (client := self._need("client")):
            self.confirm_then(f"Take the kit's MCP servers out of {client}?", "mcp-remove", client, then="clients")
        elif button == "source-connect":
            picked = self.query_one("#connector", Select).value
            self.run_kit(*(["connect"] if picked in (None, Select.BLANK) else ["connect", str(picked)]), then="sources")
        elif button.startswith("source-") and (source := self._need("source")):
            {"source-check": lambda: self.run_kit("source", "check", source, then="sources"),
             "source-refresh": lambda: self.run_kit("source", "refresh", source, then="sources"),
             "source-reauth": lambda: self.run_kit("source", "reauth", source, then="sources"),
             "source-disconnect": lambda: self.confirm_then(
                 f"Disconnect {source}? Its settings are kept, so it can be connected again.",
                 "source", "disconnect", source, then="sources"),
             "source-remove": lambda: self.confirm_then(
                 f"Remove {source}? Its virtual schema and saved settings are deleted; the source itself is untouched.",
                 "source", "remove", source, then="sources")}[button]()
        elif button.startswith("persona-") and (pid := self._need("persona")):
            if button == "persona-add":
                self.run_kit("persona", "add", pid, then="personas")
            elif button == "persona-missing":
                self.bring_in(pid)
            elif button == "persona-notebook":
                self.run_kit("notebook", then="personas")
            elif button == "persona-remove":
                self.confirm_then(f"Remove the persona {pid} from this kit?", "persona", "remove", pid, then="personas")

    def bring_in(self, pid: str) -> None:
        """What the persona brings that is not here yet, with the kit's own command: `exakit persona add <id>` does
        exactly that for a persona this kit was set up as too (it joins, and brings in what is missing)."""
        self.run_kit("persona", "add", pid, then="personas")


def run(kit: Kit, tab: str = "status", persona: str | None = None) -> int:
    ExakitApp(kit, tab=tab, persona=persona).run()
    return 0
