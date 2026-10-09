module HomeCAD
  # Callbacks run before the shared operation commits; failures abort it.
  module DomainHooks
    def self.register(key, &block)
      (@callbacks ||= {})[key] = block
    end

    def self.after_mutation(model, result)
      (@callbacks || {}).each_value { |callback| result = callback.call(model, result) }
      result
    end
  end
end
