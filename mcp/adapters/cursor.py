"""Cursor adapter."""

from .json_config import JsonConfigAdapter


class CursorAdapter(JsonConfigAdapter):
    def __init__(self) -> None:
        super().__init__(
            adapter_id_value="cursor",
            display_name_value="Cursor",
            config_env_name="CURSOR_MCP_CONFIG_PATH",
            top_level_key="mcpServers",
            activation_message="Reload Cursor to load the updated MCP configuration.",
            default_location=".cursor/mcp.json",
        )
