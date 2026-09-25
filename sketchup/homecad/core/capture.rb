require 'base64'
require 'tmpdir'

module HomeCAD
  module Capture
    VIEWS = %w[current top front back left right iso].freeze
    DIRECTIONS = {
      'top' => [[0, 0, 1], [0, 1, 0]],
      'front' => [[0, -1, 0], [0, 0, 1]],
      'back' => [[0, 1, 0], [0, 0, 1]],
      'left' => [[-1, 0, 0], [0, 0, 1]],
      'right' => [[1, 0, 0], [0, 0, 1]],
      'iso' => [[1, -1, 1], [0, 0, 1]]
    }.freeze
    MAX_PNG_BYTES = 10 * 1024 * 1024

    def self.capture(model, params)
      Inspection.check_keys!(params, %w[view zoom_extents target max_size restore_camera])
      name = params.fetch('view', 'current')
      max_size = params.fetch('max_size', 1024)
      zoom = params.fetch('zoom_extents', false)
      restore = params.fetch('restore_camera', true)
      unless VIEWS.include?(name) && max_size.is_a?(Integer) && (64..1600).cover?(max_size) &&
             [true, false].include?(zoom) && [true, false].include?(restore)
        Inspection.invalid!('invalid screenshot parameters')
      end
      Inspection.invalid!('target and zoom_extents cannot be combined') if zoom && params.key?('target')
      target = params.key?('target') ? Targeting.resolve_one(model, params['target']) : nil
      view = model.active_view
      changed = name != 'current' || !target.nil? || zoom
      if changed && restore && view.camera.respond_to?(:is_2d?) && view.camera.is_2d?
        Inspection.invalid!('camera restoration for two-point perspective is unsupported')
      end
      original = snapshot_camera(view.camera) if changed && restore
      before = camera_state(view.camera)
      width, height = image_size(view, max_size)
      response = nil
      begin
        set_camera(view, name) unless name == 'current'
        focus_target(view, target) if target
        frame_model(view, model) if zoom
        png = write_png(view, width, height)
        response = { 'mime_type' => 'image/png', 'image_base64' => Base64.strict_encode64(png),
                     'view' => name, 'width' => width, 'height' => height,
                     'target' => target && Targeting.identity(target), 'camera_before' => before }
      ensure
        if original
          view.camera = [original, 0.0]
          view.refresh
        end
        if response
          response['camera_after'] = camera_state(view.camera)
          response['camera_restored'] = restore && same_camera_state?(response['camera_before'], response['camera_after'])
        end
      end
      response
    end

    def self.snapshot_camera(source)
      point = ->(value) { Geom::Point3d.new(value.x, value.y, value.z) }
      up = Geom::Vector3d.new(source.up.x, source.up.y, source.up.z)
      perspective = source.perspective?
      copy = Sketchup::Camera.new(point.call(source.eye), point.call(source.target), up,
                                   perspective, perspective ? source.fov : 30.0)
      copy.height = source.height unless perspective
      copy.aspect_ratio = source.aspect_ratio if source.respond_to?(:aspect_ratio)
      copy
    end

    def self.same_camera_state?(before, after)
      before.all? do |key, value|
        other = after[key]
        if value.is_a?(Array)
          other.is_a?(Array) && value.zip(other).all? { |a, b| a.is_a?(Numeric) && b.is_a?(Numeric) && (a - b).abs < 0.0001 }
        elsif value.is_a?(Numeric)
          other.is_a?(Numeric) && (value - other).abs < 0.0001
        else
          value == other
        end
      end
    end

    def self.camera_state(camera)
      point = ->(value) { [value.x, value.y, value.z].map { |n| Units.internal_to_mm(n) } }
      perspective = camera.respond_to?(:perspective?) ? camera.perspective? : nil
      { 'eye_mm' => point.call(camera.eye), 'target_mm' => point.call(camera.target),
        'up' => camera.respond_to?(:up) ? [camera.up.x, camera.up.y, camera.up.z] : nil,
        'perspective' => perspective,
        'fov' => perspective && camera.respond_to?(:fov) ? camera.fov : nil,
        'height_mm' => perspective == false && camera.respond_to?(:height) ? Units.internal_to_mm(camera.height) : nil,
        'aspect_ratio' => camera.respond_to?(:aspect_ratio) ? camera.aspect_ratio : nil }
    end

    def self.image_size(view, max_size)
      width = view.vpwidth
      height = view.vpheight
      Inspection.invalid!('viewport has invalid dimensions') if width <= 0 || height <= 0

      scale = max_size.to_f / [width, height].max
      [[(width * scale).round, 1].max, [(height * scale).round, 1].max]
    end

    def self.set_camera(view, name)
      direction, up = DIRECTIONS.fetch(name)
      old = view.camera
      center = old.target
      distance = old.eye.distance(center)
      distance = 100.0 if distance < 1.0
      eye = Geom::Point3d.new(center.x + direction[0] * distance,
                              center.y + direction[1] * distance,
                              center.z + direction[2] * distance)
      camera = Sketchup::Camera.new(eye, center, Geom::Vector3d.new(*up))
      camera.perspective = false
      view.camera = [camera, 0.0]
    end

    def self.focus_target(view, entry)
      box = Serializer.bounds(entry)
      raise Runtime::BridgeError.new(-32005, 'geometry_error', 'target has no bounds to frame') unless box

      focus_bounds(view, box)
    end

    def self.frame_model(view, model)
      bounds = model.bounds
      return if bounds.empty?

      box = { 'min' => [bounds.min.x, bounds.min.y, bounds.min.z].map { |value| Units.internal_to_mm(value) },
              'max' => [bounds.max.x, bounds.max.y, bounds.max.z].map { |value| Units.internal_to_mm(value) } }
      focus_bounds(view, box)
    end

    def self.focus_bounds(view, box)
      center = (0..2).map { |index| Units.mm_to_internal((box['min'][index] + box['max'][index]) / 2.0) }
      extents = (0..2).map { |index| Units.mm_to_internal(box['max'][index] - box['min'][index]) }
      diameter = Math.sqrt(extents.sum { |value| value * value })
      camera = view.camera
      vector = [camera.eye.x - camera.target.x, camera.eye.y - camera.target.y,
                camera.eye.z - camera.target.z]
      length = Math.sqrt(vector.sum { |value| value * value })
      vector = [1, -1, 1] if length < 0.0001
      length = Math.sqrt(vector.sum { |value| value * value })
      if camera.perspective?
        aspect = view.vpwidth.to_f / view.vpheight
        narrow_factor = [aspect, 1.0 / aspect, 1.0].min
        half_angle = camera.fov * narrow_factor * Math::PI / 360.0
        distance = [diameter * 0.75 / Math.tan(half_angle), 1.0].max
      else
        camera.height = [diameter * 1.5, 1.0].max
        distance = [length, diameter * 2.0, 1.0].max
      end
      eye = (0..2).map { |index| center[index] + vector[index] / length * distance }
      camera.set(Geom::Point3d.new(*eye), Geom::Point3d.new(*center), camera.up)
      view.camera = [camera, 0.0]
    end

    def self.write_png(view, width, height)
      Dir.mktmpdir('homecad-capture-') do |directory|
        path = File.join(directory, 'capture.png')
        result = view.write_image(filename: path, width: width, height: height, antialias: true)
        raise Runtime::BridgeError.new(-32006, 'capture_error', 'SketchUp could not capture the viewport') unless result && File.file?(path)

        bytes = File.binread(path)
        if bytes.bytesize > MAX_PNG_BYTES
          raise Runtime::BridgeError.new(-32004, 'constraint_violation', 'captured PNG exceeds 10 MiB; reduce max_size')
        end
        bytes
      end
    end
  end
end
