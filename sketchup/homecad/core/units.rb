module HomeCAD
  module Units
    MM_PER_INCH = 25.4

    def self.mm_to_internal(mm)
      Float(mm) / MM_PER_INCH
    end

    def self.internal_to_mm(length)
      Float(length) * MM_PER_INCH
    end
  end
end
