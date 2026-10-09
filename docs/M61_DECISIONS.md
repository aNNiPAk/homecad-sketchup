# M6.1 Electrical System Completion

Baseline `5510fce` / 0.13.0 passed packaged M6 verification on SketchUp 26.2.243
before changes (73 Python tests, all Ruby suites, RBZ build, native Undo cleanup).
M6.1 builds on that implementation; no M6 history is rewritten.

Panels are generated root Groups using existing Electrical center/frame and support
helpers. Circuit.panel_id owns assignment; Panel.circuit_ids is derived. Panel
revision tracks its own parameters/placement and Wall relocation, while assignment
changes Circuit revision. Explicit detach_circuits removes panel links but preserves
Circuit records. Wall cascade detaches them within the shared operation.

Consumer is a model JSON record, not an appliance copy. source_object_id is an
existing stable kitchen.appliance UUID (one Consumer per source in this milestone).
Connection is outlet or direct; direct supports connection_point/junction_box.
Only point_id is stored: Consumer -> Point.circuit_id -> Circuit derives membership.
Power/voltage are explicit project inputs, unknown values stay null. Connect checks
point type; it never silently selects another point. Generic validation also reports
manually corrupted or later missing references.

DomainHooks checks sources after an outer mutation, before commit. Disappeared or
retyped appliance sources cascade their Consumers. Regeneration preserving appliance
UUID/type preserves Consumer. No Kitchen -> Electrical dependency is added.
Consumer deletion/changes bump affected circuits; Point transfer uses M6's existing
old/new Circuit bump. Cross-domain cascade aggregates affected circuits and skips
circuits already bumped by point deletion, so each revision increments once.

Route is a generated root Group with world-space polyline parameters (2..128 points),
no diameter/collision claim. Length is derived from the path. Circuit deletion rejects
routes unless detach_routes=true, independent of detach_points; detached routes are
preserved with circuit_id=null and reported by generic validation. Changing a route
bumps old/new associated circuits once. Wall movement does not automatically rewrite
world-space routes, which do not store point endpoint bindings.

Load summary sums explicit known power only. Informational current equals that sum
divided by explicit Circuit voltage, without phase/diversity/power-factor modeling.
Voltage mismatch or no known power in a nonempty consumer set suppresses current.
Warnings explain incomplete power or voltage information. No automatic cable/RCBO/RCD
sizing is performed. Consumer semantic changes on a connected circuit bump its revision;
the graph owns these revisions, not a cached load calculation.

Rulesets are named Ruby implementations, initially generic only. Validation preserves
M6 response keys and adds structured consistency findings. National RU/EU numeric
rules, wiring routes derived from building code, and M7 Lighting are outside scope.
