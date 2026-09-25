# HomeCAD for SketchUp

HomeCAD is a local MCP interface for inspecting an apartment scene in SketchUp. M1 provides `homecad_status`, `get_model_info`, `list_objects`, `find_objects`, `get_object`, `get_selection`, `measure`, `capture_view`, and `undo`. No drawing or domain creation tools are exposed yet. The roadmap is in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Requirements

- Windows with SketchUp and Ruby extension support. The installed RBZ must be updated for M1.
- [uv](https://docs.astral.sh/uv/) with Python 3.11+ for MCP and packaging.
- Ruby 3.x for standalone Ruby tests; SketchUp supplies its own runtime when the extension is installed.

## Build and install

From PowerShell in this repository:

```powershell
uv sync --project mcp
uv run --project mcp python scripts/build_rbz.py
```

Install `dist\homecad.rbz` with **SketchUp → Extensions → Extension Manager → Install Extension**, then restart SketchUp. The Ruby Console should show `[HomeCAD] INFO listening on 127.0.0.1:37941`. Confirm that `homecad_status.ruby_extension_version` says `0.2.1`; an earlier version still has the camera restoration bug.

The M0 connection check remains available:

```powershell
uv run --project mcp python scripts/smoke_mcp.py
```

To run the complete M1 inspection smoke test, select exactly one Group or ComponentInstance in SketchUp, then run:

```powershell
uv run --project mcp python scripts/smoke_m1.py
```

The script connects, reads model information, lists a bounded page, finds and inspects the selected object, measures its dimensions, reads selection, captures top and iso views, then rereads the camera after each capture. PNGs are saved under ignored `dist\m1-smoke\`. `--name "Exact known object name"` is optional; if it has no match, the script explicitly falls back to the single selected object. Ambiguous names produce a short error. The script does not invoke `undo` because that would modify the open model's history.

For an MCP host, configure a stdio server with command `uv` and arguments `run --project D:\GitHub\homecad-sketchup\mcp python -m homecad_mcp` (replace the checkout path as needed). The `capture_view` tool returns an MCP `image/png` block alongside JSON metadata, so an image-capable host can display it directly.

## Scene inspection contract

- `list_objects` reads only one collection: root, active edit context, or immediate children of `parent`. Face/Edge topology is omitted unless explicitly filtered by `entity_type`. `limit` is 1–100, `offset` is nonnegative; the response includes `total` and `has_more`.
- `find_objects` filters by HomeCAD ID, persistent ID, entity ID, SketchUp type, HomeCAD type, name, tag, parent ID, room ID, or existing HomeCAD metadata. It returns `none`, `unique`, `ambiguous`, or `multiple`. `get_object`, `measure`, and targeted capture reject ambiguous targets. For shared component definitions, include the returned `identity.instance_path` when targeting a placement.
- All entity outputs share the same identity and serializer. `homecad_id` may be null on ordinary SketchUp objects; `persistent_id` and `entity_id` are returned when available. Inspection never assigns HomeCAD metadata to existing entities.
- `measure` returns a structured kind, targets, value, and unit. Distances and dimensions are mm, area is mm². Bounding boxes are world-aligned; `bbox_distance` is the minimum distance between those boxes, not a mesh collision test.
- `capture_view` accepts `current`, `top`, `front`, `back`, `left`, `right`, `iso`, plus `zoom_extents`, `target`, `max_size` (64–1600) and `restore_camera` (default true). Targeted capture frames the resolved placement's world bounds. It includes `camera_before`, `camera_after`, and `camera_restored` in metadata. Target and `zoom_extents` cannot be combined.
- `undo` queues exactly one native SketchUp Undo action and returns `status: queued`. SketchUp's action API is asynchronous; the response does not claim completion.

The full request and response shape is in [the M1 contract](tests/contracts/m1.md). Design decisions and reviewed reference commits are in [M1 decisions](docs/M1_DECISIONS.md).

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `HOMECAD_PORT` | `37941` | Loopback TCP port. Set for both SketchUp and MCP before starting them. |
| `HOMECAD_TIMEOUT` | `30` | Python request timeout in seconds, >0 and <=120. |
| `HOMECAD_LOG_LEVEL` | `INFO` | Python logs to stderr; Ruby logs to its Console. |

The bridge binds only `127.0.0.1`, uses a 16 MiB frame cap for screenshots, and keeps the M0 four-byte framing and protocol version 1 handshake.

## Tests

```powershell
uv run --project mcp --extra dev python -m pytest tests/python -q
ruby tests/ruby/test_m0.rb
ruby tests/ruby/test_targeting.rb
ruby tests/ruby/test_serializer.rb
ruby tests/ruby/test_inspection.rb
ruby tests/ruby/test_measurement.rb
ruby tests/ruby/test_capture.rb
ruby tests/ruby/test_undo.rb
```

The Python suite includes a Python-to-Ruby bridge fixture and an MCP stdio test with image content. Ruby tests use SketchUp API stand-ins. The real SketchUp smoke test above is still required after installing the RBZ.
