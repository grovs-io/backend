class Api::V1::EventStreamController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false

  MAX_LIMIT = 1000
  DEFAULT_LIMIT = 100
  LAG_SECONDS = EventStream::Deliverer::LAG_SECONDS
  EMPTY_CURSOR = { e_at: nil, e_id: "", p_at: nil, p_id: "" }.freeze

  before_action :authenticate_reader!, only: [:index]
  before_action :doorkeeper_authorize!, except: [:index]
  before_action :authorize_and_load_project, except: [:index]
  before_action :require_entitlement
  before_action :require_admin, except: [:index]

  def index
    cursor = decode_cursor(params[:after])
    types = requested_types
    cutoff = EventStream::Outbox.cutoff(LAG_SECONDS)
    events = read_events(cursor, types - ["purchase"], cutoff)
    purchases = types.include?("purchase") ? read_purchases(cursor, cutoff) : []
    merged = EventStream::Outbox.merge_by_arrival(events, purchases, limit_param)
    render json: { schema_version: EventStream::EnvelopeBuilder::SCHEMA_VERSION,
                   events: EventStream::EnvelopeBuilder.new(project: @project, include_ip: false).build_merged(merged),
                   next_after: encode_cursor(advance(cursor, merged)) }, status: :ok
  rescue ArgumentError, JSON::ParserError
    render json: { error: "Invalid cursor" }, status: :bad_request
  end

  def tokens
    list = @project.event_stream_tokens.active.order(created_at: :desc)
    render json: { event_stream_tokens: list.map { |t| serialize_token(t) } }, status: :ok
  end

  def create_token
    name = params[:name].to_s.strip
    return render(json: { error: "name is required" }, status: :unprocessable_entity) if name.blank?

    token = EventStreamToken.new(project: @project, created_by_user: current_user, name: name)
    plain = token.generate_token
    return render(json: { error: token.errors.full_messages.join(", ") }, status: :unprocessable_entity) unless token.valid?

    ActiveRecord::Base.transaction do
      token.save!
      EventStream::Outbox.sync_project!(@project)
      audit!("event_stream_token.created", instance_id: @project.instance_id, target: audit_target(token), changes: { "after" => { "name" => name } })
    end
    render json: { event_stream_token: serialize_token(token), token: plain }, status: :created
  end

  def destroy_token
    token = @project.event_stream_tokens.active.find_by_hashid(params[:token_id])
    return render(json: { error: "Token not found" }, status: :not_found) unless token

    ActiveRecord::Base.transaction do
      token.revoke!
      audit!("event_stream_token.revoked", instance_id: @project.instance_id, target: audit_target(token))
    end
    # After commit: a rolled-back revoke must not have purged the outbox.
    EventStream::Outbox.sync_project!(@project)
    render json: { message: "Token revoked" }, status: :ok
  end

  private

  # est_ tokens carry a prefix, so a Doorkeeper bearer is never mistaken for one.
  def authenticate_reader!
    raw = request.headers["Authorization"].to_s.delete_prefix("Bearer ").strip
    return authenticate_stream_token!(raw) if raw.start_with?("est_")

    doorkeeper_authorize!
    return if performed?

    authorize_and_load_project
  end

  def authenticate_stream_token!(raw)
    token = EventStreamToken.find_by_plain_token(raw) # rubocop:disable Rails/DynamicFindBy
    return render(json: { error: "Invalid or revoked token" }, status: :unauthorized) unless token

    project = Project.find_by(id: params[:id])
    return render(json: { error: "Forbidden" }, status: :forbidden) unless project && project.id == token.project_id

    token.touch_last_used!
    skip_authorization
    @project = project
  end

  def require_entitlement
    return if performed?
    return if @project.instance.event_stream_enabled?

    render json: { error: "An active enterprise subscription is required" }, status: :payment_required
  end

  def require_admin
    return if InstanceRole.exists?(instance_id: @project.instance_id, user_id: current_user.id, role: Grovs::Roles::ADMIN)

    render json: { error: "Forbidden" }, status: :forbidden
  end

  def requested_types
    return EventDestination::ALL_EVENT_TYPES if params[:event_types].blank?

    Array(params[:event_types]).map(&:to_s) & EventDestination::ALL_EVENT_TYPES
  end

  def read_events(cursor, types, cutoff)
    return [] if types.empty?

    EventStream::Outbox.read_events(project_id: @project.id, after_at: cursor[:e_at], after_id: cursor[:e_id],
                                    event_types: types, limit: limit_param, cutoff: cutoff)
  end

  def read_purchases(cursor, cutoff)
    EventStream::Outbox.read_purchases(project_id: @project.id, after_at: cursor[:p_at], after_id: cursor[:p_id],
                                       limit: limit_param, cutoff: cutoff)
  end

  # Cursors move only through rows actually returned, so rows cut by the page limit come back next time.
  def advance(cursor, merged)
    next_cursor = cursor.dup
    last_event = merged.reverse.find { |kind, _| kind == :event }&.last
    last_purchase = merged.reverse.find { |kind, _| kind == :purchase }&.last
    next_cursor.merge!(e_at: EventStream::Outbox.parse_ts(last_event["outbox_at"]), e_id: last_event["event_id"]) if last_event
    next_cursor.merge!(p_at: EventStream::Outbox.parse_ts(last_purchase["outbox_at"]), p_id: last_purchase["purchase_key"]) if last_purchase
    next_cursor
  end

  def limit_param
    limit = params[:limit].present? ? Integer(params[:limit], 10) : DEFAULT_LIMIT
    [[limit, 1].max, MAX_LIMIT].min
  end

  def decode_cursor(raw)
    return EMPTY_CURSOR.dup if raw.blank?

    decoded = JSON.parse(Base64.urlsafe_decode64(raw))
    pairs = decoded.is_a?(Hash) ? decoded.values_at("e", "p") : []
    raise ArgumentError, "cursor" unless pairs.size == 2 && pairs.all? { |pair| pair.is_a?(Array) && pair.size == 2 && pair[1].is_a?(String) }

    { e_at: cursor_time(pairs[0][0]), e_id: pairs[0][1], p_at: cursor_time(pairs[1][0]), p_id: pairs[1][1] }
  end

  def cursor_time(value)
    return nil if value.nil?
    raise ArgumentError, "cursor" unless value.is_a?(String)

    Time.find_zone("UTC").parse(value)&.utc || raise(ArgumentError, "cursor")
  end

  def encode_cursor(cursor)
    Base64.urlsafe_encode64({ "e" => [cursor[:e_at] && EventStream::Outbox.format_ts(cursor[:e_at]), cursor[:e_id]],
                              "p" => [cursor[:p_at] && EventStream::Outbox.format_ts(cursor[:p_at]), cursor[:p_id]] }.to_json, padding: false)
  end

  def serialize_token(token)
    { id: token.hashid, name: token.name, created_at: token.created_at, last_used_at: token.last_used_at,
      created_by_email: token.created_by_user&.email }
  end
end
