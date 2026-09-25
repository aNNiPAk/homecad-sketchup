# M3 Architecture decisions

## Implementation plan

1. Strengthen the RBZ contents regression test for all shipped runtime files.
2. Add JSON-backed architecture parameters and relationship metadata without changing the base HomeCAD metadata schema.
3. Implement wall validation, a reusable wall-local frame, and deterministic wall shell regeneration.
4. Add hosted opening, door, window, and niche objects; validate bounds and cut collisions before opening an operation.
5. Add rectangular columns and generic parameter-driven architecture updates/deletes.
6. Add ordered room boundary validation, room-side derivation, and read-only conservative room detection.
7. Advertise `architecture.core.v1`, expose typed MCP tools with annotations, and preserve one-operation mutation results.
8. Add Ruby/Python/fixture coverage, disposable SketchUp smoke, packaging assertions, contracts, README, changelog, and version 0.5.0.

## Decisions

- M3 architecture objects are generated domain objects. Their editable source of truth is validated parameters and relationships; tools regenerate their geometry. Primitive tools must continue to reject generated domain objects.
- Walls remain root-level managed Groups. Updates preserve the root entity and HomeCAD identity while regenerating only its internal geometry.
- `WallFrame` uses world `start_mm` as origin, U along the normalized horizontal baseline, global +Z as Z, and V = Z × U. Therefore U × V = Z. Wall-local extents are U `[0,length]`, V `[-thickness/2,+thickness/2]`, and Z `[0,height]`.
- Hosted rectangular objects store a lower-left wall-local anchor: `offset_mm` is U, `bottom_mm` is Z, and `depth_offset_mm` is signed V. Width advances +U and height advances +Z. Side is one of `center`, `positive_v`, or `negative_v`; no room-relative aliases are accepted.
- Through cuts and partial-depth niches are regenerated from the host wall parameters and all hosted cut parameters. They do not use Solid Tools. The hosted object remains a separate semantic root object with a `wall_id` relationship.
- Room boundaries preserve the caller's ordered wall IDs. Their directed endpoints must close within the architecture point tolerance and form a simple loop. Room-facing side is derived from polygon winding and each wall's stored U direction; it is stored as a relationship result, not inferred later from world XYZ.
- `detect_rooms` only reports simple loops from snapped endpoints of root HomeCAD walls. It never creates metadata or Room objects; non-degree-two topology is reported as a warning.
- SketchUp Model remains the project root. M3 does not create an Apartment container or reparent existing model content.
- JSON strings are used for nested architecture parameter and relationship values in the HomeCAD AttributeDictionary. Frequently queried `wall_id` remains a distinct relationship attribute. Base metadata keys (`homecad_id`, `type`, `schema_version`, `revision`, `generated`) remain owned by `HomeCAD::Metadata`.
- Each public mutation validates its complete proposed state before starting `HomeCAD::Operation.run`. Geometry, metadata, dependent regeneration, result serialization, and revisions are committed atomically as one SketchUp Undo operation.

## SketchUp API findings

- `Sketchup::Entities#add_face` creates faces directly in a chosen drawing context, and `#erase_entities` removes selected generated entities. Wall geometry can therefore be created and regenerated inside the preserved root Group.
- `Sketchup::Group#split` returns `[other - self, self - other, intersection]`, but deletes both original operands and is unavailable in SketchUp Make. It is unsuitable for walls or semantic hosted cuts.
- Group boolean APIs require manifold solids and are not used by the architecture wall generator.
- `Geom::Transformation.axes(origin, xaxis, yaxis, zaxis)` represents the local frame for Group placement. Public coordinates remain millimeters and are converted only through `HomeCAD::Units`.

Official API references:

- [Sketchup::Entities](https://ruby.sketchup.com/Sketchup/Entities.html)
- [Sketchup::Group](https://ruby.sketchup.com/Sketchup/Group.html)
- [Geom::Transformation](https://ruby.sketchup.com/Geom/Transformation.html)

## References reviewed

Reference checkouts were inspected at these commits. No source code is copied; SidhNor is architectural reference only.

| Repository | Commit | M3 relevance |
| --- | --- | --- |
| `zinin/sketchup-mcp2` | `70c6edb50f4edbeaacdda1726ce93c4ba46fc1c0` | Existing transport/undo/runtime patterns; no domain model reused. |
| `Shattenjagger/sketchup-mcp-bridge` | `c7ee20c1f01a691dfdd903df7aa46b49b827b830` | Minimal bridge and SketchUp runtime reference. |
| `darwin/supex` | `66c9eed0921c418be3f1bd4ef5f100f6b5f2ad4c` | Ruby operation and geometry test patterns. |
| `Tarkiin/SketchUp-MCP` | `a47ca45d9568f175d0d2aed5320713fb3b272e37` | Primitive geometry patterns only; M3 remains domain-first. |
| `mhyrr/sketchup-mcp` | `aa096f04d3d7b22a70860368f2b576343feac405` | No M3 implementation reused. |
| `SidhNor/sketchup-mcp-server` | `75b851cbfb145fdfb444ed4c769216095c655c02` | Architecture/reference concepts and tests inspected; AGPL code not copied. |

