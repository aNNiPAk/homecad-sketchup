# Changelog

## Unreleased

### Fixed

- Capture now reconstructs an independent camera snapshot before changing the view, restores it without a transition, and frames model bounds without invoking `View#zoom_extents`.
- The M1 smoke script can use a single selected unnamed object when `--name` is absent or has no match, and reports expected errors without an `ExceptionGroup` traceback.

### Added

- M1 Scene Inspection: bounded `list_objects`, explicit `find_objects` resolution, normalized `get_object` and `get_selection`, and structured `measure`.
- Top/front/back/left/right/iso/current viewport capture with MCP PNG output and camera restoration; one native Undo action.
- Shared HomeCAD/persistent/entity identity and instance paths, scene resolver, serializer, Ruby and Python coverage, and Windows M1 smoke script.
- M0 bootstrap: `homecad_status` and `get_model_info` through a Python MCP server and a local SketchUp Ruby bridge.
- Version and protocol handshake, bounded transport, errors, logging, configuration, operation helper, tests and RBZ packaging.
