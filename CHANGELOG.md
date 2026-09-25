# Changelog

## Unreleased

### Added

- M2 Primitive Geometry: managed group, face, edge, box, circle, arc and polygon creation; push/pull, follow-me, transforms, and manifold boolean operations.
- HomeCAD UUID metadata, object revisions, a shared mutation result envelope, `geometry.primitive.v1` capability, mutation annotations, Ruby regression tests, and a disposable-model M2 smoke script.
- CI coverage for all M2 standalone Ruby tests.

### Changed

- Set the minimum supported Python MCP SDK to 1.30, the version currently locked and tested by the project.
- Renamed generic entity `dimensions_mm` / `measure(kind="dimensions")` to `bbox_dimensions_mm` / `measure(kind="bbox_dimensions")`; both now state explicitly that values are world-aligned bounding-box extents. Bumped the pre-1.0 version to 0.3.0 for M1.1 and 0.4.0 for M2.
- Added the M2 primitive API as a low-level fallback; it does not introduce Architecture, Furniture, Kitchen, Electrical, Lighting, or `eval_ruby` tools.

### Fixed

- Camera snapshots now include perspective FOV orientation and reject a capture before changing the viewport when the Ruby API cannot reproduce that orientation.
- Capture now reconstructs an independent camera snapshot before changing the view, restores it without a transition, and frames model bounds without invoking `View#zoom_extents`.
- The M1 smoke script can use a single selected unnamed object when `--name` is absent or has no match, and reports expected errors without an `ExceptionGroup` traceback.
- Python MCP refuses `capture_view` against a bridge that does not advertise `view.capture.v1` while keeping M0 status calls available.

### Added

- Added GitHub Actions CI on pushes and pull requests for Python, standalone Ruby, and RBZ packaging checks; SketchUp itself is not required.
- Added MCP tool annotations for read-only scene inspection and state-changing native Undo.
- Added advertised, versioned bridge capabilities and per-method Python capability checks; `homecad_status` remains available without feature capabilities.
- M1 Scene Inspection: bounded `list_objects`, explicit `find_objects` resolution, normalized `get_object` and `get_selection`, and structured `measure`.
- Top/front/back/left/right/iso/current viewport capture with MCP PNG output and camera restoration; one native Undo action.
- Shared HomeCAD/persistent/entity identity and instance paths, scene resolver, serializer, Ruby and Python coverage, and Windows M1 smoke script.
- M0 bootstrap: `homecad_status` and `get_model_info` through a Python MCP server and a local SketchUp Ruby bridge.
- Version and protocol handshake, bounded transport, errors, logging, configuration, operation helper, tests and RBZ packaging.
