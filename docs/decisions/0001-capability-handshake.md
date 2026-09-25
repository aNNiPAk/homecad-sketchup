# ADR 0001: Capability based bridge handshake

- Status: Accepted
- Date: 2026-09-25

## Context

The Python client used extension major-version compatibility plus a special `capture_view >= 0.2.1` version gate. This tied feature support to release numbering and required a new hard-coded version check for each capability.

## Decision

Keep protocol version 1 and add a `capabilities` string array to the Ruby `hello` result. The bridge advertises only implemented, versioned capabilities:

- `model.info.v1`
- `scene.inspect.v1`
- `scene.measure.v1`
- `view.capture.v1`
- `scene.undo.v1`

Python maps each method to its required capability and checks the `hello` result before sending the method request. A missing capability returns `unsupported_operation`; a present but malformed capability field returns `invalid_response`. Unknown extra capability strings are ignored. The baseline `homecad_status` operation requires no capability, so it remains usable with an otherwise protocol- and major-version-compatible older bridge. Ruby also includes capabilities in its status payload for inspection.

The field is additive, so the existing length-prefixed JSON transport and protocol version do not change. An older Ruby bridge that omits `capabilities` is treated as advertising no optional features.

## Consequences

Adding a feature requires adding a stable capability name and mapping the affected operation, rather than comparing software patch versions in Python. Future domain capabilities remain unadvertised until implemented.
