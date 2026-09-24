# M1 Scene Inspection — plan and decisions

## Implementation plan

1. Add a shared identity, scene traversal, target resolver and entity serializer in Ruby. Test ambiguous and missing targets, native ID lookup, pagination and units.
2. Add the seven Ruby operations with structured validation and measurement results. Keep the M0 handshake, frame format and one-call connection lifecycle.
3. Expose the seven operations through Python MCP, returning `capture_view` as MCP `image/png`. Test error mapping, image conversion and cross-language calls.
4. Add a manual SketchUp smoke script, update user documentation and changelog, then run the complete suite.

## Scope and API choices

- `list_objects` inspects one collection at a time: root, current edit context, or the immediate children of a target. Face/edge topology is excluded unless `entity_type` requests it. Results have `limit` (1..100) and numeric `offset`; no recursive scene dump.
- `find_objects` accepts identity, SketchUp type, HomeCAD type, name, tag, parent identifier and HomeCAD metadata filters. Exact `persistent_id` or `entity_id` uses SketchUp's native lookup first; nested or metadata searches traverse with a finite visit/depth budget. Exhausting the budget raises `constraint_violation`, never a false `unique` or `none`.
- Native lookup returns a root object directly; a supplied `instance_path` walks only the named containers. Broad searches may visit up to 100,000 entities and 32 levels, then require narrower filters. No persistent custom index is maintained.
- `TargetResolver.resolve_one` is the future mutation entry point. It accepts an identity selector and an optional instance path, and raises `target_not_found` or `ambiguous_target` instead of selecting the first match. `find_objects` reports `none`, `unique`, `ambiguous` (identity collision or multiple placements) or `multiple` (ordinary broad query).
- The shared serializer emits one stable identity shape at `summary`, `standard`, and `detailed` levels. `get_selection` uses that serializer. Existing SketchUp entities are never assigned HomeCAD metadata by inspection.
- Dimensions and distances are millimeters; area is square millimeters. Bounds and center distances use world-aligned boxes. Closest bounding-box distance is a geometric lower bound, not a collision test. `Face#area(transform)` and `Edge#length(transform)` account for parent scaling.
- `capture_view` temporarily sets a camera, writes a PNG to a temporary file and returns bounded base64 over the existing JSON-RPC frame. Python converts it into MCP `image/png` content. The camera is restored in an `ensure` block by default. `max_size` is the longest image side, 64..1600 pixels. The frame limit is raised to 16 MiB for images; the four-byte framing and handshake remain unchanged.
- Camera metadata includes state before and after capture so the smoke script can verify restoration. The default Python request timeout is 30 seconds and the Ruby idle limit is 60 seconds to accommodate real model image export.
- Targeted capture frames the resolved placement's transformed world bounds. This also works for geometry inside a shared ComponentDefinition, where passing the underlying entity alone to `View#zoom` would lose placement context.
- `get_selection` is paginated and uses the active edit path to retain placement identity when SketchUp is editing a nested group or component. The active path is read only; no model metadata is written.
- `room_id` is matched only against existing HomeCAD metadata, as required by the implementation plan. No room object is created in M1.
- SketchUp has no documented `Model#undo`. The official `Sketchup.send_action('editUndo:')` enqueues one native Undo asynchronously, so `undo` returns `{status: 'queued', actions: 1}`. It cannot honestly promise the operation completed before the response.

## References reviewed

| Repository | Commit | Relevant implementation and tests | Adopted idea / rejected behavior |
| --- | --- | --- | --- |
| [zinin/sketchup-mcp2](https://github.com/zinin/sketchup-mcp2) | `70c6edb50f4edbeaacdda1726ce93c4ba46fc1c0` | `handlers/model.rb`, `handlers/view.rb`, `connection.py`; `test/test_view.rb`, `test/test_model_empty_bbox.rb`, `tests/test_screenshot.py`, `tests/test_connection.py` | Empty bounds become null, camera is restored on exception, MCP gets an image. Retain HomeCAD's fresh connection per call; no automatic retry for `undo`. |
| [darwin/supex](https://github.com/darwin/supex) | `66c9eed0921c418be3f1bd4ef5f100f6b5f2ad4c` | `runtime/src/supex_runtime/tools.rb`, `batch_screenshot.rb`; `runtime/test/test_get_entity.rb`, `test_batch_screenshot.rb` | Inspect selection and camera, test top-view up-vector. Do not use entityID-only lookup or paths as the user-facing screenshot result. |
| [SidhNor/sketchup-mcp-server](https://github.com/SidhNor/sketchup-mcp-server) | `75b851cbfb145fdfb444ed4c769216095c655c02` | `target_reference_resolver.rb`, `measure_scene_commands.rb`; resolver and measure request tests | Resolver independent from tools, explicit ambiguity and structured measurements. Architecture only; checkout license is AGPL-3.0 and no code is copied. |

The [official SketchUp Ruby API](https://ruby.sketchup.com/) is authoritative for [persistent IDs](https://ruby.sketchup.com/Sketchup/Entity.html), [native model lookup](https://ruby.sketchup.com/Sketchup/Model.html), [transformed face area](https://ruby.sketchup.com/Sketchup/Face.html), [transformed edge length](https://ruby.sketchup.com/Sketchup/Edge.html), [view image export](https://ruby.sketchup.com/Sketchup/View.html), [camera state](https://ruby.sketchup.com/Sketchup/Camera.html), and [asynchronous Undo action](https://ruby.sketchup.com/Sketchup.html).
