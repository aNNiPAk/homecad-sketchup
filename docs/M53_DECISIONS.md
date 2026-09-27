# M5.3 decisions

- The EasyKitchen research report and reference catalog are local, ignored inputs. This
  implementation uses no copied geometry, formulas, models, or Redcut data.
- Project settings are Model metadata. Preset definitions are original, versioned HomeCAD
  recipes based on the existing Cabinet generator rather than imported SketchUp components.
- `furniture_source_json` is the canonical record of preset inheritance and overrides;
  `furniture_params_json` holds the derived effective parameters used by the generator.
- Old Cabinets have no source record and remain pinned. Changing project settings never
  retroactively opts them into inheritance.
- Project updates preflight affected Cabinets, then change settings and derived objects in
  one Undo operation. Invalid dimensions or locked dependents reject the whole change.
- The Python MCP catalog tools are the variant selection interface. No SketchUp dialog is
  introduced in this milestone.
