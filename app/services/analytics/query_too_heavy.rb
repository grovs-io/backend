# frozen_string_literal: true

module Analytics
  # Raised when a CH query exceeds max_execution_time / max_memory_usage.
  # Mapped to 422 query_too_heavy by the analytics base controller.
  class QueryTooHeavy < StandardError; end
end
