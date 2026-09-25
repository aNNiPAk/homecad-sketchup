# Changelog

## Unreleased

### Added

- M4 Furniture Core: a parametric Cabinet with concept/construction detail, shelves, configurable fronts, stable local frame, parameter-derived part schedule, and wall-local placement under `furniture.core.v1`.
- Generic WallAttachment indexing and dependency handling; Wall updates relocate attached Cabinets after preflight, and cascaded Wall deletion returns Cabinet tombstones in the same Undo operation.
- M4 MCP tools, cross-language Cabinet fixture coverage, explicit RBZ packaging checks, and guarded disposable-model `smoke_m4.py`.
- M3 Architecture: generated Walls with local U/V/Z frames, hosted Openings/Doors/Windows/Niches, rectangular Columns, ordered Rooms, and conservative read-only room detection under `architecture.core.v1`.
- Architecture parameter/relationship storage, deterministic wall cut regeneration, hosted dependency validation, revision-aware generic updates/deletion, and a disposable SketchUp M3 smoke test.
- Python/Ruby M3 tool schemas, annotations, capability checks, cross-language fixture coverage, and explicit RBZ packaging assertions for the architecture runtime.
- M2.1 geometry correctness hardening: exact target-minus-tool boolean difference, world-safe push/pull checks, and guarded Follow Me path cleanup.
- M2 Primitive Geometry: managed group, face, edge, box, circle, arc and polygon creation; push/pull, follow-me, transforms, and manifold boolean operations.
- HomeCAD UUID metadata, object revisions, a shared mutation result envelope, `geometry.primitive.v1` capability, mutation annotations, Ruby regression tests, and a disposable-model M2 smoke script.
- CI coverage for all M2 standalone Ruby tests.
- GitHub Actions CI on pushes and pull requests for Python, standalone Ruby, and RBZ packaging checks; SketchUp is not required.
- MCP tool annotations, versioned bridge capabilities, and per-method Python capability checks.
- M1 Scene Inspection tools, MCP PNG viewport capture with camera restoration, and native Undo.
- M0 bootstrap with Python MCP server, SketchUp Ruby extension, local transport, handshake, tests, and RBZ packaging.

### Changed

- Set the minimum supported Python MCP SDK to 1.30, the version currently locked and tested by the project.
- Renamed generic entity `dimensions_mm` / `measure(kind="dimensions")` to `bbox_dimensions_mm` / `measure(kind="bbox_dimensions")`; both now state explicitly that values are world-aligned bounding-box extents. Bumped the pre-1.0 version to 0.3.0 for M1.1 and 0.4.0 for M2.
- Bumped the pre-1.0 version to 0.4.2 after the SketchUp 26.2 smoke exposed reversed bounds from the prior `split` result selection. The rebuilt `subtract` direction was confirmed by the asymmetric SketchUp 26.2.243 smoke.
- Bumped the pre-1.0 version to 0.5.0 for the additive Architecture domain capability and tool set. Protocol version remains 1.
- M2 remains a low-level fallback. M3 adds Architecture and M4 adds the Cabinet Furniture core; Kitchen, Electrical, Lighting, and `eval_ruby` are not included.
- Bumped the pre-1.0 version to 0.6.1 for the Cabinet geometry correction. Protocol version remains 1.
- Bumped the pre-1.0 version to 0.6.0 for the additive Furniture capability and Cabinet tools. Protocol version remains 1.

### Fixed

- M4 Furniture revisions now track canonical parameter changes, generic WallAttachment projections cover horizontal and vertical fit spans, and Cabinet LOD/zero-back behavior is hardened.
- Cabinet part extrusion now follows positive world Z regardless of face normal; right-side placement remains in millimeters without double conversion.
- Empty semantic hosted objects now retain stable SketchUp identity with a hidden construction-point anchor, and anchors follow wall regeneration.
- Room updates and dependent Wall regeneration now recalculate boundary points, area, Room-facing sides, relationships, and reference geometry from current ordered wall IDs.
- Camera snapshots now include perspective FOV orientation and reject a capture before changing the viewport when the Ruby API cannot reproduce that orientation.
- Capture now reconstructs an independent camera snapshot before changing the view, restores it without a transition, and frames model bounds without invoking `View#zoom_extents`.
- The M1 smoke script can use a single selected unnamed object when `--name` is absent or has no match, and reports expected errors without an `ExceptionGroup` traceback.
- Python MCP refuses `capture_view` against a bridge that does not advertise `view.capture.v1` while keeping M0 status calls available.
