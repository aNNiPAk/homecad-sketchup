module HomeCAD
  module CountertopCutouts
    MAX_CUTOUTS = 16
    BORDER_MM = 10.0
    TOLERANCE_MM = 0.01

    def self.normalize(input, leg_keys: nil)
      Primitives.invalid!('countertop cutouts must be an array of at most 16 entries') unless input.is_a?(Array) && input.length <= MAX_CUTOUTS
      values = input.map do |item|
        Primitives.invalid!('cutout must be an object') unless item.is_a?(Hash)
        Primitives.check_keys!(item, %w[key offset_mm front_mm width_mm depth_mm] + (leg_keys ? ['leg_key'] : []))
        key = item['key']
        Primitives.invalid!('cutout key must be nonempty and at most 64 characters') unless key.is_a?(String) && !key.empty? && key.length <= 64
        value = { 'key'=>key,
          'offset_mm'=>Geometry.finite_number(item['offset_mm'], 'cutout.offset_mm'),
          'front_mm'=>Geometry.finite_number(item['front_mm'], 'cutout.front_mm'),
          'width_mm'=>Geometry.positive_length(item['width_mm'], 'cutout.width_mm'),
          'depth_mm'=>Geometry.positive_length(item['depth_mm'], 'cutout.depth_mm') }
        if leg_keys
          Primitives.invalid!('cutout leg_key must identify a Kitchen leg') unless leg_keys.include?(item['leg_key'])
          value['leg_key'] = item['leg_key']
        end
        value
      end
      Primitives.invalid!('cutout keys must be unique') unless values.map { |item| item['key'] }.uniq.length == values.length
      values
    end

    def self.validate_rectangles!(holes, bounds)
      holes.zip(bounds).each do |hole, boundary|
        x0,y0,x1,y1=hole; u0,v0,u1,v1=boundary
        Architecture.constraint!('cutout must lie inside countertop bounds with 10 mm edge reserve') unless
          x0 >= u0+BORDER_MM-TOLERANCE_MM && y0 >= v0+BORDER_MM-TOLERANCE_MM &&
          x1 <= u1-BORDER_MM+TOLERANCE_MM && y1 <= v1-BORDER_MM+TOLERANCE_MM
      end
      holes.combination(2) do |a,b|
        Architecture.constraint!('countertop cutouts overlap') if
          [a[0],b[0]].max < [a[2],b[2]].min-TOLERANCE_MM &&
          [a[1],b[1]].max < [a[3],b[3]].min-TOLERANCE_MM
      end
      holes
    end

    def self.straight(params)
      width=params['span_mm']; depth=params['modules'].map { |m| m['depth_mm'] }.max+20
      start=params.fetch('run_start_mm',params['start_mm'])
      holes=params.fetch('countertop_cutouts',[]).map do |cut|
        x=params['side']=='positive_v' ? cut['offset_mm']-start : start+width-cut['offset_mm']-cut['width_mm']
        y=cut['front_mm']-params['clearance_mm']
        [x,y,x+cut['width_mm'],y+cut['depth_mm']]
      end
      validate_rectangles!(holes, Array.new(holes.length) { [0,0,width,depth] })
      { 'polygon_mm'=>[[0,0],[width,0],[width,depth],[0,depth]], 'holes_mm'=>holes }
    end

    # Official Face#loops example: create/erase inner faces, then extrude the shell.
    def self.build!(group, shape, bottom_mm, thickness_mm)
      face=group.entities.add_face(shape['polygon_mm'].map { |x,y| Geometry.point_mm([x,y,bottom_mm], 'countertop.outer') })
      Primitives.geometry_created!(face,'SketchUp could not create countertop')
      shape['holes_mm'].each do |x0,y0,x1,y1|
        inner=group.entities.add_face([[x0,y0],[x1,y0],[x1,y1],[x0,y1]].map { |x,y| Geometry.point_mm([x,y,bottom_mm], 'countertop.cutout') })
        Primitives.geometry_created!(inner,'SketchUp could not create countertop cutout')
        inner.erase!
      end
      if face.respond_to?(:loops) && face.loops.length != shape['holes_mm'].length+1
        raise Runtime::BridgeError.new(-32009,'geometry_error','countertop cutout loop count is incorrect')
      end
      Furniture.extrude_to_positive_z!(face, Units.mm_to_internal(thickness_mm), 'countertop')
      group
    end
  end
end
