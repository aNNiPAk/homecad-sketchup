# HomeCAD for SketchUp

HomeCAD is a local MCP interface for inspecting and safely editing a SketchUp scene. M2 adds a low-level primitive geometry layer; it is a developer/fallback API, not the future architecture or furniture interface. The roadmap is in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Requirements

- Windows with SketchUp and Ruby extension support. The installed RBZ must be updated for M2.
- [uv](https://docs.astral.sh/uv/) with Python 3.11+ for MCP and packaging.
- Ruby 3.x for standalone Ruby tests; SketchUp supplies its own runtime when the extension is installed.

## Build and install

From PowerShell in this repository:

```powershell
uv sync --project mcp
uv run --project mcp python scripts/build_rbz.py
```

Install `dist\homecad.rbz` with **SketchUp → Extensions → Extension Manager → Install Extension**, then restart SketchUp. The Ruby Console should show `[HomeCAD] INFO listening on 127.0.0.1:37941`. Confirm that `homecad_status.ruby_extension_version` says `0.4.2` and that it advertises `geometry.primitive.v1` before running the M2 smoke test.

The M0 connection check remains available:

```powershell
uv run --project mcp python scripts/smoke_mcp.py
```

To run the complete M1 inspection smoke test, select exactly one Group or ComponentInstance in SketchUp, then run:

```powershell
uv run --project mcp python scripts/smoke_m1.py
```

The script first checks that SketchUp has loaded the matching RBZ, then reads model information, lists a bounded page, finds and inspects the selected object, measures its dimensions, reads selection, captures top and iso views, and rereads the camera after each capture. PNGs are saved under ignored `dist\m1-smoke\`. `--name "Exact known object name"` is optional; if it has no match, the script explicitly falls back to the single selected object. Ambiguous names produce a short error. The script does not invoke `undo` because that would modify the open model's history.

For an MCP host, configure a stdio server with command `uv` and arguments `run --project D:\GitHub\homecad-sketchup\mcp python -m homecad_mcp` (replace the checkout path as needed). The `capture_view` tool returns an MCP `image/png` block alongside JSON metadata, so an image-capable host can display it directly.

## Scene inspection contract

- `list_objects` reads only one collection: root, active edit context, or immediate children of `parent`. Face/Edge topology is omitted unless explicitly filtered by `entity_type`. `limit` is 1–100, `offset` is nonnegative; the response includes `total` and `has_more`.
- `find_objects` filters by HomeCAD ID, persistent ID, entity ID, SketchUp type, HomeCAD type, name, tag, parent ID, room ID, or existing HomeCAD metadata. It returns `none`, `unique`, `ambiguous`, or `multiple`. `get_object`, `measure`, and targeted capture reject ambiguous targets. For shared component definitions, include the returned `identity.instance_path` when targeting a placement.
- All entity outputs share the same identity and serializer. `homecad_id` may be null on ordinary SketchUp objects; `persistent_id` and `entity_id` are returned when available. Inspection never assigns HomeCAD metadata to existing entities.
- `measure` returns a structured kind, targets, value, and unit. Distances and bbox dimensions are mm, area is mm². `bbox_dimensions_mm` and `measure(kind="bbox_dimensions")` describe world-aligned axis-aligned bounds, not local or parametric dimensions; rotation can increase these values. `bbox_distance` is the minimum distance between boxes, not a mesh collision test.
- `capture_view` accepts `current`, `top`, `front`, `back`, `left`, `right`, `iso`, plus `zoom_extents`, `target`, `max_size` (64–1600) and `restore_camera` (default true). Targeted capture frames the resolved placement's world bounds. It includes `camera_before`, `camera_after`, and `camera_restored` in metadata, including perspective FOV orientation. Capture rejects a changed camera if SketchUp's Ruby API cannot reconstruct its FOV orientation safely. Target and `zoom_extents` cannot be combined.
- `undo` queues exactly one native SketchUp Undo action and returns `status: queued`. SketchUp's action API is asynchronous; the response does not claim completion.

The full request and response shape is in [the M1 contract](tests/contracts/m1.md). Design decisions and reviewed reference commits are in [M1 decisions](docs/M1_DECISIONS.md); the versioned capability handshake is recorded in [ADR 0001](docs/decisions/0001-capability-handshake.md).

## Primitive geometry (M2)

Primitive tools are a low-level fallback. Public coordinates and lengths use millimeters, angles use degrees, points are `[x_mm, y_mm, z_mm]`, and all M2 points use world coordinates. Created objects are each contained by a managed root Group with a HomeCAD UUID. `push_pull` and `follow_me` accept only an unambiguous Face inside a root Group; shared component definitions are rejected. `push_pull` also rejects parent transforms containing scale, shear, or reflection so the requested millimeter distance remains correct in world space. `transform_object` accepts root Groups and component instances. Boolean operations require manifold solids, create a new managed result, and preserve both sources. `difference` means exactly `target - tool`; `tool.subtract(target)` was verified by the asymmetric SketchUp 26.2.243 smoke. The API summary conflicts on receiver/argument direction, and the smoke caught the prior `split` selection returning reverse bounds. Boolean temporary copies are removed before commit. Follow Me removes path edges only when they have no attached faces; edges shared with swept surfaces remain as topology and are reported in `warnings`. Every call runs as one SketchUp operation and returns the shared `status/operation/created/updated/deleted/warnings/revision` envelope.

MCP clients must check `geometry.primitive.v1`. Creation calls are non-idempotent; target mutations are destructive hints. Annotations are advisory only.

Run the mutating smoke only after opening a disposable/test model. It checks box transform/Undo, asymmetric boolean subtraction, ordinary push/pull, scaled push/pull rejection, and an L-shaped Follow Me operation. It captures screenshots and undoes every created object:

```powershell
uv run --project mcp python scripts/smoke_m2.py --confirm-disposable
```

Screenshots are written under `dist\m2-smoke*.png`. The script reports model modified state before and after and verifies test objects are gone. If cleanup fails, it reports that the disposable model may still contain test geometry.

MCP tools advertise standard behavior annotations: inspection and capture are read-only; `undo` is marked as state-changing and potentially destructive. These hints help clients present tools accurately but do not enforce safety.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `HOMECAD_PORT` | `37941` | Loopback TCP port. Set for both SketchUp and MCP before starting them. |
| `HOMECAD_TIMEOUT` | `30` | Python request timeout in seconds, >0 and <=120. |
| `HOMECAD_LOG_LEVEL` | `INFO` | Python logs to stderr; Ruby logs to its Console. |

The bridge binds only `127.0.0.1`, uses a 16 MiB frame cap for screenshots, and keeps the M0 four-byte framing and protocol version 1 handshake. The additive `hello` response advertises versioned capabilities; Python checks the capability required by each operation. An older bridge without capabilities can still answer `homecad_status`, while unsupported operations return `unsupported_operation`.

## Tests

```powershell
uv sync --project mcp --extra dev
uv run --project mcp --extra dev python -m pytest tests/python -q
ruby tests/ruby/test_m0.rb
ruby tests/ruby/test_targeting.rb
ruby tests/ruby/test_serializer.rb
ruby tests/ruby/test_inspection.rb
ruby tests/ruby/test_measurement.rb
ruby tests/ruby/test_capture.rb
ruby tests/ruby/test_undo.rb
ruby tests/ruby/test_mutation_core.rb
ruby tests/ruby/test_geometry_validation.rb
ruby tests/ruby/test_primitives.rb
ruby tests/ruby/test_mutations.rb
uv run --project mcp python scripts/build_rbz.py
```

The [GitHub Actions workflow](.github/workflows/ci.yml) runs Python, standalone Ruby, and RBZ packaging checks on pushes and pull requests; it does not require SketchUp. The Python suite includes a Python-to-Ruby bridge fixture and MCP stdio tests. Ruby tests use SketchUp API stand-ins. M1 inspection and M2 mutation smoke tests remain manual checks after installing the RBZ.
