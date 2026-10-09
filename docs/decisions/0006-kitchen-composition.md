# Kitchen composition hardening (M5.8)

Baseline: main 8a05a3f / 0.14.0 passed M5 packaged verification on SketchUp
26.2.243 before code changes. Work proceeds on codex/m58-kitchen-composition.

Implementation sequence:
1. Centralize Kitchen cabinet definitions and reuse Furniture validation, geometry,
   logical schedules and DrawerHardware for straight and corner modules/cutlists.
2. Add explicit straight countertop cutouts using shared rectangle validation and
   the existing native inner-loop extrusion technique.
3. Cover part bounds/schedules, semantic revisions, atomic failures and M6 sources.
4. Extend disposable M5 smoke; run fast, M5 packaged and M6 packaged, review images,
   then publish CI results without merging or creating a release tag.

Kitchen parameters remain canonical. New plans snapshot project thickness/material
defaults into module parameters; existing unversioned modules retain legacy fixed
18/4 mm values on inspection. Furniture configuration is derived, not separately
editable metadata. Root and semantic UUID ownership stays with Kitchen.

Module composition uses construction detail. Dishwasher/fridge are appliance-only
volumes. Existing hob/oven semantic appliance types are preserved for M6 Consumers,
while their housing parts derive from Furniture. Sink/hob use an open-top case;
no automatic worktop holes, plumbing or appliance mounting are inferred.

Default drawer layout is a HomeCAD concept configuration, not a manufacturer rule.
Unknown default slide SKU stays null. Explicit layouts reuse Furniture fronts and
drawers; no Kitchen drawer-panel or hardware formulas are introduced. Core validation
retains the existing requirement for explicit SKU in public Cabinet drawer inputs.

New module configuration and straight cutout requests require kitchen.composition.v1.
Protocol remains 1; matched version becomes 0.15.0 after M6's 0.14.0 baseline.
