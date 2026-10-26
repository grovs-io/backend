class Api::V1::PushCampaignsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false
  LIST_LIMIT = 200
  PAGE_MAX = 200

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :require_push_campaigns
  before_action :load_campaign, except: %i[index create estimate_audience]

  rescue_from ActiveRecord::StaleObjectError do
    render json: { error: "Campaign changed while you were editing it; reload and retry" }, status: :conflict
  end
  rescue_from Clickhouse::Unavailable do
    render json: { error: "Analytics are unavailable right now", error_code: "clickhouse_unavailable" }, status: :service_unavailable
  end
  rescue_from Segments::Busy do
    render json: { error: "Too many segment queries are running; retry shortly.", error_code: "segment_busy" }, status: :too_many_requests
  end
  rescue_from Segments::InvalidDefinition, Segments::WindowExpired do |e|
    render json: { error: "Invalid segment: #{e.message}", error_code: "invalid_segment" }, status: :unprocessable_entity
  end
  rescue_from Analytics::QueryTooHeavy do
    render json: { error: "Segment is too heavy to estimate", error_code: "query_too_heavy" }, status: :unprocessable_entity
  end
  rescue_from InAppReport::Invalid do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Newest first, keyset-paged on `after` (the last row's hashid); ids grow with created_at.
  def index
    limit = Integer(params.fetch(:limit, LIST_LIMIT)).clamp(1, PAGE_MAX)
    scope = @project.push_campaigns.where.not(source: "journey").includes(:link, :segment, :counter_shards).with_attached_image.order(id: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    if params[:after].present?
      after = PushCampaign.decode_id(params[:after])
      return render json: { error: "after must be a push campaign id and limit an integer" }, status: :unprocessable_entity unless after.is_a?(Integer)

      scope = scope.where("push_campaigns.id < ?", after)
    end
    list = scope.limit(limit + 1).to_a
    page = list.first(limit)
    more = list.size > limit
    render json: { push_campaigns: PushCampaignSerializer.serialize(page, slim: true), truncated: more,
                   next_after: more ? page.last.hashid : nil }, status: :ok
  rescue ArgumentError, TypeError, Hashids::InputError
    render json: { error: "after must be a push campaign id and limit an integer" }, status: :unprocessable_entity
  end

  def show = render_one(:ok)

  def create
    @campaign = @project.push_campaigns.new(created_by: current_user, source: "dashboard")
    return unless assign
    return render_invalid unless @campaign.save

    audit!("push_campaign.created", instance_id: @project.instance_id, target: audit_target(@campaign),
                                    changes: { "after" => { "name" => @campaign.name, "audience_type" => @campaign.audience_type } })
    render_one(:created)
  end

  # In one transaction so a 422 rolls back an image Active Storage would otherwise have attached already.
  def update
    return render_conflict("Only a draft can be edited") unless @campaign.editable?

    saved = PushCampaign.transaction do
      raise ActiveRecord::Rollback unless assign && @campaign.save

      true
    end
    return if performed?
    return render_invalid unless saved

    audit!("push_campaign.updated", instance_id: @project.instance_id, target: audit_target(@campaign))
    render_one(:ok)
  end

  def send_now
    attrs = PushCampaigns::Schedule.parse(params)
    attrs.merge!(@campaign.segment_snapshot_attrs) if @campaign.audience_type == "segment"
    to = attrs.key?(:scheduled_at) ? "scheduled" : "evaluating"
    return render_conflict("Campaign has already been sent") unless @campaign.transition!(from: %w[draft], to: to, **attrs)

    audit!("push_campaign.scheduled", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "audience_type" => @campaign.audience_type, "recipients" => @campaign.recipients.size,
                                                              "scheduled_at" => @campaign.scheduled_at, "local_time" => @campaign.local_time } })
    PushCampaignEvaluateJob.perform_async(@campaign.id) if to == "evaluating"
    render_one(:accepted)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  rescue PushCampaigns::Schedule::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # The rows kept back by the test share go out as the variant chosen.
  def send_winner
    variant = params[:variant].to_s
    unless @campaign.variant_ids.include?(variant)
      return render json: { error: "variant must be one of #{@campaign.variant_ids.join(', ')}" }, status: :unprocessable_entity
    end
    return render_conflict("Only a sent campaign with people waiting can send a winner") unless @campaign.choose_winner!(variant)

    audit!("push_campaign.winner_sent", instance_id: @project.instance_id, target: audit_target(@campaign), changes: { "after" => { "variant" => variant } })
    PushWinnerJob.perform_async(@campaign.id)
    render_one(:accepted)
  end

  def experiment
    to = params[:to].presence || Date.current.iso8601
    from = params[:from].presence || [(@campaign.started_at || @campaign.created_at).to_date, Date.current - (InAppReport::MAX_DAYS - 1)].max.iso8601
    render json: { experiment: Experiments::Report.push(@campaign, from: from, to: to) }, status: :ok
  end

  def cancel
    return render_conflict("Only a draft, scheduled or sending campaign can be cancelled") unless @campaign.cancel!

    audit!("push_campaign.cancelled", instance_id: @project.instance_id, target: audit_target(@campaign))
    render_one(:ok)
  end

  def remove_image
    return render_conflict("Only a draft can be edited") unless @campaign.editable?

    @campaign.image.purge if @campaign.image.attached?
    audit!("push_campaign.updated", instance_id: @project.instance_id, target: audit_target(@campaign))
    render_one(:ok)
  end

  def estimate
    render json: PushCampaigns::Audience.estimate(@campaign), status: :ok
  end

  def estimate_audience
    @campaign = @project.push_campaigns.new(source: "dashboard")
    return unless assign_audience
    return render_invalid unless @campaign.valid_audience?

    render json: PushCampaigns::Audience.estimate(@campaign), status: :ok
  end

  def deliveries
    after = Integer(params.fetch(:after, 0))
    limit = Integer(params.fetch(:limit, 50)).clamp(1, PAGE_MAX)
    scope = @campaign.deliveries.where("id > ?", after).order(:id)
    scope = scope.where(status: params[:status]) if params[:status].present?
    rows = scope.limit(limit + 1).to_a
    page = rows.first(limit)
    visitors = Visitor.where(id: page.filter_map(&:visitor_id)).index_by(&:id)
    render json: { deliveries: page.map { |d| delivery_json(d, visitors[d.visitor_id]) }, next_after: rows.size > limit ? page.last.id : nil }, status: :ok
  rescue ArgumentError, TypeError
    render json: { error: "after and limit must be integers" }, status: :unprocessable_entity
  end

  private

  def delivery_json(delivery, visitor)
    { "id" => delivery.id, "status" => delivery.status, "platform" => delivery.platform, "recipient" => delivery.recipient,
      "error" => delivery.error, "opened_at" => delivery.opened_at,
      "visitor" => visitor && VisitorSerializer.serialize(visitor, slim: true) }
  end

  def assign
    %i[name title body image_url sound control_group test_share winner_after_minutes winner_by].each do |k|
      @campaign.public_send("#{k}=", params[k]) if params.key?(k)
    end
    @campaign.conversion = plain(params[:conversion]) if params.key?(:conversion)
    @campaign.variants = plain(params[:variants]) if params.key?(:variants)
    if params[:image].present?
      unless params[:image].respond_to?(:read)
        render json: { error: "image must be a file" }, status: :unprocessable_entity
        return false
      end
      @campaign.image.attach(params[:image])
    end
    if params.key?(:data)
      unless params[:data].respond_to?(:to_unsafe_h)
        render json: { error: "data must be an object" }, status: :unprocessable_entity
        return false
      end
      @campaign.data = params[:data].to_unsafe_h
    end
    if params.key?(:link_id)
      @campaign.link = params[:link_id].present? ? project_links.find_by(id: params[:link_id]) : nil
      if params[:link_id].present? && @campaign.link.nil?
        render json: { error: "Link not found" }, status: :unprocessable_entity
        return false
      end
    end
    assign_audience
  end

  # A multipart form (a create with an image) carries objects as JSON text; an invalid one reaches validation as is.
  def plain(value)
    value = JSON.parse(value) if value.is_a?(String) && value.start_with?("{", "[")
    return value.map { |v| plain(v) } if value.is_a?(Array)

    value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
  rescue JSON::ParserError
    value
  end

  def assign_audience
    return true unless params.key?(:audience)

    a = params[:audience]
    unless a.respond_to?(:to_unsafe_h)
      render json: { error: "audience must be an object" }, status: :unprocessable_entity
      return false
    end
    @campaign.audience_type = a[:type]
    @campaign.recipients = a[:recipients].is_a?(Array) ? a[:recipients] : []
    if a[:type] == "segment"
      @campaign.segment = @project.segments.active.find_by_hashid(a[:segment_id])
      if @campaign.segment.nil?
        render json: { error: "Segment not found" }, status: :unprocessable_entity
        return false
      end
    end
    true
  end

  def require_push_campaigns
    return if @project.instance.push_campaigns_enabled?

    render json: { error: "Push campaigns are not enabled" }, status: :not_found
  end

  # Links hang off domains, so project scoping goes through the join.
  def project_links = Link.joins(:domain).where(domains: { project_id: @project.id })

  def load_campaign
    @campaign = @project.push_campaigns.find_by_hashid(params[:campaign_id])
    render json: { error: "Push campaign not found" }, status: :not_found unless @campaign
  end

  def render_one(status) = render(json: { push_campaign: PushCampaignSerializer.serialize(@campaign) }, status: status)
  def render_invalid = render(json: { error: @campaign.errors.full_messages.join(", ") }, status: :unprocessable_entity)
  def render_conflict(msg) = render(json: { error: msg }, status: :conflict)
end
