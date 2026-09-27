# M5.4 decisions

- Preserve the existing Furniture part schedule's `width_mm` and `height_mm` fields.
  `length_mm` aliases the second cut-plane dimension; no automatic longest-side swap.
- Part material defaults come from canonical Cabinet or Kitchen module parameters.
  Part-specific manufacturing options override them, including an explicit null.
- Hardware appears only when explicitly listed with SKU and quantity; the generator
  does not infer hinges, slides, or handles from concept fronts.
- Kitchen modules use generic Furniture carcass calculations only. Appliance concepts
  are excluded and warned. This is a useful preliminary schedule, not a final factory BOM.
- `generate_cutlist` is read-only and paginated. It does not allocate HomeCAD IDs,
  modify the model, or expose raw SketchUp inches.
