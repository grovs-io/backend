class Api::V1::InAppCampaignsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  wrap_parameters false
  PAGE_MAX = 200
  PLAIN = %i[name template priority delay_seconds control_group].freeze
  OBJECTS = %i[content caps schedule].freeze
  LISTS = %i[triggers conditions].freeze
  OPTIONAL = { conversion: [:to_unsafe_h, "an object or null"], variants: [:to_ary, "a list or null"] }.freeze
  TIMES = %i[start_at end_at].freeze

  before_action :doorkeeper_authorize!
  before_action :authorize_and_load_project
  before_action :require_in_app
  before_action :load_campaign, except: %i[index create]
  # `test` stays open: it only shows the step to one person and changes nothing.
  before_action :refuse_journey_step, only: %i[update launch pause resume finish destroy duplicate update_audience
                                               upload_image remove_image upload_media remove_media]

  rescue_from ActiveRecord::StaleObjectError do
    render json: { error: "Campaign changed while you were editing it; reload and retry" }, status: :conflict
  end
  rescue_from InAppCampaign::Refused, ActiveRecord::RecordInvalid, InAppReport::Invalid do |e|
    render json: { error: e.message }, status: :unprocessable_entity
  end
  rescue_from ActiveModel::RangeError, ActiveRecord::NotNullViolation do
    render json: { error: "A value is missing or out of range" }, status: :unprocessable_entity
  end
  rescue_from Clickhouse::Unavailable do
    render json: { error: "Reports are unavailable right now", error_code: "clickhouse_unavailable" }, status: :service_unavailable
  end

  # Newest first, keyset-paged on `after` (the last row's hashid); ids grow with created_at.
  def index
    limit = Integer(params.fetch(:limit, PAGE_MAX)).clamp(1, PAGE_MAX)
    scope = @project.in_app_campaigns.where.not(audience_type: "journey").includes(:segment).order(id: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present?
    if params[:after].present?
      after = InAppCampaign.decode_id(params[:after])
      return render_bad_page unless after.is_a?(Integer)

      scope = scope.where(in_app_campaigns: { id: ...after })
    end
    list = scope.limit(limit + 1).to_a
    page = list.first(limit)
    more = list.size > limit
    render json: { in_app_campaigns: InAppCampaignSerializer.serialize(page, list: true), truncated: more, next_after: more ? page.last.hashid : nil },
           status: :ok
  rescue ArgumentError, TypeError, Hashids::InputError
    render_bad_page
  end

  def show = render_one(:ok)

  def create
    @campaign = @project.in_app_campaigns.new(created_by: current_user)
    return unless assign
    return render_invalid unless @campaign.save

    audit!("in_app_campaign.created", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "name" => @campaign.name, "template" => @campaign.template } })
    render_one(:created)
  end

  def update
    return render_conflict("An ended campaign cannot be edited") if @campaign.status == "ended"
    return unless assign
    return render_invalid unless @campaign.save

    audit!("in_app_campaign.updated", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "revision" => @campaign.revision } })
    render_one(:ok)
  end

  def launch
    return render_conflict("Only a draft can be launched") unless @campaign.launch!

    audit!("in_app_campaign.launched", instance_id: @project.instance_id, target: audit_target(@campaign),
                                       changes: { "after" => { "status" => @campaign.status, "audience_type" => @campaign.audience_type } })
    render_one(:accepted)
  end

  def pause
    return render_conflict("Only a live campaign can be paused") unless @campaign.transition!(from: %w[live], to: "paused")

    audit!("in_app_campaign.paused", instance_id: @project.instance_id, target: audit_target(@campaign))
    render_one(:ok)
  end

  def resume
    return render_conflict("Only a paused campaign can be resumed") unless @campaign.transition!(from: %w[paused], to: "live")

    audit!("in_app_campaign.resumed", instance_id: @project.instance_id, target: audit_target(@campaign))
    render_one(:ok)
  end

  def finish
    return render_conflict("Only a launched campaign can be ended") unless @campaign.end!

    audit!("in_app_campaign.ended", instance_id: @project.instance_id, target: audit_target(@campaign))
    render_one(:ok)
  end

  # With `variant`, the copy carries that variant as its only content and no experiment: the winner, rolled out.
  def duplicate
    source = @campaign
    @campaign = @project.in_app_campaigns.new(source.slice(*InAppCampaign::DEFINITION_FIELDS, *InAppCampaign::EXPERIMENT_FIELDS, "audience_type"))
    @campaign.assign_attributes(name: "#{source.name} copy".first(255), created_by: current_user, segment: source.segment)
    return if params.key?(:variant) && !keep_only(source, params[:variant])
    # Together, so a copy whose pictures or media could not be copied is not left behind.
    copied = InAppCampaign.transaction do
      (@campaign.save && @campaign.copy_images_from(source) && @campaign.copy_media_from(source)) || raise(ActiveRecord::Rollback)
    end
    return render_invalid unless copied

    audit!("in_app_campaign.created", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "name" => @campaign.name, "copied_from" => source.hashid } })
    render_one(:created)
  ensure
    @campaign.discard_copies unless copied
  end

  # The campaign keeps its old audience until the new one is written, then every device syncs.
  def update_audience
    return render_conflict("Only a launched campaign with a segment has an audience to update") unless audience_updatable?
    return refuse("The segment is archived") if @campaign.segment.archived?

    return render_conflict("The audience is already up to date") if @campaign.audience_snapshot[:segment_key] == @campaign.segment_key

    InAppAudienceUpdateJob.perform_async(@campaign.id)
    audit!("in_app_campaign.audience_updated", instance_id: @project.instance_id, target: audit_target(@campaign),
                                               changes: { "after" => { "segment" => @campaign.segment.hashid } })
    render_one(:accepted)
  end

  # Shown on that person's devices at their next sync, whatever the triggers, conditions and limits say.
  def test
    identifier = params[:identifier].to_s.strip
    return refuse("identifier is required") if identifier.empty?

    devices = InAppTests.deliver(@campaign, identifier)
    return refuse("Nobody in this project has that identifier") if devices.zero?

    audit!("in_app_campaign.tested", instance_id: @project.instance_id, target: audit_target(@campaign),
                                     changes: { "after" => { "devices" => devices } })
    render json: { devices: devices }, status: :accepted
  end

  def experiment
    to = params[:to].presence || Date.current.iso8601
    render json: { experiment: Experiments::Report.in_app(@campaign, from: params[:from].presence || default_from, to: to) }, status: :ok
  end

  def report
    to = params[:to].presence || Date.current.iso8601
    render json: { report: InAppReport.call(@campaign, from: params[:from].presence || default_from, to: to, by: params.fetch(:by, "day")) }, status: :ok
  end

  def comments
    to = params[:to].presence || Date.current.iso8601
    page = InAppReport.comments(@campaign, from: params[:from].presence || default_from, to: to,
                                           values: params[:values].to_s.split(","), before: params[:before].presence)
    render json: page, status: :ok
  end

  def answers
    to = params[:to].presence || Date.current.iso8601
    render json: { answers: InAppReport.answers(@campaign, from: params[:from].presence || default_from, to: to) }, status: :ok
  end

  def upload_image
    return refuse("slot must be portrait or landscape") unless InAppCampaign::IMAGE_SLOTS.include?(params[:slot].to_s)
    return refuse("image must be a file") unless params[:image].respond_to?(:read)
    return render_conflict("An ended campaign cannot be edited") if @campaign.status == "ended"
    return render_invalid unless @campaign.attach_image(params[:slot].to_s, params[:image])

    audit!("in_app_campaign.updated", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "image" => params[:slot].to_s } })
    render_one(:ok)
  end

  def remove_image
    return refuse("slot must be portrait or landscape") unless InAppCampaign::IMAGE_SLOTS.include?(params[:slot].to_s)
    return render_conflict("An ended campaign cannot be edited") if @campaign.status == "ended"
    return render_invalid unless @campaign.remove_image(params[:slot].to_s)

    audit!("in_app_campaign.updated", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "image_removed" => params[:slot].to_s } })
    render_one(:ok)
  end

  def media_index
    render json: { media: @campaign.media.blobs.map { |blob| media_json(blob) } }, status: :ok
  end

  def upload_media
    return refuse("file must be a file") unless params[:file].respond_to?(:read)
    return render_conflict("An ended campaign cannot be edited") if @campaign.status == "ended"
    return if (expected = media_version) == false

    blob = @campaign.attach_media(params[:file], expected_version: expected)
    return render_invalid if blob.nil?

    audit!("in_app_campaign.updated", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "media" => blob.filename.to_s } })
    render json: { media: media_json(blob), lock_version: @campaign.lock_version }, status: :created
  end

  def remove_media
    return render_conflict("An ended campaign cannot be edited") if @campaign.status == "ended"
    return if (expected = media_version) == false

    blob = @campaign.media.blobs.find_by(id: ActiveStorage::Blob.find_signed(params[:media_id])&.id)
    return render json: { error: "Media not found" }, status: :not_found if blob.nil?

    removed = @campaign.with_lock do
      raise ActiveRecord::StaleObjectError.new(@campaign, "remove_media") if expected && expected != @campaign.lock_version
      next false if @campaign.media_in_use?(blob)

      @campaign.media.attachments.find_by(blob_id: blob.id)&.purge
      @campaign.reload # the version answered must be read under this lock
      true
    end
    return render json: { error: "in_use" }, status: :conflict unless removed

    audit!("in_app_campaign.updated", instance_id: @project.instance_id, target: audit_target(@campaign),
                                      changes: { "after" => { "media_removed" => blob.filename.to_s } })
    render json: { message: "Deleted", lock_version: @campaign.lock_version }, status: :ok
  end

  def destroy
    return render_conflict("Only a draft can be deleted") unless @campaign.draft?

    @campaign.destroy!
    audit!("in_app_campaign.deleted", instance_id: @project.instance_id, target: audit_target(@campaign))
    render json: { message: "Deleted" }, status: :ok
  end

  private

  # The launch day, unless that is further back than a report may reach.
  def default_from
    [(@campaign.launched_at || Time.current).to_date, Date.current - (InAppReport::MAX_DAYS - 1)].max.iso8601
  end

  def audience_updatable?
    %w[scheduled live paused].include?(@campaign.status) && @campaign.segment_key.present? && @campaign.segment.present?
  end


  # The revision the editor was looking at: a save made from an older one is refused, not merged.
  def expect_version
    return true unless params.key?(:lock_version)

    @campaign.lock_version = Integer(params[:lock_version])
    true
  rescue ArgumentError, TypeError
    refuse("lock_version must be a number")
  end

  # Media writes bump lock_version too, so an editor's optional lock_version is checked here as well.
  def media_version
    params.key?(:lock_version) ? Integer(params[:lock_version]) : nil
  rescue ArgumentError, TypeError
    refuse("lock_version must be a number")
  end

  def assign
    return false unless expect_version

    PLAIN.each { |k| @campaign.public_send("#{k}=", params[k]) if params.key?(k) }
    OBJECTS.each { |k| return false unless take(k, :to_unsafe_h, "an object") }
    OPTIONAL.each { |k, (reader, kind)| return false unless params[k].nil? ? clear(k) : take(k, reader, kind) }
    LISTS.each { |k| return false unless take_list(k) }
    TIMES.each { |k| return false unless take_time(k) }
    assign_audience
  end

  def take(key, reader, kind)
    return true unless params.key?(key)
    return refuse("#{key} must be #{kind}") unless params[key].respond_to?(reader)

    value = params[key].public_send(reader)
    @campaign.public_send("#{key}=", value.is_a?(Array) ? value.map { |item| plain(item) } : value.to_h)
    true
  end

  def clear(key)
    @campaign.public_send("#{key}=", nil) if params.key?(key)
    true
  end

  def keep_only(source, variant)
    content = source.variant_content(variant.to_s)
    return refuse("variant must be one of #{source.variant_ids.join(', ')}") if content.nil?

    @campaign.assign_attributes(content: content, variants: nil, control_group: nil, conversion: nil)
    true
  end

  def take_list(key)
    return true unless params.key?(key)
    return refuse("#{key} must be a list") unless params[key].is_a?(Array)

    @campaign.public_send("#{key}=", params[key].map { |item| plain(item) })
    true
  end

  def plain(item) = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h.to_h : item

  def take_time(key)
    return true unless params.key?(key)

    @campaign.public_send("#{key}=", params[key].presence && Time.iso8601(params[key].to_s))
    true
  rescue ArgumentError
    refuse("#{key} must be a time such as 2026-10-01T09:00:00Z")
  end

  # The audience is frozen at launch, so it changes only while the campaign is a draft.
  def assign_audience
    return true unless params.key?(:audience)

    audience = params[:audience]
    return refuse("audience must be an object") unless audience.respond_to?(:to_unsafe_h)
    return refuse("The audience cannot change after launch") unless @campaign.draft?

    @campaign.audience_type = audience[:type]
    @campaign.segment = audience[:type] == "segment" ? @project.segments.active.find_by_hashid(audience[:segment_id]) : nil
    return refuse("Segment not found") if audience[:type] == "segment" && @campaign.segment.nil?

    true
  end

  def refuse(message)
    render json: { error: message }, status: :unprocessable_entity
    false
  end

  def require_in_app
    return if @project.instance.in_app_enabled?

    render json: { error: "In-app messages are not enabled" }, status: :not_found
  end

  def load_campaign
    @campaign = @project.in_app_campaigns.find_by_hashid(params[:campaign_id])
    render json: { error: "In-app campaign not found" }, status: :not_found unless @campaign
  end

  def refuse_journey_step
    render_conflict("This message belongs to a journey; change it there") if @campaign.audience_type == "journey"
  end

  def media_json(blob) = { id: blob.signed_id, url: AssetService.absolute_url(blob), type: blob.content_type, bytes: blob.byte_size,
                          used: @campaign.media_in_use?(blob) }

  def render_bad_page = render(json: { error: "after must be an in-app campaign id and limit an integer" }, status: :unprocessable_entity)
  def render_one(status) = render(json: { in_app_campaign: InAppCampaignSerializer.serialize(@campaign) }, status: status)
  def render_invalid = render(json: { error: @campaign.errors.full_messages.join(", ") }, status: :unprocessable_entity)
  def render_conflict(msg) = render(json: { error: msg }, status: :conflict)
end
