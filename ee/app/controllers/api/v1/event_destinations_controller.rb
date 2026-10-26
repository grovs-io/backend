class Api::V1::EventDestinationsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  include Api::V1::Concerns::AnalyticsRetentionGate
  # wrap_parameters nests JSON bodies under :event_destination, breaking the strict request contract.
  wrap_parameters false
  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :require_entitlement
  before_action :require_admin, except: [:index]
  before_action :load_destination, only: %i[update destroy pause resume rewind test]
  # Row lock so an in-flight delivery cannot overwrite this change with its older Bookmark.
  around_action :lock_destination, only: %i[update pause resume rewind]
  before_action :enforce_export_retention_window!, only: [:create_export]

  PERMITTED = %i[name kind batch_size concurrency include_ip].freeze
  SETTINGS_KEYS = %w[url bucket region prefix endpoint force_path_style].freeze
  CREDENTIAL_KEYS = %w[headers access_key_id secret_access_key].freeze
  MAX_REWIND = EventStream::Outbox::RETENTION_DAYS.days
  MAX_EXPORT_DAYS = 92

  def index
    list = @project.event_destinations.order(:created_at)
    render json: { event_destinations: list.map { |d| EventDestinationSerializer.serialize(d) } }, status: :ok
  end

  def create
    destination = EventDestination.new(project: @project, created_by_user: current_user)
    assign(destination)
    secret = destination.webhook? ? destination.generate_signing_secret : nil
    return render_invalid(destination) unless destination.valid?

    ActiveRecord::Base.transaction do
      destination.events_cursor_at = Time.current
      destination.purchases_cursor_at = Time.current
      destination.save!
      EventStream::Outbox.sync_project!(@project)
      audit!("event_destination.created", instance_id: @project.instance_id, target: audit_target(destination),
             changes: { "after" => { "name" => destination.name, "kind" => destination.kind } })
    end
    render json: { event_destination: EventDestinationSerializer.serialize(destination), signing_secret: secret }, status: :created
  end

  def update
    if params.key?(:kind) && params[:kind].to_s != @destination.kind
      return render(json: { error: "kind cannot be changed; create a new destination instead" }, status: :unprocessable_entity)
    end

    assign(@destination)
    return render_invalid(@destination) unless @destination.valid?

    @destination.save!
    audit!("event_destination.updated", instance_id: @project.instance_id, target: audit_target(@destination))
    render_one
  end

  def destroy
    @destination.with_lock do
      @destination.destroy!
      audit!("event_destination.deleted", instance_id: @project.instance_id, target: audit_target(@destination))
    end
    # After commit: a rolled-back delete must not have purged a live destination's outbox.
    EventStream::Outbox.sync_project!(@project)
    render json: { message: "Destination deleted" }, status: :ok
  end

  def pause
    @destination.pause!("manual")
    audit!("event_destination.paused", instance_id: @project.instance_id, target: audit_target(@destination))
    render_one
  end

  def resume
    @destination.resume!
    audit!("event_destination.resumed", instance_id: @project.instance_id, target: audit_target(@destination))
    render_one
  end

  def rewind
    to = Time.iso8601(params[:to].to_s)
    if to < Time.current - MAX_REWIND || to > Time.current
      return render(json: { error: "to must be within the last #{EventStream::Outbox::RETENTION_DAYS} days" }, status: :unprocessable_entity)
    end

    @destination.rewind!(to: to)
    audit!("event_destination.rewound", instance_id: @project.instance_id, target: audit_target(@destination),
           changes: { "after" => { "to" => to.utc.iso8601 } })
    render_one
  rescue ArgumentError
    render json: { error: "Invalid timestamp" }, status: :bad_request
  end

  def test
    return render(json: { error: "Event delivery is paused" }, status: :service_unavailable) unless Grovs.event_stream_enabled?

    body = { schema_version: EventStream::EnvelopeBuilder::SCHEMA_VERSION, id: SecureRandom.hex(16), type: "test", name: nil,
             occurred_at: Time.current.utc.iso8601(3), project: { id: @project.hashid, test: @project.test } }
    accepted, error = adapter_for(@destination).deliver([body])
    audit!("event_destination.tested", instance_id: @project.instance_id, target: audit_target(@destination), outcome: error ? "failure" : "success")
    # 424, not 502: Cloudflare swaps an origin 502 for its own page and the reason never arrives.
    return render(json: { error: error }, status: :failed_dependency) unless accepted == 1

    render json: { message: "Test event delivered" }, status: :ok
  end

  def create_export
    start_date = Date.iso8601(params[:start_date].to_s)
    end_date = Date.iso8601(params[:end_date].to_s)
    return render(json: { error: "end_date must be on or after start_date" }, status: :unprocessable_entity) if end_date < start_date
    return render(json: { error: "Range is limited to #{MAX_EXPORT_DAYS} days" }, status: :unprocessable_entity) if (end_date - start_date) >= MAX_EXPORT_DAYS

    destination = params[:destination_id].present? ? @project.event_destinations.find_by_hashid(params[:destination_id]) : nil
    return render(json: { error: "Destination not found" }, status: :not_found) if params[:destination_id].present? && destination.nil?

    EventExportJob.perform_async(@project.id, start_date.to_s, end_date.to_s, current_user.id, destination&.id, SecureRandom.uuid)
    audit!("export.event_data", instance_id: @project.instance_id, target: audit_target(@project),
           changes: { "after" => { "start_date" => start_date.to_s, "end_date" => end_date.to_s, "destination_id" => destination&.hashid } })
    render json: { message: "Export job has been queued. You will be notified when it's ready." }, status: :accepted
  rescue ArgumentError
    render json: { error: "Invalid date" }, status: :bad_request
  end

  private

  # An export always reads ClickHouse, so retention binds it even when rollup reads are off.
  def enforce_export_retention_window!
    raise ::Analytics::RetentionWindowExceeded if retention_window_exceeded?
  end

  def lock_destination(&)
    @destination.with_lock(&)
  end

  def adapter_for(destination)
    destination.s3? ? EventStream::Adapters::S3.new(destination) : EventStream::Adapters::Webhook.new(destination)
  end

  def assign(destination)
    PERMITTED.each { |k| destination.public_send("#{k}=", params[k]) if params.key?(k) }
    destination.event_types = Array(params[:event_types]).map(&:to_s) if params.key?(:event_types)
    destination.settings = params[:settings].to_unsafe_h.slice(*SETTINGS_KEYS) if params[:settings].respond_to?(:to_unsafe_h)
    destination.credentials_hash = params[:credentials].to_unsafe_h.slice(*CREDENTIAL_KEYS) if params[:credentials].respond_to?(:to_unsafe_h)
  end

  def render_invalid(destination)
    render json: { error: destination.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def render_one
    render json: { event_destination: EventDestinationSerializer.serialize(@destination) }, status: :ok
  end

  def load_destination
    @destination = @project.event_destinations.find_by_hashid(params[:destination_id])
    render json: { error: "Destination not found" }, status: :not_found unless @destination
  end

  def require_entitlement
    return if @project.instance.event_stream_enabled?

    render json: { error: "An active enterprise subscription is required" }, status: :payment_required
  end

  def require_admin
    return if InstanceRole.exists?(instance_id: @project.instance_id, user_id: current_user.id, role: Grovs::Roles::ADMIN)

    render json: { error: "Forbidden" }, status: :forbidden
  end
end
