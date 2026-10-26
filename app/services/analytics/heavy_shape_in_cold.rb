# frozen_string_literal: true

module Analytics
  # A heavy raw shape (search, contains/is_not, segment) reaching past the hot window; 422 heavy_filter_in_cold.
  class HeavyShapeInCold < QueryTooHeavy; end
end
