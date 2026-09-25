# ADR 0004: Parametric Furniture Core

## Status

Accepted for M4.

## Context

Architecture objects are generated from semantic parameters and cannot be safely edited through primitive geometry tools. Furniture needs the same regeneration model while preserving a stable object identity and a local frame suitable for later host attachments.

## Decision

- M4 exposes one Furniture domain object, `furniture.cabinet`, behind `furniture.core.v1`.
- Cabinet parameters in `FurnitureData` are the source of truth. Construction detail regenerates nested part Groups; concept detail regenerates a case envelope and front planes. The root Group and `homecad_id` survive updates.
- Cabinet local origin is back-left-bottom; X is width, Y is back-to-front, and Z is up. The local frame is right-handed. Cabinet dimensions are generated geometry; the root transform contains only rigid placement.
- World placement is a millimeter origin plus global-Z angle. Wall placement stores a Wall UUID, U offset, base elevation, side, and clearance in Wall-local coordinates.
- `WallAttachment` is the generic dependency projection. Cabinet width determines its searchable U span. Wall changes are preflighted before the shared operation; valid changes relocate Cabinet roots while retaining wall-local parameters. Wall deletion requires cascade when attachments exist.
- The projection is domain independent and stores `wall_id`, U offset, base elevation, side, clearance, `span_u_mm`, and `span_z_mm`. Furniture derives spans from its canonical parameters before syncing the projection. Relocation code reads only this projection and proposed Wall frame/dimensions.
- Direct Furniture revision follows canonical semantic parameter changes, even when two placements resolve to the same world transform. Wall-induced relocation increments a dependent revision only when the effective root transform changes. No-op normalized updates do not open an operation; placement-only updates retain generated children.
- `back_thickness_mm` may be zero, in which case no back part or geometry is generated and shelves span from Y=0 to the Cabinet depth.
- Part schedules are derived from Cabinet parameters and logical keys, not transient SketchUp child IDs or detail level.
- Primitive mutation policy rejects generated domain roots and descendants. Future Furniture changes use domain parameters and regeneration.

## Consequences

- A Cabinet's root entity identity is stable across update, while generated child entity IDs are not.
- Wall shortening or height reduction that invalidates a Cabinet fails atomically.
- Construction fronts extend beyond the case depth by their thickness; the Furniture frame remains the case envelope.
- A zero back thickness omits the back part entirely; shelves then span the full case depth beginning at Y=0.
- Direct Furniture semantic changes increment revision even when world transformation is unchanged. Wall-driven relocation increments revision only when the effective root transform changes.
- Kitchen composition, appliances, manufacturing details, Electrical, Lighting, and arbitrary Ruby evaluation remain out of scope.

## Verification

Ruby tests cover local frames, schedules, validation, revisions, Wall relocation, cascade dependency, and operation counts. A cross-language TCP fixture covers create/find/frame/schedule/update. `scripts/smoke_m4.py --confirm-disposable` is the required manual SketchUp kernel check for generated panels, placement, camera capture, and native Undo.
