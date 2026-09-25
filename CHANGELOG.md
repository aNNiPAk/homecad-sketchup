# Changelog

## Unreleased

### Added

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
- Bumped the pre-1.0 version to 0.4.1 for M2.1 correctness fixes. The public tool set and capability remain unchanged.
- M2 remains a low-level fallback; no Architecture, Furniture, Kitchen, Electrical, Lighting, or `eval_ruby` tools were added.

### Fixed

- Camera snapshots now include perspective FOV orientation and reject a capture before changing the viewport when the Ruby API cannot reproduce that orientation.
- Capture now reconstructs an independent camera snapshot before changing the view, restores it without a transition, and frames model bounds without invoking `View#zoom_extents`.
- The M1 smoke script can use a single selected unnamed object when `--name` is absent or has no match, and reports expected errors without an `ExceptionGroup` traceback.
- Python MCP refuses `capture_view` against a bridge that does not advertise `view.capture.v1` while keeping M0 status calls available.
