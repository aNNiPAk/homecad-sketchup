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

Official [Entities API](https://ruby.sketchup.com/Sketchup/Entities.html) confirms
add_line returns an Edge, used for the original generated polyline. The M6 API/reference
inspection remains applicable; no third-party Electrical domain code is copied.
Fast verification on SketchUp 26.2.243 passed the existing M6 flow plus M6.1 graph,
Wall movement, source regeneration/retyping and native Undo cleanup. The saved back
view was visually inspected: Panel, outlet, continuous concept route and appliance
were visible from positive_v; no cable diameter or engineering accuracy is implied.

Visual review also caught a background-only export after Undo despite correct target
bounds/camera restoration metadata. Target framing now prepares a detached Camera,
uses a target-sized orthographic eye distance (not inherited from the prior view),
and refreshes before write_image. camera_capture reports the actual temporary frame;
the original restoration contract remains. A unit regression prevents live-wrapper
mutation during framing; fresh SketchUp verification confirms visible geometry.

The GPU export issue was intermittent: refresh/framing alone did not eliminate
background-only images. Native export now uses the documented antialias=false path.
ImageRep inspects raw rows (including padding) and reports image_has_variation; the
system fixture requires it to be true and the resulting PNG is visually reviewed.
The flag distinguishes a flat buffer, not arbitrary geometry correctness; an empty
model/hidden target may legitimately be uniform. No image pixels are altered.

Final packaged M6.1 verification passed on SketchUp 26.2.243 with 77 Python tests,
all Ruby suites, RBZ build and 23 successful test commands. The complete system flow,
including detach/voltage mismatch/route update/Wall relocation/source lifecycle and
native Undo cleanup, passed. The packaged PNG contained visible Panel, outlet,
polyline and appliance and was inspected; camera restoration and pixel variation
checks passed. Development links were restored with no cleanup errors.
