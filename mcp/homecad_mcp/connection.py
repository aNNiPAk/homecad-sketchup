"""One-tool-call TCP connection with JSON-RPC handshake and bounded frames."""

import asyncio
import json
import logging
import re
import struct
from typing import Any

from . import PROTOCOL_VERSION, VERSION
from .config import Config
from .errors import BridgeError

logger = logging.getLogger(__name__)

METHOD_CAPABILITIES = {
    "get_model_info": "model.info.v1",
    "list_objects": "scene.inspect.v1",
    "find_objects": "scene.inspect.v1",
    "get_object": "scene.inspect.v1",
    "get_selection": "scene.inspect.v1",
    "measure": "scene.measure.v1",
    "capture_view": "view.capture.v1",
    "undo": "scene.undo.v1",
    "create_group": "geometry.primitive.v1",
    "create_face": "geometry.primitive.v1",
    "create_edge": "geometry.primitive.v1",
    "create_box": "geometry.primitive.v1",
    "create_circle": "geometry.primitive.v1",
    "create_arc": "geometry.primitive.v1",
    "create_polygon": "geometry.primitive.v1",
    "push_pull": "geometry.primitive.v1",
    "follow_me": "geometry.primitive.v1",
    "transform_object": "geometry.primitive.v1",
    "boolean_operation": "geometry.primitive.v1",
    "get_wall_frame": "architecture.core.v1",
    "create_wall": "architecture.core.v1",
    "create_opening": "architecture.core.v1",
    "create_door": "architecture.core.v1",
    "create_window": "architecture.core.v1",
    "create_niche": "architecture.core.v1",
    "create_column": "architecture.core.v1",
    "update_architecture_object": "architecture.core.v1",
    "delete_architecture_object": "architecture.core.v1",
    "create_room": "architecture.core.v1",
    "detect_rooms": "architecture.core.v1",
    "get_furniture_frame": "furniture.core.v1",
    "list_furniture_parts": "furniture.core.v1",
    "create_cabinet": "furniture.core.v1",
    "update_furniture_object": "furniture.core.v1",
    "delete_furniture_object": "furniture.core.v1",
    "get_project_settings": "project.defaults.v1",
    "update_project_settings": "project.defaults.v1",
    "list_furniture_presets": "furniture.presets.v1",
    "get_furniture_preset": "furniture.presets.v1",
    "create_cabinet_from_preset": "furniture.presets.v1",
    "generate_cutlist": "manufacturing.cutlist.v1",
    "plan_kitchen_run": "kitchen.run.v1",
    "plan_corner_kitchen_run": "kitchen.corner_run.v1",
    "apply_kitchen_run": "kitchen.run.v1",
    "validate_kitchen": "kitchen.run.v1",
    "update_kitchen_run": "kitchen.run.v1",
    "delete_kitchen_run": "kitchen.run.v1",
}


def encode_frame(payload: dict[str, Any], limit: int) -> bytes:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if not 1 <= len(body) <= limit:
        raise BridgeError("invalid_request", "request frame length out of range")
    return struct.pack(">I", len(body)) + body


