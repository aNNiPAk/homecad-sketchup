"""Configuration shared by MCP tools and the local TCP client."""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = 37941
    timeout: float = 5.0
    max_frame_bytes: int = 16 * 1024 * 1024

    @classmethod
    def from_env(cls) -> "Config":
        try:
            port = int(os.environ.get("HOMECAD_PORT", "37941"))
            timeout = float(os.environ.get("HOMECAD_TIMEOUT", "5"))
        except ValueError as exc:
            raise ValueError("HOMECAD_PORT must be an integer and HOMECAD_TIMEOUT a number") from exc
        if not 1 <= port <= 65535:
            raise ValueError("HOMECAD_PORT must be 1..65535")
        if not 0 < timeout <= 120:
            raise ValueError("HOMECAD_TIMEOUT must be >0 and <=120 seconds")
        return cls(port=port, timeout=timeout)
