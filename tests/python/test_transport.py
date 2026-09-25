import asyncio
import json
import struct

import pytest

from homecad_mcp.config import Config
from homecad_mcp.connection import BridgeClient, encode_frame, read_frame
from homecad_mcp.errors import BridgeError


def response(request_id, *, result=None, error=None):
    value = {"jsonrpc": "2.0", "id": request_id}
    value["error" if error else "result"] = error if error else result
    return value


async def fake_bridge(handler):
    server = await asyncio.start_server(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    return server, port


async def read_request(reader):
    return await read_frame(reader, 1_048_576)


async def send_response(writer, value):
    writer.write(encode_frame(value, 1_048_576))
    await writer.drain()


@pytest.mark.asyncio
async def test_handshake_and_two_tools():
    methods = []

    async def handler(reader, writer):
        hello = await read_request(reader)
        assert hello["method"] == "hello"
        assert hello["params"]["protocol_version"] == 1
        await send_response(writer, response(1, result={"protocol_version": 1,
                         "ruby_extension_version": "0.1.0"}))
        call = await read_request(reader)
        methods.append(call["method"])
        await send_response(writer, response(2, result={"name": "test"}))
        writer.close()

    server, port = await fake_bridge(handler)
    try:
        client = BridgeClient(Config(port=port))
        assert await client.call("homecad_status") == {"name": "test"}
        assert await client.call("get_model_info") == {"name": "test"}
        assert methods == ["homecad_status", "get_model_info"]
    finally:
        server.close()
        await server.wait_closed()


def test_capture_rejects_old_camera_bridge_without_blocking_m0():
    hello = {"ruby_extension_version": "0.2.0"}
    BridgeClient._check_method_version("homecad_status", hello)
    with pytest.raises(BridgeError, match="requires HomeCAD RBZ 0.2.1") as caught:
        BridgeClient._check_method_version("capture_view", hello)
    assert caught.value.category == "incompatible_version"


@pytest.mark.asyncio
async def test_incompatible_version_rejected_by_ruby():
    async def handler(reader, writer):
        await read_request(reader)
        await send_response(writer, response(1, error={"code": -32001,
            "message": "wrong protocol", "data": {"category": "incompatible_version"}}))
        writer.close()

    server, port = await fake_bridge(handler)
    try:
        with pytest.raises(BridgeError, match="wrong protocol") as caught:
            await BridgeClient(Config(port=port)).call("homecad_status")
        assert caught.value.category == "incompatible_version"
    finally:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
async def test_incompatible_version_rejected_by_python():
    async def handler(reader, writer):
        await read_request(reader)
        await send_response(writer, response(1, result={"protocol_version": 2,
                         "ruby_extension_version": "9.0.0"}))
        writer.close()

    server, port = await fake_bridge(handler)
    try:
        with pytest.raises(BridgeError) as caught:
            await BridgeClient(Config(port=port)).call("get_model_info")
        assert caught.value.category == "incompatible_version"
    finally:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
async def test_timeout_on_silent_peer():
    async def handler(reader, writer):
        await read_request(reader)
        await asyncio.sleep(0.3)
        writer.close()

    server, port = await fake_bridge(handler)
    try:
        with pytest.raises(BridgeError) as caught:
            await BridgeClient(Config(port=port, timeout=0.05)).call("homecad_status")
        assert caught.value.category == "connection_error"
    finally:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
async def test_connection_refused():
    server, port = await fake_bridge(lambda *_: None)
    server.close()
    await server.wait_closed()
    with pytest.raises(BridgeError, match="Open SketchUp") as caught:
        await BridgeClient(Config(port=port)).call("get_model_info")
    assert caught.value.category == "connection_error"


@pytest.mark.asyncio
async def test_bad_frame_size_and_response_id():
    reader = asyncio.StreamReader()
    reader.feed_data(struct.pack(">I", 1_048_577))
    with pytest.raises(BridgeError, match="frame length"):
        await read_frame(reader, 1_048_576)

    async def handler(reader, writer):
        await read_request(reader)
        await send_response(writer, response(99, result={}))
        writer.close()

    server, port = await fake_bridge(handler)
    try:
        with pytest.raises(BridgeError, match="response id mismatch"):
            await BridgeClient(Config(port=port)).call("homecad_status")
    finally:
        server.close()
        await server.wait_closed()
