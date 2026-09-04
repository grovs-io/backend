# frozen_string_literal: true

module Analytics
  # Request asks for data older than the plan allows (billing/upsell signal,
  # distinct from the QueryTooHeavy cost cap).
  class RetentionWindowExceeded < StandardError; end
end
