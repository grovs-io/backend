# Which group a bucket lands in: the control first, then the variants in equal shares of what is left.
module Experiments::Split
  CONTROL = "control".freeze
  IDS = %w[a b c].freeze

  module_function

  def group(bucket, control:, variants:)
    return CONTROL if bucket < control

    ids = IDS.first(variants)
    ids[(bucket - control) * ids.size / (100 - control)]
  end

  # The same choice in ClickHouse, over a bucket expression.
  def sql(bucket_sql, control:, variants:)
    ids = IDS.first(variants).map { |id| "'#{id}'" }.join(", ")
    "if(#{bucket_sql} < #{control}, '#{CONTROL}', [#{ids}][intDiv((#{bucket_sql} - #{control}) * #{variants}, #{100 - control}) + 1])"
  end
end
