# M5 Kitchen Core decisions

## M5.8 composition

See ADR 0006 for the accepted implementation sequence. Kitchen cabinet-like modules
derive construction geometry and manufacturing records through one
KitchenCabinetDefinition and Furniture.part_schedule. The shared Furniture generator
uses part origins instead of reading Cabinet metadata from a Kitchen semantic root.
New plans snapshot project thickness/material defaults; legacy unversioned module
records retain their effective fixed defaults when inspected or renamed.

### Composition and straight cutouts

The detailed contract is [M5.8](../tests/contracts/m58.md). New module definitions
snapshot project settings; layout defaults remain original HomeCAD concept values,
not manufacturer installation claims. Sink/hob housings omit their top panel;
dishwasher/fridge keep only an appliance envelope. Drawer front thickness is part
of the module outer depth, so shelves/drawers do not expand collision/service bounds.
Furniture Core remains the owner of all panel and drawer mathematics.

CountertopCutouts shares rectangle validation and inner-loop generation between
straight and L-shaped runs. Straight cuts use Wall U and outward-from-wall-face
coordinates, including negative-V placement. Cutouts are explicit and shaped tops
remain concept_shaped manufacturing records. Countertop descriptor changes preserve
UUID and increment its revision; a run name change leaves it untouched.

Native verification found that an appliance base Face can have a negative Z normal.
Appliance extrusion now uses the existing positive-Z Furniture helper, as do worktops.
The official [Face pushpull/loops API](https://ruby.sketchup.com/Sketchup/Face.html)
is the source of truth; fake geometry alone did not establish this behavior.

M6 source identity stays Kitchen-owned. Neighboring cabinet regeneration keeps
appliance UUID/type and Consumer membership; retyping/removing an appliance uses
the existing scoped DomainHooks cascade, without a Kitchen-to-Electrical dependency.

### M5.8 verification

On 2026-10-09, the runtime/smoke implementation committed through d4fa701 was verified
with M5 --fast, M5 --packaged and M6 --packaged on fresh dedicated SketchUp 26.2.243
processes, version 0.15.0.
Each packaged run passed 24 commands: Python 80 tests, 22 standalone Ruby files
(895 test runs / 9449 assertions including inherited regressions), and RBZ build.
Both native smokes exited 0, completed Undo cleanup and restored dev links with no
cleanup errors. CI for d4fa701 also passed (GitHub Actions run 37928784055).

Native M5 measured generated cabinet part bounds against the cutlist, confirmed
appliance outer bounds, two real straight countertop holes by Face area, and the
existing L-shaped hole after shared generator extraction. Shelf/drawer updates,
stable semantic identities, invalid-cut rejection and Undo were checked. M6
confirmed source UUID preservation and retype cascade with Consumer restoration
through Undo. The focused Ruby regression additionally changes neighboring cabinet
internals while checking that its appliance Consumer remains unchanged.

Reviewed front/iso/top images show shelves inside the case, two drawer fronts
distinct from open shelf cases, appliance alignment, real straight holes and one
continuous L countertop with its hole. Closed fronts obscure internal drawer panels
in these views; their dimensions/placement are verified by native measurements,
not inferred from pixel variation. Pictures/reports remain ignored local artifacts.

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

## M5.6 countertop and panel variants

The existing one-Wall API and `kitchen.run.v1` remain unchanged. L-shaped runs gain explicit optional `countertop` and `panels` inputs under `kitchen.variants.v1`. Omitting them retains the M5.5 no-countertop behavior. The countertop is a single L-shaped face extruded once, with rectangular inner loops for cutouts. Free outer tips can be square or beveled. Each cutout is wholly inside one arm, at least 10 mm from its border, and cutouts cannot overlap. The official [Face API](https://ruby.sketchup.com/Sketchup/Face.html) documents creating a hole by adding an inner face then erasing it; generation checks the resulting loop count before extrusion. SketchUp kernel behavior is verified by packaged smoke, not inferred from the standalone fake.

End panels are semantic generated children with material, grain, edge and SKU inputs. The shaped countertop has a conceptual cutlist record with polygon and cutout coordinates; its two arm extents are not a rectangular fabrication blank. Fabrication of joints, sink support, grain continuity and edge finishing needs project-specific confirmation. No EasyKitchen geometry or formulas were copied. All variant dimensions are explicit project values, not regulatory defaults. A Wall update replans both arms, including cutouts and panels, before the one Undo operation.