async def read_frame(reader: asyncio.StreamReader, limit: int) -> dict[str, Any]:
    length = struct.unpack(">I", await reader.readexactly(4))[0]
    if not 1 <= length <= limit:
        raise BridgeError("invalid_response", f"response frame length {length} out of range")
    try:
        decoded = json.loads((await reader.readexactly(length)).decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise BridgeError("invalid_response", "response is not valid UTF-8 JSON") from exc
    if not isinstance(decoded, dict):
        raise BridgeError("invalid_response", "response must be a JSON object")
    return decoded


def check_response(response: dict[str, Any], request_id: int) -> Any:
    if response.get("jsonrpc") != "2.0" or response.get("id") != request_id:
        raise BridgeError("invalid_response", "JSON-RPC version or response id mismatch")
    if "error" in response:
        error = response["error"]
        if not isinstance(error, dict):
            raise BridgeError("invalid_response", "malformed JSON-RPC error")
        data = error.get("data")
        category = data.get("category") if isinstance(data, dict) else None
        code = error.get("code")
        raise BridgeError(
            category if isinstance(category, str) else "remote_error",
            str(error.get("message", "SketchUp bridge error")),
            code if isinstance(code, int) else None,
        )
    if "result" not in response or not isinstance(response["result"], dict):
        raise BridgeError("invalid_response", "missing JSON-RPC result object")
    return response["result"]


class BridgeClient:
    def __init__(self, config: Config | None = None):
        self.config = config or Config.from_env()

    async def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        if method != "homecad_status" and method not in METHOD_CAPABILITIES:
            raise BridgeError("unsupported_operation", f"unsupported method: {method}")
        try:
            async with asyncio.timeout(self.config.timeout):
                return await self._call(method, params or {})
        except TimeoutError as exc:
            raise BridgeError("connection_error", "Timed out waiting for SketchUp bridge") from exc
        except (OSError, asyncio.IncompleteReadError) as exc:
            logger.warning("SketchUp bridge connection failed: %s", exc)
            raise BridgeError(
                "connection_error",
                f"Cannot reach SketchUp at {self.config.host}:{self.config.port}. "
                "Open SketchUp and enable the HomeCAD extension; check HOMECAD_PORT.",
            ) from exc

    async def _call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        reader, writer = await asyncio.open_connection(self.config.host, self.config.port)
        try:
            await self._send(writer, {
                "jsonrpc": "2.0", "id": 1, "method": "hello",
                "params": {"protocol_version": PROTOCOL_VERSION, "client_version": VERSION},
            })
            hello = check_response(await read_frame(reader, self.config.max_frame_bytes), 1)
            self._check_hello(hello)
            self._check_method_capability(method, hello, params)
            await self._send(writer, {
                "jsonrpc": "2.0", "id": 2, "method": method, "params": params,
            })
            result = check_response(await read_frame(reader, self.config.max_frame_bytes), 2)
            return result
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass

    async def _send(self, writer: asyncio.StreamWriter, request: dict[str, Any]) -> None:
        writer.write(encode_frame(request, self.config.max_frame_bytes))
        await writer.drain()

    @staticmethod
    def _check_hello(hello: dict[str, Any]) -> None:
        version = hello.get("ruby_extension_version")
        protocol = hello.get("protocol_version")
        valid = isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
        if protocol != PROTOCOL_VERSION or not valid or version.split(".")[0] != VERSION.split(".")[0]:
            raise BridgeError(
                "incompatible_version",
                f"Incompatible HomeCAD bridge: expected protocol {PROTOCOL_VERSION} "
                f"and extension {VERSION.split('.')[0]}.x.x; received protocol {protocol!r}, "
                f"extension {version!r}. Install the matching HomeCAD RBZ.",
                -32001,
            )

    @staticmethod
    def _check_method_capability(method: str, hello: dict[str, Any],
                                 params: dict[str, Any] | None = None) -> None:
        required = METHOD_CAPABILITIES.get(method)
        if required is None:
            return
        capabilities = hello.get("capabilities", [])
        if (not isinstance(capabilities, list)
                or any(not isinstance(capability, str) or not capability for capability in capabilities)):
            raise BridgeError(
                "invalid_response",
                "SketchUp bridge advertised malformed capabilities",
            )
        if required not in capabilities:
            raise BridgeError(
                "unsupported_operation",
                f"SketchUp bridge does not advertise required capability '{required}' for '{method}'. "
                "Install a HomeCAD RBZ that supports this operation and restart SketchUp.",
                -32601,
            )
        if BridgeClient._uses_service_zones(method, params or {}) and "kitchen.service_zone.v1" not in capabilities:
            raise BridgeError(
                "unsupported_operation",
                "SketchUp bridge does not advertise 'kitchen.service_zone.v1'. "
                "Install a HomeCAD RBZ with Kitchen service zones and restart SketchUp.",
                -32601,
            )
        if BridgeClient._uses_corner_run(method, params or {}) and "kitchen.corner_run.v1" not in capabilities:
            raise BridgeError(
                "unsupported_operation",
                "SketchUp bridge does not advertise 'kitchen.corner_run.v1'. "
                "Install a HomeCAD RBZ with L-shaped KitchenRun support and restart SketchUp.",
                -32601,
            )

    @staticmethod
    def _uses_corner_run(method: str, params: dict[str, Any]) -> bool:
        if method == "apply_kitchen_run":
            plan = params.get("plan")
            return isinstance(plan, dict) and isinstance(plan.get("params"), dict) and \
                plan["params"].get("layout_type") == "l_shaped"
        if method == "update_kitchen_run":
            changes = params.get("changes")
            return isinstance(changes, dict) and bool({"legs", "corner"} & changes.keys())
        return False

    @staticmethod
    def _uses_service_zones(method: str, params: dict[str, Any]) -> bool:
        if method in ("plan_kitchen_run", "plan_corner_kitchen_run"):
            values = params
        elif method == "apply_kitchen_run":
            plan = params.get("plan")
            values = plan.get("params", {}) if isinstance(plan, dict) else {}
        elif method == "update_kitchen_run":
            values = params.get("changes", {})
        else:
            return False
        if not isinstance(values, dict):
            return False
        modules = values.get("modules")
        constraints = values.get("constraints")
        direct = (isinstance(modules, list) and any(
            isinstance(item, dict) and "service_clearance_mm" in item for item in modules
        )) or (isinstance(constraints, dict) and constraints.get("require_service_clearance") is True)
        legs = values.get("legs")
        return direct or (isinstance(legs, list) and any(
            isinstance(leg, dict) and BridgeClient._uses_service_zones("plan_kitchen_run", leg)
            for leg in legs))
