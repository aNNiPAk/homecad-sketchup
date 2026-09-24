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

    async def call(self, method: str) -> dict[str, Any]:
        if method not in ("homecad_status", "get_model_info"):
            raise BridgeError("unsupported_operation", f"unsupported method: {method}")
        try:
            async with asyncio.timeout(self.config.timeout):
                return await self._call(method)
        except TimeoutError as exc:
            raise BridgeError("connection_error", "Timed out waiting for SketchUp bridge") from exc
        except (OSError, asyncio.IncompleteReadError) as exc:
            logger.warning("SketchUp bridge connection failed: %s", exc)
            raise BridgeError(
                "connection_error",
                f"Cannot reach SketchUp at {self.config.host}:{self.config.port}. "
                "Open SketchUp and enable the HomeCAD extension; check HOMECAD_PORT.",
            ) from exc

    async def _call(self, method: str) -> dict[str, Any]:
        reader, writer = await asyncio.open_connection(self.config.host, self.config.port)
        try:
            await self._send(writer, {
                "jsonrpc": "2.0", "id": 1, "method": "hello",
                "params": {"protocol_version": PROTOCOL_VERSION, "client_version": VERSION},
            })
            hello = check_response(await read_frame(reader, self.config.max_frame_bytes), 1)
            self._check_hello(hello)
            await self._send(writer, {
                "jsonrpc": "2.0", "id": 2, "method": method, "params": {},
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
