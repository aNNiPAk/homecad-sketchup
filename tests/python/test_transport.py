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
                         "ruby_extension_version": "0.1.0",
                         "capabilities": ["model.info.v1", "scene.inspect.v1",
                                          "scene.measure.v1", "view.capture.v1", "scene.undo.v1",
                                          "geometry.primitive.v1"]}))
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


def test_capability_handshake_accepts_current_bridge_and_unknown_capabilities():
    hello = {"ruby_extension_version": "0.3.0", "capabilities": [
        "model.info.v1", "scene.inspect.v1", "scene.measure.v1", "view.capture.v1",
        "scene.undo.v1", "geometry.primitive.v1", "architecture.core.v1", "future.unknown.v1"]}
    BridgeClient._check_hello({"protocol_version": 1, **hello})
    for method in ("get_model_info", "list_objects", "find_objects", "get_object",
                   "get_selection", "measure", "capture_view", "undo"):
        BridgeClient._check_method_capability(method, hello)
    for method in ("create_group", "create_face", "create_edge", "create_box", "create_circle",
                   "create_arc", "create_polygon", "push_pull", "follow_me", "transform_object",
                   "boolean_operation"):
        BridgeClient._check_method_capability(method, hello)
    for method in ("get_wall_frame", "create_wall", "create_opening", "create_door",
                   "create_window", "create_niche", "create_column", "update_architecture_object",
                   "delete_architecture_object", "create_room", "detect_rooms"):
        BridgeClient._check_method_capability(method, hello)


def test_old_bridge_without_capabilities_still_reports_status():
    hello = {"protocol_version": 1, "ruby_extension_version": "0.2.1"}
    BridgeClient._check_hello(hello)
    BridgeClient._check_method_capability("homecad_status", hello)
    with pytest.raises(BridgeError, match="scene.inspect.v1") as caught:
        BridgeClient._check_method_capability("list_objects", hello)
    assert caught.value.category == "unsupported_operation"
    with pytest.raises(BridgeError, match="geometry.primitive.v1") as primitive:
        BridgeClient._check_method_capability("create_box", hello)
    assert primitive.value.category == "unsupported_operation"
    with pytest.raises(BridgeError, match="view.capture.v1") as caught:
        BridgeClient._check_method_capability("capture_view", hello)
    assert caught.value.category == "unsupported_operation"
    BridgeClient._check_method_capability("homecad_status", {"capabilities": "malformed"})
    with pytest.raises(BridgeError, match="architecture.core.v1") as architecture:
        BridgeClient._check_method_capability("create_wall", hello)
    assert architecture.value.category == "unsupported_operation"


@pytest.mark.asyncio
async def test_old_bridge_status_works_without_capabilities_over_transport():
    methods = []

    async def handler(reader, writer):
        await read_request(reader)
        await send_response(writer, response(1, result={
            "protocol_version": 1, "ruby_extension_version": "0.2.1"}))
        try:
            request = await read_request(reader)
        except asyncio.IncompleteReadError:
            writer.close()
            return
        methods.append(request["method"])
        await send_response(writer, response(2, result={"connection_status": "connected"}))
        writer.close()

    server, port = await fake_bridge(handler)
    try:
        client = BridgeClient(Config(port=port))
        assert await client.call("homecad_status") == {"connection_status": "connected"}
        with pytest.raises(BridgeError) as unsupported:
            await client.call("capture_view")
        assert unsupported.value.category == "unsupported_operation"
        assert methods == ["homecad_status"]
    finally:
        server.close()
        await server.wait_closed()


def test_capability_list_may_be_empty_or_missing_but_must_be_well_formed():
    with pytest.raises(BridgeError) as missing:
        BridgeClient._check_method_capability("measure", {"ruby_extension_version": "0.2.1"})
    assert missing.value.category == "unsupported_operation"
    with pytest.raises(BridgeError, match="malformed capabilities") as malformed:
        BridgeClient._check_method_capability("capture_view", {
            "ruby_extension_version": "0.3.0", "capabilities": "view.capture.v1"})
    assert malformed.value.category == "invalid_response"
    with pytest.raises(BridgeError, match="malformed capabilities"):
        BridgeClient._check_method_capability("capture_view", {
            "ruby_extension_version": "0.3.0", "capabilities": ["view.capture.v1", 7]})
    with pytest.raises(BridgeError, match="malformed capabilities"):
        BridgeClient._check_method_capability("create_box", {
            "ruby_extension_version": "0.4.0", "capabilities": ["geometry.primitive.v1", None]})


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
