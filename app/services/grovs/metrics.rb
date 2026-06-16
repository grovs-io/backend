module Grovs
  # Thin OpenTelemetry meter wrapper. Falls back to a NullMeter when the OTel SDK isn't
  # loaded (dev/test) so callers don't need to env-branch. Metrics failures never raise.
  module Metrics
    METER_NAME = "grovs".freeze

    class NullInstrument
      def add(*); end
      def record(*); end
    end

    class NullMeter
      def create_counter(_name) = NullInstrument.new
      def create_histogram(_name) = NullInstrument.new
    end

    class << self
      def increment(name, by: 1, tags: {})
        counter_for(name).add(by, attributes: stringify_tags(tags))
      rescue StandardError => e
        Rails.logger.warn(message: "metrics_increment_failed", name: name, error: e.message)
      end

      def histogram(name, value, tags: {})
        histogram_for(name).record(value, attributes: stringify_tags(tags))
      rescue StandardError => e
        Rails.logger.warn(message: "metrics_histogram_failed", name: name, error: e.message)
      end

      def reset!
        @meter = nil
        @counters = nil
        @histograms = nil
      end

      private

      def meter
        @meter ||= if defined?(OpenTelemetry) && OpenTelemetry.respond_to?(:meter_provider)
                     OpenTelemetry.meter_provider.meter(METER_NAME)
                   else
                     NullMeter.new
                   end
      end

      def counter_for(name)
        @counters ||= {}
        @counters[name] ||= meter.create_counter(name)
      end

      def histogram_for(name)
        @histograms ||= {}
        @histograms[name] ||= meter.create_histogram(name)
      end

      def stringify_tags(tags)
        tags.each_with_object({}) { |(k, v), h| h[k.to_s] = v.is_a?(Symbol) ? v.to_s : v }
      end
    end
  end
end
