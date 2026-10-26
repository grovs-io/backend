module Billing
  module Plans
    class UnknownPlan < StandardError; end

    CAPS = { "growth_250k" => 250_000, "growth_500k" => 500_000, "scale_1m" => 1_000_000 }.freeze
    INTERVALS = %w[monthly yearly].freeze

    module_function

    def flat?(key) = CAPS.key?(key.to_s)
    def mau_cap(key) = CAPS[key.to_s]
    def valid?(key, interval) = flat?(key) && INTERVALS.include?(interval.to_s) && ENV[env_key(key, interval)].present?

    def price(key, interval)
      raise UnknownPlan, "Unknown plan" unless valid?(key, interval)

      ENV.fetch(env_key(key, interval))
    end

    def for_price(price_id)
      return nil if price_id.blank?

      CAPS.keys.product(INTERVALS).find { |k, i| ENV[env_key(k, i)] == price_id }&.first
    end

    def env_key(key, interval) = "STRIPE_PRICE_#{key.upcase}_#{interval.upcase}"
  end
end
