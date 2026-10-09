# M6 Electrical Points and Circuits

M6 adds project-selected electrical points and logical circuits. Cable routes, panels,
consumers, load calculations and jurisdiction-specific rules are reserved for M6.1.
Points are root generated Groups; circuits are UUID records in model metadata, with
no artificial scene geometry. Point membership is the only source of circuit members.

Point placement uses explicit dimensions, a center anchor on Wall U/Z, or an explicit
world normal/up frame. WallAttachment remains a domain-independent projection. A
generic before-commit DomainHooks callback maintains circuits after Architecture
cascade deletion and emits support-loss warnings. All mutations share Operation.

SceneVolumes owns canonical Architecture/Furniture/Kitchen obstacle volumes. Existing
Kitchen checks retain upright SAT behavior; Electrical uses full 3D OBB SAT, including
world placements on floors and ceilings. Wall support comes from occupied cells, not
from an enclosing bbox or Solid Tools.

References inspected (no code copied):
- zinin/sketchup-mcp2, MIT, `70c6edb50f4edbeaacdda1726ce93c4ba46fc1c0`:
  handlers/geometry.rb and test/test_transform_absolute.rb, operation and validation
  patterns. Keep HomeCAD shared operations rather than per-handler transaction code.
- darwin/supex, MIT, `66c9eed0921c418be3f1bd4ef5f100f6b5f2ad4c`:
  existing runtime reference checkout; no Electrical domain implementation reused.
- Official [Model API](https://ruby.sketchup.com/Sketchup/Model.html),
  [Transformation API](https://ruby.sketchup.com/Geom/Transformation.html), and
  [Face API](https://ruby.sketchup.com/Sketchup/Face.html): model attributes,
  rigid axes and generated face extrusion. SidhNor AGPL code is not copied.

Circuit labels and voltage are explicit project data, not verified engineering
selection. Quantity is the number of positions in a block, not a geometry multiplier.
