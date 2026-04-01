class LinkQueryService
  ALLOWED_SORT_COLUMNS = %w[created_at updated_at name title path active sdk_generated campaign_id ads_platform].freeze

  def initialize(domain:)
    @domain = domain
  end

  # Returns paginated, ordered ActiveRecord relation of links.
  def search(active:, sdk:, page: 1, per_page: nil, sort_by: nil, asc: false,
             start_date: nil, end_date: nil, term: nil, ads_platform: nil, campaign_id: nil)
    links = build_query(
      active: active, sdk: sdk,
      start_date: start_date, end_date: end_date,
      term: term, ads_platform: ads_platform, campaign_id: campaign_id
    )

    order_col = ALLOWED_SORT_COLUMNS.include?(sort_by) ? sort_by : "created_at"
    order_dir = asc ? "asc" : "desc"
    links = links.order("#{order_col} #{order_dir}")

    links = links.page(page || 1)
    links = links.per([per_page.to_i, 1].max) if per_page

    links
  end

  # Returns unordered, unpaginated ActiveRecord relation of links.
  def filter(active:, sdk:, start_date: nil, end_date: nil,
             term: nil, ads_platform: nil, campaign_id: nil)
    build_query(
      active: active, sdk: sdk,
      start_date: start_date, end_date: end_date,
      term: term, ads_platform: ads_platform, campaign_id: campaign_id
    )
  end

  private

  def build_query(active:, sdk:, start_date:, end_date:, term:, ads_platform:, campaign_id:)
    links = @domain.links
    links = links.where(active: active)
    links = links.where(sdk_generated: sdk)

    parsed_start = DateParamParser.call(start_date, default: 30.days.ago)
    parsed_end = DateParamParser.call(end_date, default: Time.now)
    links = links.where(created_at: parsed_start.beginning_of_day..parsed_end.end_of_day)

    links = links.where(ads_platform: ads_platform) if ads_platform
    if term
      links = links.where("name ILIKE ? OR title ILIKE ? OR subtitle ILIKE ? OR path ILIKE ?",
                           "%#{term}%", "%#{term}%", "%#{term}%", "%#{term}%")
    end
    links = links.where(campaign_id: campaign_id) if campaign_id

    links
  end
end
