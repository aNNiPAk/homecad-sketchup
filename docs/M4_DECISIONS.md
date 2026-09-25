# M4 Furniture Core decisions

## Implementation plan

1. Add a generic wall attachment projection/helper and parameter-backed Furniture metadata.
2. Add Cabinet validation, rigid local frames, bounded carcass/shelf/front generation, and derived part schedules.
3. Add world and wall placement, parameter update/delete, and generic relocation/deletion integration with Architecture Wall operations.
4. Expose typed MCP tools and `furniture.core.v1`; cover Ruby, Python, packaging, and cross-language behavior.
5. Add disposable SketchUp smoke, contracts, README/AGENTS/CHANGELOG updates, and version 0.6.0.

## Decisions

- Cabinet is a root-level generated Group. Its identity and root entity survive update; all editable state comes from validated `FurnitureData` parameters and its generated children are rebuilt only when Cabinet geometry parameters or detail level change.
- Cabinet local origin is back-left-bottom. X is width, Y runs from back to front, and Z runs bottom to top. The local case envelope is `[0,width] × [0,depth] × [0,height]`; X × Y = Z. Cabinet dimensions are geometry dimensions, never a root scale.
- World placement uses a horizontal rotation around global Z. Wall placement uses the M3 `WallFrame`. Positive V anchors at `offset_mm` and `+thickness/2 + clearance`; negative V anchors at `offset_mm + width_mm` and `-thickness/2 - clearance`, with X = -U and Y = -V so the Cabinet basis remains right-handed. Attachment parameters, not cached world coordinates, control placement after wall movement or direction reversal.
- `WallAttachment` is a shared projection of the host placement stored in Furniture parameters. The direct searchable `wall_id` and attachment index fields are synchronized from `placement` and Cabinet width on every write; `span_u_mm` is derived from `width_mm`, never independently editable. Detaching removes only these HomeCAD-owned attachment attributes.
- Wall updates preflight attached dependents and planned transforms before opening an operation. A valid update regenerates the Wall and architecture dependents, changes only the attached Cabinet root transform, and increments a Cabinet revision only when its effective transform changes. Wall cascade deletion includes attached objects in its dependency check and tombstones before erase.
- Construction detail uses independent nested Groups for carcass panels, shelves, and front panels. They have generated `furniture.part` metadata and stable logical `part_key` values, but no public HomeCAD UUID; nested SketchUp entity identity is not stable across regeneration. Primitive mutation policy rejects generated ancestors as well as generated targets.
- The carcass is frameless. Side panels span full case depth/height; top and bottom fit between sides; the back is near Y=0; shelves begin after back thickness. `shelf_z_mm` is the bottom elevation of each shelf and shelf thickness equals panel thickness.
- Construction fronts are solids starting at Y=depth and extending in +Y by their thickness. In concept detail, the Cabinet envelope remains exactly the requested case dimensions and configured fronts are represented by faces at Y=depth. `get_furniture_frame` always reports the parametric case envelope; `get_object` bounds include any construction front projection.
- `list_furniture_parts` is calculated from parameters and stable logical keys; it never depends on generated SketchUp child IDs or current detail level.
- M4 adds Furniture only. Kitchen composition, appliances, electrical, lighting, and arbitrary Ruby evaluation remain out of scope.

## Reference review

Reviewed current remote HEADs; no reference code was copied.

| Repository | Commit | Files/tests reviewed | Finding |
| --- | --- | --- | --- |
| `mhyrr/sketchup-mcp` | `aa096f04d3d7b22a70860368f2b576343feac405` | `examples/arts_and_crafts_cabinet.py`, `src/sketchup_mcp/server.py`, `test_eval_ruby.py`, README | README declares MIT but checkout has no LICENSE file. Cabinet example is raw-inch, one-off `eval_ruby` geometry; it is not a parameterized/tested Furniture layer and was not reused. |
| `zinin/sketchup-mcp2` | `70c6edb50f4edbeaacdda1726ce93c4ba46fc1c0` | `handlers/geometry.rb`, `test/test_geometry_builders.rb`, `test/test_operation_names.rb` | Bounded builders and failure-aware operation tests are useful patterns. No code copied. |
| `Tarkiin/SketchUp-MCP` | `a47ca45d9568f175d0d2aed5320713fb3b272e37` | `sketchup_plugin/sketchup_mcp_server.rb`, README, LICENSE | Monolithic entity-ID based bridge uses implicit SketchUp units; not suitable for HomeCAD domain geometry. No code copied. |
| `darwin/supex` | `66c9eed0921c418be3f1bd4ef5f100f6b5f2ad4c` | `stdlib/test/operation_test.rb`, `stdlib/src/supex_stdlib/operation.rb`, README, LICENSE | Recording-model operation tests clarify commit/abort expectations. VCAD and broad runtime are unnecessary for M4. No code copied. |

The official [SketchUp Ruby API](https://ruby.sketchup.com/) is authoritative. The implementation uses `Sketchup::Entities#add_group`, `#add_face`, and `#clear!`, `Sketchup::Entity#delete_attribute`, and `Geom::Transformation.axes` to keep generated geometry in a stable local frame with a rigid root transform.

## Verification boundary

Standalone tests validate parameter calculations, frames, attachment planning, logical part schedules, mutation atomicity, and tool contracts. They do not prove the SketchUp kernel's face closure, visible panel orientation, or native Undo behavior. Run `scripts/smoke_m4.py --confirm-disposable` on a disposable model after installing the matching RBZ.
