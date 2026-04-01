class PurchaseQueryService
  ALLOWED_SORT_COLUMNS = %w[id event_type device_id product_id identifier price_cents currency usd_price_cents date created_at updated_at].freeze

  def initialize(project:)
    @project = project
  end

  # Returns paginated, ordered ActiveRecord relation of purchase events.
  def search(page: 1, sort_by: nil, asc: false, start_date: nil, end_date: nil, term: nil)
    events = base_scope

    parsed_start = DateParamParser.call(start_date, default: 30.days.ago)
    parsed_end = DateParamParser.call(end_date, default: Time.now)
    events = events.where(date: parsed_start.beginning_of_day..parsed_end.end_of_day)

    if term
      sanitized_term = term.gsub('%', '\%').gsub('_', '\_')
      events = events.where("event_type ILIKE ?", "%#{sanitized_term}%")
    end

    order_col = ALLOWED_SORT_COLUMNS.include?(sort_by) ? sort_by : "date"
    order_dir = asc ? "asc" : "desc"
    events = events.order("#{order_col} #{order_dir}")

    safe_page = [(page || 1).to_i, 1].max
    events.page(safe_page)
  end

  private

  def base_scope
    PurchaseEvent
      .where(store: false).or(PurchaseEvent.where(store: true, webhook_validated: true))
      .where(project_id: @project.id)
      .includes(:device)
  end

end
