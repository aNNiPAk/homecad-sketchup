"""Call both M0 tools through the real MCP stdio interface."""

import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def smoke() -> None:
    params = StdioServerParameters(command=sys.executable, args=["-m", "homecad_mcp"])
    failed = False
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("tools:", ", ".join(tool.name for tool in tools.tools))
            for name in ("homecad_status", "get_model_info"):
                result = await session.call_tool(name, {})
                print(f"{name}:")
                for item in result.content:
                    if item.type == "text":
                        try:
                            print(json.dumps(json.loads(item.text), ensure_ascii=False, indent=2))
                        except json.JSONDecodeError:
                            print(item.text)
                if result.isError:
                    failed = True
                    break
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(smoke())
