# Changelog

## Unreleased

### Added

- M6 Electrical points in explicit Wall/world frames, model-level UUID circuits, atomic membership management, occupied-cell support checks and full 3D HomeCAD volume collision findings. Adds electrical.points.v1 and electrical.circuits.v1.

- M5.7 original versioned hardware catalog, read-only drawer planning, generic wooden drawer panels within Cabinet, and explicit slide-pair cutlist records under `furniture.hardware.v1`.

- Hardware research report consolidating catalog findings, dynamic data, manufacturer calculation examples, and the direction for an original parametric HomeCAD library.

- Component storage research comparing lossless SKP archives with HCG1 and recommending catalog metadata, compressed delivery, and a native SKP cache.

- Read-only analysis of Blum Dynamic Component dictionaries, formulas, material markers, and deduplicated storage estimates for the HCG1 research.

- Research-only HCG1 geometry/instance codec and benchmark report for compact Blum hardware catalogs; no HomeCAD runtime integration or third-party models are included.

- M5.6 opt-in continuous L-shaped countertop with bounded rectangular cutouts, square/beveled free ends, semantic end panels, and conceptual shaped-panel cutlist records under `kitchen.variants.v1`.

- M5.5 L-shaped two-Wall `kitchen.run` planning and generated void/blind-cabinet corners, multi-Wall dependency checks, stable semantic child IDs, and additive `kitchen.corner_run.v1`.

- M5.4 parameter-derived, paginated Cabinet and KitchenRun cutlists with materials, grain, four edge sides, explicit hardware and honest concept-only warnings under `manufacturing.cutlist.v1`.

- M5.3 project-level Cabinet defaults and an original versioned Cabinet preset catalog with explicit overrides and atomic dependent regeneration under `project.defaults.v1` and `furniture.presets.v1`.

- M5.2 optional full-volume Kitchen service clearances in six directions, with cross-wall HomeCAD obstacle checks, cut-aware Walls, read-only structured findings, and an opt-in blocking constraint under `kitchen.service_zone.v1`.
- M5.1 Kitchen planning accepts explicit start/end clearances and bounded coverage, countertop, opening-clearance, and module-depth constraints.
- M5.1 semantic Kitchen child UUIDs and revisions survive regeneration; validation distinguishes appliance and wall-cabinet collisions using module bounds.
- M5 KitchenRun planning and application under `kitchen.run.v1`: ordered base, wall, and tall modules; bounded filler, concept countertop/plinth, current-plan checks, read-only validation, semantic updates/deletion, and guarded real SketchUp smoke.
- Windows development harness with a repository junction, disposable fixture marker, exact SketchUp process ownership, and fresh-process fast/packaged verification; destructive M2–M4 smokes now refuse unmarked models.
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

- Matched Python/Ruby version is 0.13.0 for M6; protocol stays 1. Cable routes, panels, consumers and engineering sizing are deferred to M6.1.

- M5.7.1 verifies generated drawer panel bounds against their parameter and cutlist dimensions in standalone and real SketchUp tests. Cabinet cutlists with drawers now warn that slide selection and clearance are project inputs without verified mounting compatibility.

- Bumped matched Python/Ruby extension version to 0.12.0 for M5.7; protocol remains 1.

- Bumped the matched Python/Ruby extension version to 0.11.0 for M5.6; protocol remains 1.

- Bumped the matched Python/Ruby extension version to 0.10.0 for M5.5; protocol remains 1.

- Bumped the matched Python/Ruby extension version to 0.9.0 for M5.4; protocol remains 1.

- Bumped the matched Python/Ruby extension version to 0.8.0 for M5.3; protocol remains 1.

- Bumped the matched Python/Ruby extension version to 0.7.1 for M5.2; protocol remains 1 and older `kitchen.run.v1` requests remain supported.
- Bumped the pre-1.0 version to 0.7.0 for the additive Kitchen capability and tools; protocol version remains 1.
- Set the minimum supported Python MCP SDK to 1.30, the version currently locked and tested by the project.
- Renamed generic entity `dimensions_mm` / `measure(kind="dimensions")` to `bbox_dimensions_mm` / `measure(kind="bbox_dimensions")`; both now state explicitly that values are world-aligned bounding-box extents. Bumped the pre-1.0 version to 0.3.0 for M1.1 and 0.4.0 for M2.
- Bumped the pre-1.0 version to 0.4.2 after the SketchUp 26.2 smoke exposed reversed bounds from the prior `split` result selection. The rebuilt `subtract` direction was confirmed by the asymmetric SketchUp 26.2.243 smoke.
- Bumped the pre-1.0 version to 0.5.0 for the additive Architecture domain capability and tool set. Protocol version remains 1.
- M2 remains a low-level fallback. M3 adds Architecture, M4 adds the Cabinet Furniture core, and M5 adds straight Kitchen runs; Electrical, Lighting, and `eval_ruby` are not included.
- Bumped the pre-1.0 version to 0.6.1 for the Cabinet geometry correction. Protocol version remains 1.
- Bumped the pre-1.0 version to 0.6.0 for the additive Furniture capability and Cabinet tools. Protocol version remains 1.

### Fixed

- M4 smoke screenshots now face the attached Cabinet from its wall side, keeping the cabinet visible instead of the host Wall obscuring it.
- M4 Furniture revisions now track canonical parameter changes, generic WallAttachment projections cover horizontal and vertical fit spans, Cabinet LOD/zero-back behavior is hardened, and concept fronts no longer overlap the case envelope face.
- Cabinet part extrusion now follows positive world Z regardless of face normal; right-side placement remains in millimeters without double conversion.
- Empty semantic hosted objects now retain stable SketchUp identity with a hidden construction-point anchor, and anchors follow wall regeneration.
- Room updates and dependent Wall regeneration now recalculate boundary points, area, Room-facing sides, relationships, and reference geometry from current ordered wall IDs.
- Camera snapshots now include perspective FOV orientation and reject a capture before changing the viewport when the Ruby API cannot reproduce that orientation.
- Capture now reconstructs an independent camera snapshot before changing the view, restores it without a transition, and frames model bounds without invoking `View#zoom_extents`.
- The M1 smoke script can use a single selected unnamed object when `--name` is absent or has no match, and reports expected errors without an `ExceptionGroup` traceback.
- Python MCP refuses `capture_view` against a bridge that does not advertise `view.capture.v1` while keeping M0 status calls available.
