class CampaignQueryService
  ALLOWED_SORT_COLUMNS = %w[created_at updated_at name].freeze

  def initialize(project:)
    @project = project
  end

  # Returns paginated, ordered ActiveRecord relation of campaigns.
  def search(archived:, page: 1, per_page: nil, sort_by: nil, asc: false,
             start_date: nil, end_date: nil, term: nil)
    campaigns = build_query(archived: archived, start_date: start_date, end_date: end_date, term: term)

    order_col = ALLOWED_SORT_COLUMNS.include?(sort_by) ? sort_by : "updated_at"
    order_dir = asc ? "asc" : "desc"
    campaigns = campaigns.order("#{order_col} #{order_dir}")

    campaigns = campaigns.page(page || 1)
    campaigns = campaigns.per([per_page.to_i, 1].max) if per_page

    campaigns
  end

  # Returns unordered, unpaginated ActiveRecord relation of campaigns.
  def filter(archived:, start_date: nil, end_date: nil, term: nil)
    build_query(archived: archived, start_date: start_date, end_date: end_date, term: term)
  end

  private

  def build_query(archived:, start_date:, end_date:, term:)
    campaigns = @project.campaigns
    campaigns = campaigns.where(archived: archived)

    parsed_start = DateParamParser.call(start_date, default: Date.today - 30)
    parsed_end = DateParamParser.call(end_date, default: Date.today)
    campaigns = campaigns.where(created_at: parsed_start.beginning_of_day..parsed_end.end_of_day)

    campaigns = campaigns.where("name ILIKE ?", "%#{term}%") if term

    campaigns
  end
end
