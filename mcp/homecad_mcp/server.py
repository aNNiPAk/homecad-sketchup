"""Exactly two read-only HomeCAD MCP tools over stdio."""

import logging
import os

from mcp.server.fastmcp import FastMCP

from . import PROTOCOL_VERSION, VERSION
from .connection import BridgeClient
from .errors import BridgeError

logger = logging.getLogger(__name__)
mcp = FastMCP("HomeCAD for SketchUp")


@mcp.tool()
async def homecad_status() -> dict:
    """Report MCP, bridge, SketchUp and active model status."""
    try:
        result = await BridgeClient().call("homecad_status")
        return {"mcp_version": VERSION, **result}
    except BridgeError as exc:
        logger.warning("homecad_status: %s: %s", exc.category, exc.message)
        return {
            "mcp_version": VERSION, "ruby_extension_version": None,
            "sketchup_version": None, "model_name": None,
            "connection_status": "incompatible" if exc.category == "incompatible_version" else "disconnected",
            "protocol_version": PROTOCOL_VERSION, "error": exc.as_dict(),
        }


@mcp.tool()
async def get_model_info() -> dict:
    """Read the active SketchUp model's identity and collection counts."""
    try:
        return await BridgeClient().call("get_model_info")
    except BridgeError as exc:
        logger.warning("get_model_info: %s: %s", exc.category, exc.message)
        raise RuntimeError(f"{exc.category}: {exc.message}") from exc


def main() -> None:
    level = os.environ.get("HOMECAD_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(level=getattr(logging, level, logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    mcp.run(transport="stdio")
