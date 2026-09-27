# M5 Kitchen Core decisions

## Implementation plan

1. Reuse the M3 Wall frame and M4 Cabinet generator for a managed KitchenRun.
2. Add a read-only bounded planner, then apply only a current conflict-free plan in one HomeCAD operation.
3. Regenerate run modules, countertop, filler, and plinth from canonical run parameters; add read-only validation.
4. Expose Kitchen capability and MCP methods, cover contracts, packaging, standalone and real SketchUp verification.

## Initial contract

- A `kitchen.run` is one root-level generated Group with a HomeCAD UUID. `Kitchen` is the project-level concept, not a parent Group around the model.
- A run is on one HomeCAD Wall side and one tier: `base`, `wall`, or `tall`. Wall U offsets are in millimeters. Modules are ordered by increasing Wall U. This restriction keeps validation and worktop coverage deterministic.
- The plan is read-only and contains normalized input, calculated module positions, optional end filler, warnings, conflicts, and the Wall revision. Applying revalidates against the current model and rejects stale plans.
- Modules are generated child Groups with semantic type/key and a stable UUID in M5.1. Appliance, sink and hob models are concept volumes; manufacturing detail and real countertop cutouts are outside this first Kitchen layer.
- The run root uses a rigid wall-relative transform and the generic WallAttachment projection. A Wall update can relocate the run without rescaling geometry. The run parameters remain canonical; generated children are never edited through primitives.
- A plan may leave unallocated wall length. An end filler is generated only when the gap is at most the bounded filler maximum. Validation reports missing countertop coverage and collisions conservatively.

## SketchUp API review

The official [SketchUp Ruby API](https://ruby.sketchup.com/) is the source of truth. `Sketchup::Entities#add_group` and `#add_face` support contained generated geometry; `Sketchup::Model#start_operation`, `#commit_operation`, and `#abort_operation` support one Undo action and rollback. `Geom::Transformation.axes` provides the rigid Wall-relative frame, and `Sketchup::Entity` attribute dictionaries store the run parameters. M5 does not depend on Solid Tools. No external Kitchen implementation or AGPL code was copied; Kitchen geometry and planning are HomeCAD original work built on the M3/M4 foundations.

The [Entities API](https://ruby.sketchup.com/Sketchup/Entities.html), [Model API](https://ruby.sketchup.com/Sketchup/Model.html), [Group API](https://ruby.sketchup.com/Sketchup/Group.html), and [Entity attribute API](https://ruby.sketchup.com/Sketchup/Entity.html) were consulted for this milestone.

## M5.1 planning contract

`start_mm`/`end_mm` define the requested Wall U interval. Explicit `start_clearance_mm`/`end_clearance_mm` reserve its ends; `run_start_mm` is derived and controls the generated root WallAttachment. The planner normalizes a small `constraints` object and reports full-coverage, countertop-coverage, opening-clearance, and depth violations as conflicts. This keeps the read-only plan useful before a mutation and prevents applying a plan with an uncovered required worktop.

## M5.1 semantic identity and collision decisions

The run root remains the authority for editable module order and dimensions. `semantic_objects` is a derived identity/revision map keyed by stable module key or generated part role. UUIDs are assigned only during apply/update, never during read-only planning. A regenerated child receives the same HomeCAD UUID while SketchUp persistent/entity IDs may change. A type change under the same module key is a semantic update and increments that child's revision. Name-only run updates do not rebuild children; Wall relocation changes the root transform while preserving wall-local module parameters and child revisions. Nested semantic Groups are discovered through shared Targeting and serialized through the common entity serializer.

KitchenRun-vs-KitchenRun collisions compare bounded rectangles in Wall U/Z and outward depth rather than the coarse full-run WallAttachment span. Appliances and upper cabinets receive distinct conflict codes. Unknown wall attachments retain conservative span checks. This is a spatial check, not a SketchUp solid intersection test or a door-swing simulation.

## M5.2 service clearance decisions

Service clearances are explicit per-module, six-direction values in mm; no appliance type supplies a supposed regulatory default. The optional `require_service_clearance` constraint makes findings blocking, while the default reports them as structured findings plus a warning. The full expanded envelope minus the module body is decomposed into six slabs, then compared with HomeCAD volumes in world space. Broad-phase world bounds are followed by horizontal oriented-rectangle separation and vertical overlap; `Group#bounds` alone is not used as a rotated solid test. See the official [Drawingelement bounds API](https://ruby.sketchup.com/Sketchup/Drawingelement.html) and [Transformation API](https://ruby.sketchup.com/Geom/Transformation.html).

Wall occupied cells are shared with the wall shell generator so openings and niches remove obstacle volume consistently. Cabinets and Kitchen parts use their conceptual envelopes; a same-run countertop/plinth is treated as an intentional assembly part. The scan covers root HomeCAD Walls, Columns, Furniture Cabinets and Kitchen runs, and sibling modules/filler. It does not claim arbitrary SketchUp geometry coverage. `validate_kitchen` detects obstructions introduced by later foreign-domain mutations; M5.2 does not insert Kitchen preflight into every Architecture/Furniture mutation. Existing `kitchen.run.v1` stays available and new requests are gated by `kitchen.service_zone.v1`; 0.7.1 does not change protocol version.
