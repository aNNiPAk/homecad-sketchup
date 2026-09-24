# HomeCAD for SketchUp

HomeCAD is an MCP interface for apartment design in SketchUp. M0 provides a read-only bootstrap bridge with exactly two tools: `homecad_status` and `get_model_info`. Geometry and domain objects belong to later milestones in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Requirements

- Windows with SketchUp and its Ruby extension support (runtime validation in SketchUp is still required).
- [uv](https://docs.astral.sh/uv/) and Python 3.11+ for the MCP server and RBZ builder.
- Ruby 3.x to run the standalone Ruby tests; SketchUp includes its own Ruby runtime for the installed extension.

## Build and install on Windows

From PowerShell in the repository root:

```powershell
uv sync --project mcp
uv run --project mcp python scripts/build_rbz.py
```

Install `dist\homecad.rbz` through **SketchUp → Extensions → Extension Manager → Install Extension**, then restart SketchUp or enable the extension. The Ruby side starts its loopback listener when the extension loads. The Ruby Console shows `[HomeCAD] INFO listening on 127.0.0.1:37941` if startup succeeds.

Run the first MCP smoke test while SketchUp is open:

```powershell
uv run --project mcp python scripts/smoke_mcp.py
```

The script starts the Python MCP server over stdio, lists its two tools, calls `homecad_status` and `get_model_info`, and prints their JSON responses. `homecad_status.connection_status` should be `connected`. When SketchUp is absent, status includes an actionable `connection_error` and `get_model_info` returns an MCP tool error.

To connect a host such as Codex, configure an MCP stdio server with command `uv` and arguments `run --project D:\GitHub\homecad-sketchup\mcp python -m homecad_mcp` (replace the checkout path if different). The host should then see only `homecad_status` and `get_model_info`.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `HOMECAD_PORT` | `37941` | Loopback TCP port; set it for both SketchUp and the MCP process before starting them. |
| `HOMECAD_TIMEOUT` | `5` | Python end-to-end request timeout in seconds, >0 and <=120. |
| `HOMECAD_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARN`, or `ERROR`; Python logs to stderr and Ruby logs to its console. |

The bridge binds only `127.0.0.1`, enforces a 1 MiB frame limit and requires a version handshake. Its tools do not change the active model. Details and reviewed source commits are in [M0 decisions](docs/M0_DECISIONS.md); the exact request envelope is in [the M0 contract](tests/contracts/m0.md).

## Tests

```powershell
uv run --project mcp --extra dev python -m pytest tests/python -q
ruby -I sketchup tests/ruby/test_m0.rb
```

The Python suite includes a real Python-to-Ruby TCP test and an MCP stdio startup test. The Ruby suite uses a small SketchUp stand-in; neither substitutes for the manual SketchUp smoke test.
