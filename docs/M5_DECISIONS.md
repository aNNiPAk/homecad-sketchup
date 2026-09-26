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
- Modules are generated child Groups with semantic type/key, without independent UUIDs. Appliance, sink and hob models are concept volumes; manufacturing detail and real countertop cutouts are outside this first Kitchen layer.
- The run root uses a rigid wall-relative transform and the generic WallAttachment projection. A Wall update can relocate the run without rescaling geometry. The run parameters remain canonical; generated children are never edited through primitives.
- A plan may leave unallocated wall length. An end filler is generated only when the gap is at most the bounded filler maximum. Validation reports missing countertop coverage and collisions conservatively.

## SketchUp API review

The official [SketchUp Ruby API](https://ruby.sketchup.com/) is the source of truth. `Sketchup::Entities#add_group` and `#add_face` support contained generated geometry; `Sketchup::Model#start_operation`, `#commit_operation`, and `#abort_operation` support one Undo action and rollback. `Geom::Transformation.axes` provides the rigid Wall-relative frame, and `Sketchup::Entity` attribute dictionaries store the run parameters. M5 does not depend on Solid Tools. No external Kitchen implementation or AGPL code was copied; Kitchen geometry and planning are HomeCAD original work built on the M3/M4 foundations.

The [Entities API](https://ruby.sketchup.com/Sketchup/Entities.html), [Model API](https://ruby.sketchup.com/Sketchup/Model.html), [Group API](https://ruby.sketchup.com/Sketchup/Group.html), and [Entity attribute API](https://ruby.sketchup.com/Sketchup/Entity.html) were consulted for this milestone.
