module HomeCAD
  module Operation
    def self.run(name, model: Sketchup.active_model)
      raise ArgumentError, 'operation block required' unless block_given?
      raise RuntimeError, 'nested HomeCAD operations are not supported' if @active
      raise RuntimeError, 'no active SketchUp model' unless model

      @active = true
      started = false
      begin
        started = model.start_operation(name, true)
        raise RuntimeError, 'SketchUp did not start operation' unless started

        result = yield(model)
        model.commit_operation
        result
      rescue StandardError
        model.abort_operation if started
        raise
      ensure
        @active = false
      end
    end
  end
end
