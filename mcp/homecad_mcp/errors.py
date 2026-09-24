"""Bridge errors remain independent of the MCP SDK."""


class BridgeError(Exception):
    def __init__(self, category: str, message: str, code: int | None = None):
        super().__init__(message)
        self.category = category
        self.message = message
        self.code = code

    def as_dict(self) -> dict[str, object]:
        result: dict[str, object] = {"category": self.category, "message": self.message}
        if self.code is not None:
            result["code"] = self.code
        return result
