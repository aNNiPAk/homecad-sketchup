import pytest

from homecad_mcp.errors import BridgeError
from homecad_mcp.server import get_model_info, homecad_status, mcp


@pytest.mark.asyncio
async def test_mcp_has_exactly_two_tools():
    names = {tool.name for tool in await mcp.list_tools()}
    assert names == {"homecad_status", "get_model_info"}


@pytest.mark.asyncio
async def test_disconnected_status_is_actionable(monkeypatch):
    async def fail(self, method):
        raise BridgeError("connection_error", "Open SketchUp and enable HomeCAD")

    monkeypatch.setattr("homecad_mcp.server.BridgeClient.call", fail)
    result = await homecad_status()
    assert result["connection_status"] == "disconnected"
    assert "Open SketchUp" in result["error"]["message"]


@pytest.mark.asyncio
async def test_get_model_info_surfaces_bridge_error(monkeypatch):
    async def fail(self, method):
        raise BridgeError("incompatible_version", "Install matching RBZ")

    monkeypatch.setattr("homecad_mcp.server.BridgeClient.call", fail)
    with pytest.raises(RuntimeError, match="incompatible_version: Install matching RBZ"):
        await get_model_info()
