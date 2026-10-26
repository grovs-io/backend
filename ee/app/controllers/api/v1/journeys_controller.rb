class Api::V1::JourneysController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false
  PAGE_MAX = 200
  PLAIN = %i[name control_group first_step].freeze
  OBJECTS = { entry: :to_unsafe_h, re_entry: :to_unsafe_h, steps: :to_unsafe_h, goals: :to_ary }.freeze
  TIMES = %i[start_at end_at].freeze

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :require_journeys
  before_action :load_journey, except: %i[index create]

  rescue_from ActiveRecord::StaleObjectError do
    render json: { error: "Journey changed while you were editing it; reload and retry" }, status: :conflict
  end
  rescue_from Journey::Refused, ActiveRecord::RecordInvalid, InAppReport::Invalid do |e|
    render json: { error: e.message.delete_prefix("Validation failed: ") }, status: :unprocessable_entity
  end
  rescue_from ActiveModel::RangeError, ActiveRecord::NotNullViolation do
    render json: { error: "A value is missing or out of range" }, status: :unprocessable_entity
  end
  rescue_from Clickhouse::Unavailable do
    render json: { error: "Reports are unavailable right now", error_code: "clickhouse_unavailable" }, status: :service_unavailable
  end

  # Newest first, keyset-paged on `after` (the last row's hashid).
  def index
    limit = Integer(params.fetch(:limit, PAGE_MAX)).clamp(1, PAGE_MAX)
    scope = @project.journeys.order(id: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    if params[:after].present?
      after = Journey.decode_id(params[:after])
      return render_bad_page unless after.is_a?(Integer)

      scope = scope.where(id: ...after)
    end
    list = scope.limit(limit + 1).to_a
    page = list.first(limit)
    more = list.size > limit
    render json: { journeys: JourneySerializer.serialize(page, slim: true, stats: JourneySerializer.stats(page)), truncated: more,
                   next_after: more ? page.last.hashid : nil }, status: :ok
  rescue ArgumentError, TypeError, Hashids::InputError
    render_bad_page
  end

  def show = render_one(:ok)

  def create
    @journey = @project.journeys.new(created_by: current_user)
    return unless assign
    return render_invalid unless @journey.save

    audit!("journey.created", instance_id: @project.instance_id, target: audit_target(@journey), changes: { "after" => { "name" => @journey.name } })
    render_one(:created)
  end

  def update
    return render_conflict("An ended journey cannot be edited") if @journey.status == "ended"
    return unless assign
    return render_invalid unless @journey.save

    audit!("journey.updated", instance_id: @project.instance_id, target: audit_target(@journey), changes: { "after" => { "revision" => @journey.revision } })
    render_one(:ok)
  end

  def destroy
    return render_conflict("Only a draft can be deleted") unless @journey.draft?

    @journey.destroy!
    audit!("journey.deleted", instance_id: @project.instance_id, target: audit_target(@journey))
    render json: { message: "Deleted" }, status: :ok
  end

  def launch
    return render_conflict("Only a draft can be launched") unless @journey.launch!(by: current_user)

    audit!("journey.launched", instance_id: @project.instance_id, target: audit_target(@journey), changes: { "after" => { "status" => @journey.status } })
    render_one(:ok)
  end

  def pause = transition(@journey.pause!, "Only a live journey can be paused", "journey.paused")
  def resume = transition(@journey.resume!, "Only a paused journey can be resumed", "journey.resumed")
  def finish = transition(@journey.end!, "Only a live or paused journey can be ended", "journey.ended")

  def duplicate
    source = @journey
    @journey = source.duplicate(by: current_user)
    copied = Journey.transaction { (@journey.save && @journey.copy_images_from(source)) || raise(ActiveRecord::Rollback) }
    return render_invalid unless copied

    audit!("journey.created", instance_id: @project.instance_id, target: audit_target(@journey),
                              changes: { "after" => { "name" => @journey.name, "copied_from" => source.hashid } })
    render_one(:created)
  ensure
    @journey.discard_copies unless copied
  end

  def upload_image
    return refuse("image must be a file") unless params[:image].respond_to?(:read)
    return render_conflict("An ended journey cannot be edited") if @journey.status == "ended"
    return if (expected = upload_version) == false

    url = @journey.attach_image(params[:image], expected_version: expected)
    return render_invalid if url.nil?

    version = @journey.lock_version
    audit!("journey.updated", instance_id: @project.instance_id, target: audit_target(@journey), changes: { "after" => { "image" => url } })
    render json: { url: url, lock_version: version }, status: :created
  end

  def report
    from = params[:from].presence || [(@journey.launched_at || Time.current).to_date, Date.current - (InAppReport::MAX_DAYS - 1)].max.iso8601
    render json: { report: Journeys::Report.call(@journey, from: from, to: params[:to].presence || Date.current.iso8601) }, status: :ok
  end

  private

  def transition(done, refusal, action)
    return render_conflict(refusal) unless done

    audit!(action, instance_id: @project.instance_id, target: audit_target(@journey))
    render_one(:ok)
  end


  def assign
    return false unless expect_version

    PLAIN.each { |k| @journey.public_send("#{k}=", params[k]) if params.key?(k) }
    OBJECTS.each do |k, reader|
      next unless params.key?(k)
      return refuse("#{k} must be #{reader == :to_ary ? 'a list' : 'an object'}") unless params[k].respond_to?(reader)

      @journey.public_send("#{k}=", JSON.parse(params[k].public_send(reader).to_json))
    end
    TIMES.each { |k| return false unless take_time(k) }
    true
  end

  # The revision the editor was looking at: a save made from an older one is refused, not merged.
  def expect_version
    return true unless params.key?(:lock_version)

    @journey.lock_version = Integer(params[:lock_version])
    true
  rescue ArgumentError, TypeError
    refuse("lock_version must be a number")
  end

  # Uploads bump lock_version too, so an editor's optional lock_version is checked under the journey's lock.
  def upload_version
    params.key?(:lock_version) ? Integer(params[:lock_version]) : nil
  rescue ArgumentError, TypeError
    refuse("lock_version must be a number")
  end

  def take_time(key)
    return true unless params.key?(key)

    @journey.public_send("#{key}=", params[key].presence && Time.iso8601(params[key].to_s))
    true
  rescue ArgumentError
    refuse("#{key} must be a time such as 2026-10-01T09:00:00Z")
  end

  def refuse(message)
    render json: { error: message }, status: :unprocessable_entity
    false
  end

  def require_journeys
    return if @project.instance.journeys_enabled?

    render json: { error: "Journeys are not enabled" }, status: :not_found
  end

  def load_journey
    @journey = @project.journeys.find_by_hashid(params[:journey_id])
    render json: { error: "Journey not found" }, status: :not_found unless @journey
  end

  def render_one(status)
    render json: { journey: JourneySerializer.serialize(@journey) }, status: status
  end

  def render_bad_page = render(json: { error: "after must be a journey id and limit an integer" }, status: :unprocessable_entity)
  def render_invalid = render(json: { error: @journey.errors.full_messages.first(3).join(", ") }, status: :unprocessable_entity)
  def render_conflict(msg) = render(json: { error: msg }, status: :conflict)
end
