# frozen_string_literal: true

module Analytics
  # Single source of truth for the ClickHouse "source attribution" taxonomy.
  # Both the multiIf classifier (`expr`) and the per-bucket filters
  # (`where_clause`) are derived from one priority list, so classification and
  # filtering are provably consistent: each bucket's predicate is its own
  # condition AND the negation of every higher-priority condition.
  module SourceTaxonomy
    # Ordered by priority — first matching condition wins, like CH multiIf.
    # Each entry: [bucket, ->(prefix){ condition_sql }].
    PRIORITY = [
      ['campaigns', ->(p) { "#{p}campaign_id > 0" }],
      ['referrals', ->(p) { "#{p}sdk_generated = 1 AND #{p}link_visitor_id > 0" }],
      ['api_links', ->(p) { "#{p}sdk_generated = 1 AND #{p}link_visitor_id = 0" }],
      ['links',     ->(p) { "#{p}link_id > 0" }]
    ].freeze

    SOURCES = (PRIORITY.map(&:first) + ['organic']).freeze

    module_function

    # CH multiIf classifying a row into one source bucket.
    def expr(table_alias = nil)
      p = prefix(table_alias)
      branches = PRIORITY.map { |bucket, cond| "#{cond.call(p)}, '#{bucket}'" }
      "multiIf(#{branches.join(', ')}, 'organic')".squish
    end

    # The EXACT predicate the multiIf assigns to `source`: its own condition AND
    # the negation of all higher-priority conditions (so exactly one bucket
    # matches any row). 'organic' is the negation of every condition.
    def where_clause(source, table_alias = nil)
      return nil unless SOURCES.include?(source)

      p = prefix(table_alias)
      higher = PRIORITY.take_while { |bucket, _| bucket != source }
      negations = higher.map { |_, cond| "NOT (#{cond.call(p)})" }
      own = PRIORITY.find { |bucket, _| bucket == source }&.last&.call(p)
      (negations + [own].compact).join(' AND ')
    end

    def prefix(table_alias)
      table_alias ? "#{table_alias}." : ''
    end
  end
end
