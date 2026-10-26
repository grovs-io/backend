# frozen_string_literal: true

require 'digest'

module Analytics
  # Routes overview requests to rollup or raw-events mode.
  module OverviewFilters
    class Unsupported < StandardError; end

    Resolved = Struct.new(:mode, :platform, :clauses, :digest, :purchases, keyword_init: true) do
      def raw?
        mode == :raw
      end
    end

    def self.resolve(filters, platform: nil)
      parsed = QueryHelpers.parse_filters(filters)
                           .select { |f| f['field'].present? && f['operator'].present? }
                           .uniq
      if platform.present? && parsed.none? { |f| f['field'] == 'platform' }
        parsed << { 'field' => 'platform', 'operator' => 'is', 'value' => platform }
      end

      platform_filters, others = parsed.partition { |f| f['field'] == 'platform' }
      simple = platform_filters.size == 1 &&
               platform_filters[0]['operator'] == 'is' &&
               !platform_filters[0]['value'].is_a?(Array)
      simple_platform = simple ? platform_filters[0]['value'].to_s : nil

      if others.empty? && (platform_filters.empty? || simple)
        return Resolved.new(mode: :rollup, platform: simple_platform, clauses: [], digest: '')
      end

      parsed.each do |f|
        next if f['field'] == 'platform' && simple

        raise Unsupported, "Unsupported filter: #{f['field']} #{f['operator']}" if EventsQueryService.filter_clauses([f]).empty?
      end
      clauses = EventsQueryService.filter_clauses(parsed)

      Resolved.new(mode: :raw, platform: simple_platform, clauses: clauses,
                   digest: Digest::SHA1.hexdigest(clauses.join('|'))[0, 12],
                   purchases: parsed.any? { |f| targets_purchases?(f) })
    end

    def self.targets_purchases?(filter)
      return true if EventsSource.purchase_field?(filter['field'])
      return false unless filter['field'] == 'event_type'

      values = Array(filter['value']).map { |v| v.to_s.downcase }
      case filter['operator']
      when 'is' then values.include?('purchase')
      when 'contains' then values.any? { |v| 'purchase'.include?(v) }
      else false
      end
    end
    private_class_method :targets_purchases?
  end
end
