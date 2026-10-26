class DashboardWidget < ApplicationRecord
  MAX_PER_DASHBOARD = 20
  MAX_FILTERS = 25
  MAX_FILTER_FIELD_LENGTH = 100
  MAX_FILTER_VALUE_LENGTH = 200
  MAX_FILTER_VALUES = 50
  VIZ = %w[number bar line table].freeze
  SIZES = %w[sm md lg].freeze
  FILTER_OPERATORS = %w[is is_not contains].freeze
  KINDS = %w[metric panel].freeze
  PANELS = %w[
    acquisition_channels top_links top_campaigns acquisition engagement revenue retention user_trends
    kpis_acquisition kpis_engagement kpis_revenue kpis_links revenue_trend
  ].freeze

  belongs_to :dashboard, touch: true

  validates :title, presence: true, length: { maximum: 100 }
  validates :subtitle, length: { maximum: 140 }, allow_nil: true
  validates :kind, inclusion: { in: KINDS }
  validates :viz, inclusion: { in: VIZ }
  validates :size, inclusion: { in: SIZES }
  validate :query_must_be_valid
  validate :panel_must_be_valid
  validate :filters_must_be_chips
  validate :within_dashboard_cap, on: :create

  private

  # The stored query is exactly what GET analytics/query accepts, minus dates.
  def query_must_be_valid
    return unless kind == 'metric'

    raw = query.is_a?(Hash) ? query : {}
    params = ActionController::Parameters.new(raw.slice('metric', 'group_by', 'granularity', 'limit', 'compare'))
    parsed = Analytics::MetricQuery.build(params, start_date: Date.current, end_date: Date.current)
    canonical = { 'metric' => parsed.metric, 'limit' => parsed.limit, 'compare' => parsed.compare }
    canonical['group_by'] = parsed.group_by if parsed.group_by
    canonical['granularity'] = parsed.granularity if parsed.granularity
    self.query = canonical
  rescue Analytics::MetricQuery::Invalid => e
    errors.add(:query, e.message)
  end

  # A panel widget renders a curated Overview panel instead of a stored query.
  def panel_must_be_valid
    if kind == 'panel'
      errors.add(:panel, 'must be a known panel') unless PANELS.include?(panel)
      errors.add(:query, 'must be empty for a panel widget') unless query.is_a?(Hash) && query.empty?
    elsif panel.present?
      errors.add(:panel, 'must be blank unless kind is panel')
    end
  end

  def filters_must_be_chips
    unless filters.is_a?(Array)
      errors.add(:filters, 'must be an array')
      return
    end
    if filters.size > MAX_FILTERS
      errors.add(:filters, "at most #{MAX_FILTERS} filters")
      return
    end
    chips = filters.map { |f| f.is_a?(Hash) ? f.slice('field', 'operator', 'value') : nil }
    if chips.any? { |c| c.nil? || c['field'].blank? || !FILTER_OPERATORS.include?(c['operator'].to_s) || c['value'].nil? }
      errors.add(:filters, 'each filter needs field, operator (is/is_not/contains) and value')
      return
    end
    if chips.any? { |c| c['field'].to_s.length > MAX_FILTER_FIELD_LENGTH }
      errors.add(:filters, "filter fields must be at most #{MAX_FILTER_FIELD_LENGTH} characters")
      return
    end
    unless chips.all? { |c| filter_value_within_limits?(c['value']) }
      errors.add(:filters, "filter values must be strings of at most #{MAX_FILTER_VALUE_LENGTH} characters, " \
                           "at most #{MAX_FILTER_VALUES} per filter")
      return
    end
    unsupported = chips.find { |c| Analytics::EventsQueryService.filter_clauses([c]).empty? }
    if unsupported
      errors.add(:filters, "filters contain an unsupported filter: #{unsupported['field']} #{unsupported['operator']}")
      return
    end
    self.filters = chips
  end

  def filter_value_within_limits?(value)
    short = ->(v) { v.is_a?(String) && v.length <= MAX_FILTER_VALUE_LENGTH }
    return value.size <= MAX_FILTER_VALUES && value.all?(&short) if value.is_a?(Array)

    short.call(value)
  end

  def within_dashboard_cap
    return if dashboard.nil? || dashboard.widgets.count < MAX_PER_DASHBOARD

    errors.add(:base, "a dashboard can have at most #{MAX_PER_DASHBOARD} widgets")
  end
end
