# ADR 0002: M2 mutation contract

## Status

Accepted for M2.

## Context

Primitive geometry introduces the first model mutations. Later domain tools need stable object identity, consistent undo behavior, and responses that make affected objects inspectable without exposing SketchUp's internal units.

## Decision

All M2 writes use one `HomeCAD::Operation` per MCP mutation. Inputs and targets are validated before starting it; mutations abort on failure. Created managed objects receive a Ruby `SecureRandom.uuid` HomeCAD ID plus schema/type/revision/generated metadata. Results share one structured envelope and use the scene serializer. Public lengths/coordinates use millimeters and angles use degrees. A versioned `geometry.primitive.v1` capability gates these tools.

Boolean operations copy their two source objects and return a new result, preserving source object identity. M2.1 uses `tool_copy.subtract(target_copy)` for `difference = target - tool`, following the official parameter description. The API summary and parameter prose conflict. On SketchUp 26.2.243, the asymmetric smoke found that the old `split` index mapping produced reverse bounds, then confirmed that the rebuilt `subtract` call returns target-minus-tool bounds. Temporary source copies are erased before commit.

M2.1 also defines `push_pull.distance_mm` as a world-visible length and rejects scaled, sheared, reflected, malformed, or non-finite parent transformations before opening an operation. Follow Me removes only path edges that have no attached faces; edges participating in the swept topology remain and produce a warning.

## Consequences

Primitive operations are undoable as one action and later tools can identify/revise managed objects consistently. M2 intentionally rejects nested/shared geometry contexts where mutation scope is uncertain. Domain parameters and domain-specific geometry remain outside this milestone.
